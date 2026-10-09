defmodule MobWhisper.SelfTestTest do
  use ExUnit.Case, async: true

  alias MobDev.Plugin.{Manifest, Validator}

  @plugin_dir Path.expand("../..", __DIR__)
  @ctx %{platform: :android, device: :emulator}

  test "the manifest declares it and the validator raises no selftest warning" do
    {:ok, m} = Manifest.load(@plugin_dir)
    assert m.selftest == MobWhisper.SelfTest
    assert %{errors: [], warnings: warnings} = Validator.validate_plugin(m, @plugin_dir)
    refute Enum.any?(warnings, &(&1 =~ "selftest"))
  end

  test "each check names the call, what came back and what was expected; a raise means not linked" do
    assert MobWhisper.SelfTest.check(
             :load_model,
             fn -> {:error, :load_failed} end,
             {:error, :load_failed}
           ) == :ok

    assert MobWhisper.SelfTest.check(:load_model, fn -> {:ok, :x} end, {:error, :load_failed}) ==
             {:fail, "load_model returned {:ok, :x}, expected {:error, :load_failed}"}

    assert {:fail, reason} =
             MobWhisper.SelfTest.check(
               :capture_stop,
               fn -> :erlang.nif_error(:nif_not_loaded) end,
               {:error, :not_capturing}
             )

    assert reason =~ "capture_stop raised"
    assert reason =~ "mob_whisper_nif is not linked"
  end

  test "on a host with no cpp_archive linked the first answer already fails, without raising" do
    # The stub's nif_loaded/0 is false; load_model/1 would raise nif_not_loaded
    # but is never reached.
    assert {:fail, reason} = MobWhisper.SelfTest.run(@ctx)
    assert reason == "nif_loaded returned false, expected true"
    assert Mob.Plugin.SelfTest.result?({:fail, reason})
  end
end
