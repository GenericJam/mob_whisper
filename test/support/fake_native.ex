defmodule MobWhisper.FakeNative do
  @moduledoc """
  Scripted stand-in for the NIF in tests. Each call reports
  `{:native, name, args}` to the test process registered with `script/2` and
  returns that test's scripted result (defaults: capture works, the model
  loads, transcription returns "hello world").

  Scripted results may be functions; they're called with the call's args, so
  a test can block a transcription until it says so.
  """

  @behaviour MobWhisper.Native

  @key {__MODULE__, :script}

  @doc "Register `test_pid` as the observer and override results for this test."
  @spec script(pid(), map()) :: :ok
  def script(test_pid, overrides \\ %{}) do
    defaults = %{
      loaded?: true,
      load_model: {:ok, make_ref()},
      transcribe: {:ok, " hello world"},
      abort: :ok,
      capture_start: :ok,
      capture_stop: {:ok, speech_pcm(2_000)}
    }

    :persistent_term.put(@key, {test_pid, Map.merge(defaults, overrides)})
  end

  @doc "`ms` of a loud 440 Hz-ish square wave as 16 kHz s16le PCM."
  @spec speech_pcm(non_neg_integer()) :: binary()
  def speech_pcm(ms) do
    for i <- 1..(ms * 16)//1, into: <<>> do
      s = if rem(div(i, 18), 2) == 0, do: 8_000, else: -8_000
      <<s::little-signed-16>>
    end
  end

  defp call(name, args) do
    {pid, script} = :persistent_term.get(@key)
    send(pid, {:native, name, args})

    case Map.fetch!(script, name) do
      fun when is_function(fun) -> apply(fun, args)
      value -> value
    end
  end

  @impl true
  def loaded?, do: call(:loaded?, [])

  @impl true
  def load_model(path), do: call(:load_model, [path])

  @impl true
  def transcribe(model, pcm, language, threads, audio_ctx),
    do: call(:transcribe, [model, pcm, language, threads, audio_ctx])

  @impl true
  def abort(model), do: call(:abort, [model])

  @impl true
  def capture_start, do: call(:capture_start, [])

  @impl true
  def capture_stop, do: call(:capture_stop, [])
end
