defmodule MobWhisper do
  @moduledoc """
  Offline speech-to-text for Mob apps, as a `MobSpeech` engine.

  [whisper.cpp](https://github.com/ggml-org/whisper.cpp) runs on the phone's
  CPU: no Google app, no language pack, no network once the model is on the
  device. It records the microphone while you listen and transcribes when you
  stop, so there are no partial results; the final text arrives a moment after
  `MobSpeech.stop/1` (about 1.7 s for a 4-5 s sentence with `:base_en` on a
  Moto G 2021, Snapdragon 662).

      # once, e.g. when the screen mounts:
      socket = Mob.Permissions.request(socket, :microphone)

      # hold to talk
      socket = MobSpeech.listen(socket, engine: MobWhisper)
      socket = MobSpeech.stop(socket)

      def handle_info({:speech, :final, text}, socket), do: ...
      def handle_info({:speech, :error, reason}, socket), do: ...

  Events and their guarantees are `MobSpeech`'s; this engine sends
  `{:speech, :state, :listening}` when the microphone opens, then one
  `{:speech, :final, text}` or `{:speech, :error, reason}`. Reasons:
  `:no_speech` (silence, or nothing recognisable), `:permission` (microphone
  not granted), `:busy` (another session is listening), `:language` (the model
  doesn't speak the requested language), `:network` (the model download
  failed), `:unavailable` (the NIF isn't linked or the model won't load),
  `:audio` (the microphone failed).

  ## The model

  The first recognition downloads the configured model (see
  `MobWhisper.Model`) into the app's support directory and loads it; that
  first final waits for the download. Call `prefetch/0` at app start, or set
  `prefetch: true`, to have it ready before the user first speaks.

  ## Configuration

      config :mob_whisper,
        model: :base_en,      # or :tiny_en, or {:file, "/abs/path/model.bin"}
        threads: 4,           # CPU threads for transcription (default: min(4, cores))
        prefetch: false,      # download + load the model at boot
        models_dir: nil       # default: <Mob.Storage.dir(:app_support)>/mob_whisper

  On Android the BEAM has no system CA store, so HTTPS needs
  `Mob.Certs.load_cacerts!/1` at boot before the model download.
  """

  @behaviour MobSpeech.Engine

  alias MobWhisper.Server

  @doc false
  @spec config() :: keyword()
  def config do
    env = Application.get_all_env(:mob_whisper)

    [
      native: Keyword.get(env, :native, MobWhisper.Native),
      model: Keyword.get(env, :model, :base_en),
      threads: Keyword.get(env, :threads, default_threads()),
      prefetch: Keyword.get(env, :prefetch, false),
      models_dir: Keyword.get(env, :models_dir)
    ]
  end

  # whisper.cpp runs its own threads, so this counts CPU cores, not BEAM
  # schedulers (a Mob app runs a single scheduler). Four is the sweet spot on
  # big.LITTLE phones: more threads spill onto the slow cores and wait on them.
  @doc false
  @spec default_threads() :: pos_integer()
  def default_threads do
    case :erlang.system_info(:logical_processors_available) do
      n when is_integer(n) -> min(4, n)
      :unknown -> 4
    end
  end

  # ── MobSpeech.Engine ─────────────────────────────────────────────────────

  @impl MobSpeech.Engine
  @spec start(pid(), keyword()) :: :ok | {:error, term()}
  def start(pid, opts), do: Server.start_session(pid, opts)

  @impl MobSpeech.Engine
  @spec stop(pid()) :: :ok
  def stop(pid), do: Server.stop_session(pid)

  @impl MobSpeech.Engine
  @spec cancel(pid()) :: :ok
  def cancel(pid), do: Server.cancel_session(pid)

  @doc "Whether the whisper NIF is linked into this app (false on a host build)."
  @impl MobSpeech.Engine
  @spec available?() :: boolean()
  def available?, do: config()[:native].loaded?()

  @impl MobSpeech.Engine
  @spec permissions() :: [atom()]
  def permissions, do: [:microphone]

  # Transcription starts after stop: give a long utterance on a slow phone
  # (and a first-use model download) room before MobSpeech's watchdog fires.
  @impl MobSpeech.Engine
  @spec stop_timeout_ms() :: pos_integer()
  def stop_timeout_ms, do: 120_000

  # ── Direct use ───────────────────────────────────────────────────────────

  @doc """
  Download (if needed) and load the configured model in the background, so the
  first recognition doesn't wait for it. Returns immediately.

  Options: `notify: pid` sends that process `{:mob_whisper, :model, :ready}`
  once the model is loaded (at once if it already is), or
  `{:mob_whisper, :model, {:error, reason}}` (`:network` for a failed
  download, `:unavailable` otherwise), e.g. to tell the user.
  """
  @spec prefetch(keyword()) :: :ok
  def prefetch(opts \\ []), do: Server.prefetch(Keyword.get(opts, :notify))

  @doc """
  Transcribe a recording directly, without a session or the microphone:
  `pcm` is 16 kHz mono signed 16-bit little-endian. Blocks until the model is
  loaded (downloading it if needed) and the text is ready.

  Options: `:language` (BCP-47, default English), `:timeout` (ms, default
  `:infinity`).
  """
  @spec transcribe(binary(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def transcribe(pcm, opts \\ []) when is_binary(pcm) do
    config = config()
    timeout = Keyword.get(opts, :timeout, :infinity)

    with :ok <- if(available?(), do: :ok, else: {:error, :unavailable}),
         {:ok, language} <- Server.language(opts[:language], config[:model]),
         {:ok, model} <- Server.model(timeout),
         {:ok, text} <-
           config[:native].transcribe(
             model,
             pcm,
             language,
             config[:threads],
             MobWhisper.Audio.audio_ctx(pcm)
           ) do
      {:ok, MobWhisper.Audio.clean_text(text)}
    end
  end

  @doc """
  What the engine is doing: the configured model and whether it's loaded,
  the current session if any, and timings of the last transcription
  (`%{audio_ms:, transcribe_ms:, stop_to_text_ms:, audio_ctx:}`).
  """
  @spec status() :: map()
  def status, do: Server.status()
end
