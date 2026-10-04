defmodule MobWhisper.Native do
  @moduledoc false
  # The NIF surface `MobWhisper.Server` drives, behind a behaviour so tests can
  # substitute a scripted fake (`config :mob_whisper, :native, Fake`) and run
  # the session state machine without a microphone or a model.
  #
  # transcribe/5 blocks the calling process until the text is ready. Sending
  # that process `:mob_whisper_abort` cancels the transcription: it returns
  # {:error, :cancelled} promptly.

  @callback loaded?() :: boolean()
  @callback load_model(Path.t()) :: {:ok, reference()} | {:error, atom()}
  @callback transcribe(reference(), binary(), String.t(), pos_integer(), non_neg_integer()) ::
              {:ok, String.t()} | {:error, atom()}
  @callback capture_start() :: :ok | {:error, atom()}
  @callback capture_stop() :: {:ok, binary()} | {:error, atom()}

  @behaviour __MODULE__

  @impl true
  def loaded?, do: :mob_whisper_nif.nif_loaded()

  @impl true
  def load_model(path), do: :mob_whisper_nif.load_model(path)

  # The NIF returns at once and a native thread replies with a message.
  @impl true
  def transcribe(model, pcm, language, threads, audio_ctx) do
    case :mob_whisper_nif.transcribe(model, pcm, language, threads, audio_ctx) do
      {:ok, ref, job} -> await(model, ref, job)
      {:error, _} = error -> error
    end
  end

  defp await(model, ref, job) do
    receive do
      {:mob_whisper_result, ^ref, result} ->
        result

      :mob_whisper_abort ->
        :ok = :mob_whisper_nif.abort(model, job)
        await(model, ref, job)
    end
  end

  @impl true
  def capture_start, do: :mob_whisper_nif.capture_start()

  @impl true
  def capture_stop, do: :mob_whisper_nif.capture_stop()
end
