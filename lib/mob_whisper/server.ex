defmodule MobWhisper.Server do
  @moduledoc false
  # Owns the microphone and the loaded model. One recognition session at a
  # time (there is one microphone); a second start gets {:error, :busy}.
  #
  # Session phases: :listening (capturing) → :processing (stopped, waiting for
  # the model and/or the transcription task) → gone. Events go to the session
  # pid as MobSpeech expects ({:speech, :state, :listening} on start, then one
  # {:speech, :final, text} or {:speech, :error, reason}); MobSpeech's session
  # adds :processing and :idle.
  #
  # The model is fetched (MobWhisper.Model.ensure/3) and loaded in a task the
  # first time anything needs it, and kept loaded. A failed load is retried by
  # the next caller.

  use GenServer

  require Logger

  alias MobWhisper.{Audio, Model}

  # Shorter than this is a tap, not speech: skip the model entirely.
  @min_speech_ms 300
  # Peak below this (of 32768) is silence or a muted microphone.
  @silence_peak 200

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec start_session(pid(), keyword()) :: :ok | {:error, term()}
  def start_session(pid, opts), do: GenServer.call(__MODULE__, {:start, pid, opts}, 10_000)

  @spec stop_session(pid()) :: :ok
  def stop_session(pid), do: GenServer.call(__MODULE__, {:stop, pid}, 10_000)

  @spec cancel_session(pid()) :: :ok
  def cancel_session(pid), do: GenServer.call(__MODULE__, {:cancel, pid}, 10_000)

  @spec prefetch(pid() | nil) :: :ok
  def prefetch(notify \\ nil), do: GenServer.cast(__MODULE__, {:prefetch, notify})

  @spec model(timeout()) :: {:ok, reference()} | {:error, term()}
  def model(timeout), do: GenServer.call(__MODULE__, :model, timeout)

  @spec status() :: map()
  def status, do: GenServer.call(__MODULE__, :status)

  # ── GenServer ────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    # Read at (re)start, so changed application config applies after a restart.
    opts = Keyword.merge(MobWhisper.config(), opts)

    state = %{
      native: Keyword.fetch!(opts, :native),
      model_spec: Keyword.fetch!(opts, :model),
      models_dir: Keyword.get(opts, :models_dir),
      threads: Keyword.fetch!(opts, :threads),
      model: nil,
      model_task: nil,
      model_error: nil,
      model_waiters: [],
      session: nil,
      last: nil
    }

    if Keyword.get(opts, :prefetch, false),
      do: {:ok, state, {:continue, :prefetch}},
      else: {:ok, state}
  end

  @impl true
  def handle_continue(:prefetch, state), do: {:noreply, ensure_model(state)}

  @impl true
  def handle_call({:start, _pid, _opts}, _from, %{session: %{}} = state),
    do: {:reply, {:error, :busy}, state}

  def handle_call({:start, pid, opts}, _from, state) do
    with :ok <- linked(state.native),
         {:ok, language} <- language(opts[:language], state.model_spec),
         :ok <- state.native.capture_start() do
      session = %{
        pid: pid,
        monitor: Process.monitor(pid),
        language: language,
        phase: :listening,
        started_at: now(),
        stopped_at: nil,
        pcm: nil,
        task: nil
      }

      send(pid, {:speech, :state, :listening})
      {:reply, :ok, ensure_model(%{state | session: session})}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:stop, pid}, _from, %{session: %{pid: pid, phase: :listening} = s} = state) do
    s = %{s | phase: :processing, stopped_at: now()}

    case state.native.capture_stop() do
      {:ok, pcm} -> {:reply, :ok, process(%{state | session: %{s | pcm: pcm}})}
      {:error, reason} -> {:reply, :ok, finish(state, {:error, reason})}
    end
  end

  def handle_call({:stop, _pid}, _from, state), do: {:reply, :ok, state}

  def handle_call({:cancel, pid}, _from, %{session: %{pid: pid}} = state),
    do: {:reply, :ok, abandon(state)}

  def handle_call({:cancel, _pid}, _from, state), do: {:reply, :ok, state}

  def handle_call(:model, _from, %{model: model} = state) when model != nil,
    do: {:reply, {:ok, model}, state}

  def handle_call(:model, from, state),
    do: {:noreply, ensure_model(%{state | model_waiters: [{:reply, from} | state.model_waiters]})}

  def handle_call(:status, _from, state) do
    status = %{
      model: state.model_spec,
      model_state: model_state(state),
      session: state.session && Map.take(state.session, [:pid, :phase]),
      last: state.last
    }

    {:reply, status, state}
  end

  @impl true
  def handle_cast({:prefetch, nil}, state), do: {:noreply, ensure_model(state)}

  def handle_cast({:prefetch, pid}, %{model: model} = state) when model != nil do
    send(pid, {:mob_whisper, :model, :ready})
    {:noreply, state}
  end

  def handle_cast({:prefetch, pid}, state),
    do: {:noreply, ensure_model(%{state | model_waiters: [{:notify, pid} | state.model_waiters]})}

  @impl true
  def handle_info({ref, result}, %{model_task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, model_ready(%{state | model_task: nil}, result)}
  end

  def handle_info({ref, result}, %{session: %{task: %Task{ref: ref}}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, transcribed(state, result)}
  end

  def handle_info({:DOWN, ref, :process, _, reason}, %{model_task: %Task{ref: ref}} = state),
    do: {:noreply, model_ready(%{state | model_task: nil}, {:error, {:crashed, reason}})}

  def handle_info(
        {:DOWN, ref, :process, _, reason},
        %{session: %{task: %Task{ref: ref}}} = state
      ),
      do: {:noreply, transcribed(state, {:error, {:crashed, reason}})}

  def handle_info({:DOWN, ref, :process, _, _}, %{session: %{monitor: ref}} = state),
    do: {:noreply, abandon(state)}

  # Late result of a transcription that was cancelled, or a stale monitor.
  def handle_info(_msg, state), do: {:noreply, state}

  # ── Sessions ─────────────────────────────────────────────────────────────

  # A stopped session: decide whether there's anything to transcribe, then
  # wait for the model or start the transcription.
  defp process(%{session: s} = state) do
    cond do
      Audio.duration_ms(s.pcm) < @min_speech_ms -> finish(state, {:error, :no_speech})
      Audio.peak(s.pcm) < @silence_peak -> finish(state, {:error, :no_speech})
      state.model != nil -> transcribe(state)
      true -> ensure_model(state)
    end
  end

  defp transcribe(%{session: s, model: model, native: native, threads: threads} = state) do
    audio_ctx = Audio.audio_ctx(s.pcm)

    task =
      Task.Supervisor.async_nolink(MobWhisper.TaskSupervisor, fn ->
        t0 = now()
        {native.transcribe(model, s.pcm, s.language, threads, audio_ctx), now() - t0}
      end)

    %{state | session: %{s | task: task}}
  end

  defp transcribed(%{session: s} = state, {{:ok, text}, transcribe_ms}) do
    last = %{
      audio_ms: Audio.duration_ms(s.pcm),
      transcribe_ms: transcribe_ms,
      stop_to_text_ms: now() - s.stopped_at,
      audio_ctx: Audio.audio_ctx(s.pcm)
    }

    Logger.info(
      "mob_whisper: #{last.audio_ms} ms of audio → text in #{last.stop_to_text_ms} ms " <>
        "(transcribe #{transcribe_ms} ms, #{inspect(state.model_spec)})"
    )

    result =
      case Audio.clean_text(text) do
        "" -> {:error, :no_speech}
        clean -> {:ok, clean}
      end

    finish(%{state | last: last}, result)
  end

  defp transcribed(state, {{:error, reason}, _ms}), do: finish(state, {:error, reason})
  defp transcribed(state, {:error, reason}), do: finish(state, {:error, reason})

  defp finish(%{session: s} = state, result) do
    case result do
      {:ok, text} -> send(s.pid, {:speech, :final, text})
      {:error, reason} -> send(s.pid, {:speech, :error, speech_reason(reason)})
    end

    Process.demonitor(s.monitor, [:flush])
    %{state | session: nil}
  end

  # Cancel, or the session process died: release the microphone or abort the
  # transcription. Nothing is sent; a late task result is dropped by handle_info.
  defp abandon(%{session: s} = state) do
    case s do
      %{phase: :listening} -> state.native.capture_stop()
      %{task: %Task{pid: pid}} -> send(pid, :mob_whisper_abort)
      _ -> :ok
    end

    if s.task, do: Process.demonitor(s.task.ref, [:flush])
    Process.demonitor(s.monitor, [:flush])
    %{state | session: nil}
  end

  # ── Model ────────────────────────────────────────────────────────────────

  defp ensure_model(%{model: model} = state) when model != nil, do: state
  defp ensure_model(%{model_task: %Task{}} = state), do: state

  defp ensure_model(state) do
    %{native: native, model_spec: spec, models_dir: models_dir} = state

    # In the task, so a failure anywhere (storage dir, download, load) is a
    # model error the next caller retries, not a server crash.
    task =
      Task.Supervisor.async_nolink(MobWhisper.TaskSupervisor, fn ->
        dir = if match?({:file, _}, spec), do: nil, else: models_dir || default_models_dir()

        with {:ok, path} <- Model.ensure(spec, dir) do
          native.load_model(path)
        end
      end)

    %{state | model_task: task, model_error: nil}
  end

  defp model_ready(state, {:ok, model}) do
    Enum.each(state.model_waiters, &tell_waiter(&1, {:ok, model}))
    state = %{state | model: model, model_waiters: []}

    case state.session do
      %{phase: :processing, task: nil, pcm: pcm} when is_binary(pcm) -> transcribe(state)
      _ -> state
    end
  end

  defp model_ready(state, {:error, reason}) do
    Logger.warning(
      "mob_whisper: model #{inspect(state.model_spec)} unavailable: #{inspect(reason)}"
    )

    Enum.each(state.model_waiters, &tell_waiter(&1, {:error, reason}))
    state = %{state | model_error: reason, model_waiters: []}

    case state.session do
      %{phase: :processing, task: nil} -> finish(state, {:error, reason})
      _ -> state
    end
  end

  # model/1 callers get the model; prefetch(pid) gets a notice.
  defp tell_waiter({:reply, from}, result), do: GenServer.reply(from, result)
  defp tell_waiter({:notify, pid}, {:ok, _}), do: send(pid, {:mob_whisper, :model, :ready})

  defp tell_waiter({:notify, pid}, {:error, reason}),
    do: send(pid, {:mob_whisper, :model, {:error, speech_reason(reason)}})

  defp model_state(%{model: m}) when m != nil, do: :ready
  defp model_state(%{model_task: %Task{}}), do: :loading
  defp model_state(%{model_error: nil}), do: :not_loaded
  defp model_state(%{model_error: reason}), do: {:error, reason}

  defp default_models_dir, do: Path.join(Mob.Storage.dir(:app_support), "mob_whisper")

  # ── Helpers ──────────────────────────────────────────────────────────────

  # A host build, or an app that didn't activate the plugin, has no NIF: say
  # so instead of letting nif_not_loaded crash the server (and with it the
  # MobSpeech session, silently).
  defp linked(native), do: if(native.loaded?(), do: :ok, else: {:error, :unavailable})

  @doc false
  # The whisper language code for a MobSpeech `:language` (BCP-47 or nil).
  # English-only models accept nil or any "en" tag; others take the primary
  # subtag, or "auto" (detect) for nil. A misconfigured model is :unavailable.
  @spec language(String.t() | nil, term()) ::
          {:ok, String.t()} | {:error, :language | :unavailable}
  def language(tag, spec) do
    primary = tag && tag |> String.split(["-", "_"]) |> hd() |> String.downcase()

    cond do
      not Model.valid?(spec) -> {:error, :unavailable}
      Model.english_only?(spec) and primary in [nil, "en"] -> {:ok, "en"}
      Model.english_only?(spec) -> {:error, :language}
      primary == nil -> {:ok, "auto"}
      true -> {:ok, primary}
    end
  end

  @doc false
  # Map a capture / model / NIF failure onto MobSpeech's public reasons.
  @spec speech_reason(term()) :: atom() | term()
  def speech_reason(reason)
      when reason in [:no_speech, :permission, :busy, :audio, :unavailable, :language],
      do: reason

  def speech_reason({:download, _}), do: :network
  def speech_reason(:checksum_mismatch), do: :network
  def speech_reason(reason) when reason in [:load_failed, :enoent], do: :unavailable
  # The model or transcription task raised (e.g. storage dir unavailable).
  def speech_reason({:crashed, _}), do: :unavailable
  def speech_reason(:transcribe_failed), do: :client
  def speech_reason(other), do: other

  defp now, do: System.monotonic_time(:millisecond)
end
