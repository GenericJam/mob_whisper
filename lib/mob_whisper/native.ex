defmodule MobWhisper.Native do
  @moduledoc false
  # The NIF surface `MobWhisper.Server` drives, behind a behaviour so tests can
  # substitute a scripted fake (`config :mob_whisper, :native, Fake`) and run
  # the session state machine without a microphone or a model.

  @callback loaded?() :: boolean()
  @callback load_model(Path.t()) :: {:ok, reference()} | {:error, atom()}
  @callback transcribe(reference(), binary(), String.t(), pos_integer(), non_neg_integer()) ::
              {:ok, String.t()} | {:error, atom()}
  @callback abort(reference()) :: :ok
  @callback capture_start() :: :ok | {:error, atom()}
  @callback capture_stop() :: {:ok, binary()} | {:error, atom()}

  @behaviour __MODULE__

  @impl true
  def loaded?, do: :mob_whisper_nif.nif_loaded()

  @impl true
  def load_model(path), do: :mob_whisper_nif.load_model(path)

  # The NIF returns at once and the native thread replies with a message;
  # abort/1 makes it reply {:error, :cancelled} promptly.
  @impl true
  def transcribe(model, pcm, language, threads, audio_ctx) do
    case :mob_whisper_nif.transcribe(model, pcm, language, threads, audio_ctx) do
      {:ok, ref} ->
        receive do
          {:mob_whisper_result, ^ref, result} -> result
        end

      {:error, _} = error ->
        error
    end
  end

  @impl true
  def abort(model), do: :mob_whisper_nif.abort(model)

  @impl true
  def capture_start, do: :mob_whisper_nif.capture_start()

  @impl true
  def capture_stop, do: :mob_whisper_nif.capture_stop()
end
