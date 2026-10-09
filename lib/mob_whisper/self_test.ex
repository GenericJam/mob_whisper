defmodule MobWhisper.SelfTest do
  @moduledoc """
  The plugin's on-device proof (`Mob.Plugin.SelfTest`), run by
  `mix mob.selftest` and mob_ci for every activated plugin.

  Three answers from the NIF, without a model download or a microphone:

    1. `nif_loaded/0` must be `true`: the Erlang stub answers `false`, the
       C++ export answers `true`, so this is whether the cpp_archive was
       linked and `nif_init` ran.
    2. `load_model/1` on a path that does not exist must answer
       `{:error, :load_failed}`: whisper.cpp's loader ran and refused, which
       proves the vendored whisper/ggml objects are in the binary and callable.
    3. `capture_stop/0` while nothing is recording must answer
       `{:error, :not_capturing}`: the platform capture backend (AAudio /
       AudioQueue) is linked and answers.

  Transcription itself needs a model (about 60 MB) and is the feature, not the
  proof. Run it while the host is not recording: `capture_stop/0` is only a
  no-op while idle, and would otherwise stop the host's capture (the test
  then fails visibly with the returned PCM).
  """
  @behaviour Mob.Plugin.SelfTest

  @missing_model "/mob_whisper-selftest-no-such-model.bin"

  @impl true
  def run(_ctx) do
    with :ok <- check(:nif_loaded, fn -> :mob_whisper_nif.nif_loaded() end, true),
         :ok <-
           check(
             :load_model,
             fn -> :mob_whisper_nif.load_model(@missing_model) end,
             {:error, :load_failed}
           ),
         :ok <-
           check(
             :capture_stop,
             fn -> :mob_whisper_nif.capture_stop() end,
             {:error, :not_capturing}
           ) do
      :pass
    end
  end

  @doc false
  @spec check(atom(), (-> term()), term()) :: :ok | {:fail, String.t()}
  def check(name, call, expected) do
    case call.() do
      ^expected -> :ok
      other -> {:fail, "#{name} returned #{inspect(other)}, expected #{inspect(expected)}"}
    end
  rescue
    e in ErlangError ->
      {:fail,
       "#{name} raised #{Exception.message(e)}: mob_whisper_nif is not linked into this build"}
  end
end
