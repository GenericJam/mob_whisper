defmodule MobWhisper.EngineTest do
  # Drives the MobSpeech.Engine callbacks against MobWhisper.Server with the
  # scripted FakeNative (config/config.exs): the session state machine the
  # device runs, minus the microphone and the model.
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias MobWhisper.FakeNative

  @model_path MobWhisper.config()[:model] |> elem(1)

  setup do
    File.write!(@model_path, "fake model")
    FakeNative.script(self())
    restart_server()
    on_exit(fn -> File.rm(@model_path) end)
    :ok
  end

  defp restart_server do
    :ok = Supervisor.terminate_child(MobWhisper.Supervisor, MobWhisper.Server)
    {:ok, _} = Supervisor.restart_child(MobWhisper.Supervisor, MobWhisper.Server)
  end

  defp script(overrides) do
    FakeNative.script(self(), overrides)
    restart_server()
  end

  test "start → listening; stop → the transcript, cleaned" do
    assert MobWhisper.start(self(), language: "en-US") == :ok
    assert_receive {:speech, :state, :listening}
    assert_receive {:native, :capture_start, []}

    assert MobWhisper.stop(self()) == :ok
    assert_receive {:native, :capture_stop, []}
    assert_receive {:native, :transcribe, [_model, pcm, "en", 2, audio_ctx]}
    assert byte_size(pcm) == 64_000
    assert audio_ctx == MobWhisper.Audio.audio_ctx(pcm)
    assert_receive {:speech, :final, "hello world"}

    assert %{session: nil, model_state: :ready, last: %{audio_ms: 2_000}} = MobWhisper.status()
  end

  test "the model is loaded once and reused" do
    for _ <- 1..2 do
      :ok = MobWhisper.start(self(), [])
      :ok = MobWhisper.stop(self())
      assert_receive {:speech, :final, _}, 1_000
    end

    assert_received {:native, :load_model, [@model_path]}
    refute_received {:native, :load_model, _}
  end

  test "a second session while one is listening is :busy" do
    :ok = MobWhisper.start(self(), [])
    other = spawn(fn -> Process.sleep(:infinity) end)
    assert MobWhisper.start(other, []) == {:error, :busy}
  end

  test "a microphone refusal fails the start with its reason" do
    script(%{capture_start: {:error, :permission}})
    assert MobWhisper.start(self(), []) == {:error, :permission}
    refute_receive {:speech, :state, :listening}
    assert %{session: nil} = MobWhisper.status()
  end

  test "a non-English language on an English-only model is refused before the mic opens" do
    FakeNative.script(self())
    Application.put_env(:mob_whisper, :model, :base_en)
    restart_server()
    on_exit(fn -> Application.put_env(:mob_whisper, :model, {:file, @model_path}) end)

    assert MobWhisper.start(self(), language: "fr-FR") == {:error, :language}
    refute_received {:native, :capture_start, []}
  end

  test "silence and taps end with :no_speech without running the model" do
    for pcm <- [:binary.copy(<<0::16>>, 32_000), FakeNative.speech_pcm(150)] do
      script(%{capture_stop: {:ok, pcm}})
      :ok = MobWhisper.start(self(), [])
      :ok = MobWhisper.stop(self())
      assert_receive {:speech, :error, :no_speech}
      refute_received {:native, :transcribe, _}
    end
  end

  test "a transcript of only non-speech markers is :no_speech" do
    script(%{transcribe: {:ok, " [BLANK_AUDIO]"}})
    :ok = MobWhisper.start(self(), [])
    :ok = MobWhisper.stop(self())
    assert_receive {:speech, :error, :no_speech}
  end

  test "cancel while listening releases the microphone and sends nothing" do
    :ok = MobWhisper.start(self(), [])
    assert_receive {:speech, :state, :listening}
    assert MobWhisper.cancel(self()) == :ok
    assert_receive {:native, :capture_stop, []}
    refute_receive {:speech, _, _}, 100
    assert :ok = MobWhisper.start(self(), [])
  end

  test "cancel while transcribing aborts it and drops its late result" do
    test = self()

    script(%{
      transcribe: fn _, _, _, _, _ ->
        send(test, {:transcribing, self()})

        receive do
          :mob_whisper_abort -> send(test, :aborted)
        end

        receive do
          :finish -> {:ok, "too late"}
        end
      end
    })

    :ok = MobWhisper.start(self(), [])
    :ok = MobWhisper.stop(self())
    assert_receive {:transcribing, task}
    :ok = MobWhisper.cancel(self())
    assert_receive :aborted
    send(task, :finish)
    refute_receive {:speech, :final, _}, 200
    assert %{session: nil} = MobWhisper.status()
  end

  test "without the NIF linked, start and transcribe/2 are :unavailable and the server survives" do
    script(%{loaded?: false})
    server = Process.whereis(MobWhisper.Server)

    assert MobWhisper.start(self(), []) == {:error, :unavailable}
    assert MobWhisper.transcribe(FakeNative.speech_pcm(500)) == {:error, :unavailable}
    refute_received {:native, :capture_start, []}
    refute_received {:native, :load_model, _}
    assert Process.whereis(MobWhisper.Server) == server

    :ok = MobWhisper.prefetch(notify: self())
    assert_receive {:mob_whisper, :model, {:error, :unavailable}}
    refute_received {:native, :load_model, _}
  end

  test "a misconfigured model is :unavailable, not a crash" do
    Application.put_env(:mob_whisper, :model, :large_v9)
    restart_server()
    on_exit(fn -> Application.put_env(:mob_whisper, :model, {:file, @model_path}) end)

    assert MobWhisper.start(self(), []) == {:error, :unavailable}
    assert MobWhisper.transcribe(FakeNative.speech_pcm(500)) == {:error, :unavailable}
  end

  test "a capture that fails at stop ends the session with one error" do
    script(%{capture_stop: {:error, :audio}})
    :ok = MobWhisper.start(self(), [])
    assert_receive {:speech, :state, :listening}
    :ok = MobWhisper.stop(self())
    assert_receive {:speech, :error, :audio}
    refute_receive {:speech, _, _}, 100
    assert %{session: nil} = MobWhisper.status()
  end

  test "a crashing model load fails the waiting session, and the next one retries" do
    script(%{load_model: fn _ -> raise "boom" end})
    :ok = MobWhisper.start(self(), [])
    :ok = MobWhisper.stop(self())
    assert_receive {:speech, :error, :unavailable}

    FakeNative.script(self())
    :ok = MobWhisper.start(self(), [])
    :ok = MobWhisper.stop(self())
    assert_receive {:speech, :final, "hello world"}
  end

  test "cancel while waiting for the model: the model arriving later sends nothing" do
    test = self()

    script(%{
      load_model: fn _ ->
        send(test, {:loading, self()})
        receive do: (:loaded -> {:ok, make_ref()})
      end
    })

    :ok = MobWhisper.start(self(), [])
    assert_receive {:loading, loader}
    :ok = MobWhisper.stop(self())
    :ok = MobWhisper.cancel(self())
    send(loader, :loaded)
    refute_receive {:speech, :final, _}, 200
    refute_received {:native, :transcribe, _}
    assert %{session: nil, model_state: :ready} = MobWhisper.status()
  end

  test "the session process dying releases the microphone" do
    pid = spawn(fn -> receive do: (:never -> :ok) end)
    :ok = MobWhisper.start(pid, [])
    Process.exit(pid, :kill)
    assert_receive {:native, :capture_stop, []}
    assert :ok = MobWhisper.start(self(), [])
  end

  test "a model that won't load fails the stopped session with :unavailable" do
    script(%{load_model: {:error, :load_failed}})
    :ok = MobWhisper.start(self(), [])
    :ok = MobWhisper.stop(self())
    assert_receive {:speech, :error, :unavailable}
    assert %{model_state: {:error, :load_failed}} = MobWhisper.status()
  end

  test "stop waits for a model still loading, then transcribes" do
    test = self()

    script(%{
      load_model: fn _path ->
        send(test, {:loading, self()})

        receive do
          :loaded -> {:ok, make_ref()}
        end
      end
    })

    :ok = MobWhisper.start(self(), [])
    assert_receive {:loading, loader}
    :ok = MobWhisper.stop(self())
    refute_received {:native, :transcribe, _}
    send(loader, :loaded)
    assert_receive {:speech, :final, "hello world"}
  end

  test "stop/cancel from a process with no session are no-ops" do
    assert MobWhisper.stop(self()) == :ok
    assert MobWhisper.cancel(self()) == :ok
    refute_receive {:speech, _, _}, 50
  end

  test "prefetch(notify:) reports the model ready, at once when already loaded" do
    :ok = MobWhisper.prefetch(notify: self())
    assert_receive {:mob_whisper, :model, :ready}
    assert_received {:native, :load_model, [@model_path]}

    :ok = MobWhisper.prefetch(notify: self())
    assert_receive {:mob_whisper, :model, :ready}
    refute_received {:native, :load_model, _}
  end

  test "prefetch(notify:) reports a failed download as :network" do
    script(%{load_model: {:error, {:download, :timeout}}})
    :ok = MobWhisper.prefetch(notify: self())
    assert_receive {:mob_whisper, :model, {:error, :network}}
  end

  test "transcribe/2 transcribes a recording directly" do
    assert MobWhisper.transcribe(FakeNative.speech_pcm(1_000)) == {:ok, "hello world"}
  end

  test "engine metadata: microphone permission, long stop budget, availability from the NIF" do
    assert MobWhisper.permissions() == [:microphone]
    assert MobWhisper.stop_timeout_ms() >= 60_000
    assert MobWhisper.available?()
    FakeNative.script(self(), %{loaded?: false})
    refute MobWhisper.available?()
  end
end
