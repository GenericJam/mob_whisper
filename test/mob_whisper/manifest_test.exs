defmodule MobWhisper.ManifestTest do
  use ExUnit.Case, async: true

  alias MobDev.Plugin.{Manifest, Merge, Validator}

  @plugin_dir Path.expand("../..", __DIR__)

  setup_all do
    {:ok, manifest} = Manifest.load(@plugin_dir)
    %{manifest: manifest}
  end

  test "the manifest passes mob_dev's pre-publish validator", %{manifest: m} do
    assert %{errors: []} = Validator.validate_plugin(m, @plugin_dir)
  end

  test "every cpp_archive source, include dir and capture file exists", %{manifest: m} do
    for platform <- [:android, :ios] do
      [spec] = Merge.static_archives([{@plugin_dir, m}], platform)

      for path <- spec.sources, do: assert(File.regular?(path), "missing source #{path}")
      for path <- spec.includes, do: assert(File.dir?(path), "missing include dir #{path}")
    end
  end

  test "each platform compiles its own capture backend and not the other's", %{manifest: m} do
    [android] = Merge.static_archives([{@plugin_dir, m}], :android)
    [ios] = Merge.static_archives([{@plugin_dir, m}], :ios)

    assert Enum.any?(android.sources, &String.ends_with?(&1, "capture_android.cpp"))
    refute Enum.any?(android.sources, &String.ends_with?(&1, "capture_ios.mm"))
    assert Enum.any?(ios.sources, &String.ends_with?(&1, "capture_ios.mm"))
    refute Enum.any?(ios.sources, &String.ends_with?(&1, "capture_android.cpp"))
  end

  test "the NIF init symbol matches the Erlang module that loads it", %{manifest: m} do
    for nif <- m.nifs do
      assert nif.module == :mob_whisper_nif
      assert nif.nm_symbol == "mob_whisper_nif_nif_init"
      assert "-DSTATIC_ERLANG_NIF_LIBNAME=mob_whisper_nif" in nif.cxxflags
    end

    assert {:module, :mob_whisper_nif} = Code.ensure_loaded(:mob_whisper_nif)
  end

  test "the microphone plist key is left to the host (core owns it)", %{manifest: m} do
    refute Map.has_key?(get_in(m, [:ios, :plist_keys]) || %{}, "NSMicrophoneUsageDescription")
    assert "android.permission.RECORD_AUDIO" in m.android.permissions
  end
end
