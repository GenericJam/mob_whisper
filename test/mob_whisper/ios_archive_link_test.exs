defmodule MobWhisper.IosArchiveLinkTest do
  # Builds the iOS device archive exactly as the host's native build does
  # (mob_dev's CppArchive over this manifest's spec), then links every member
  # into a dylib WITHOUT -dead_strip. `mix mob.release --ios` links without it,
  # so any symbol a member references but no member defines fails the release
  # even when the dev builds (which dead-strip) pass: ggml-backend-reg.cpp's
  # dl_* helpers did exactly that (MOB-470). Only the BEAM's enif_* may stay
  # undefined; the app binary provides those.
  use ExUnit.Case, async: true

  alias MobDev.Plugin.{CppArchive, Manifest, Merge}

  @moduletag :macos_only
  @moduletag timeout: 600_000

  @plugin_dir Path.expand("../..", __DIR__)

  @tag :tmp_dir
  test "the iOS device archive links with no undefined symbols but the BEAM's enif_*",
       %{tmp_dir: tmp} do
    {:ok, manifest} = Manifest.load(@plugin_dir)
    [spec] = Merge.static_archives([{@plugin_dir, manifest}], :ios)

    # erl_nif.h from the host OTP: only the declarations are needed to compile.
    erts_include =
      Path.join([:code.root_dir(), "erts-#{:erlang.system_info(:version)}", "include"])

    assert {:ok, %{archive: archive}} =
             CppArchive.build(spec, :ios_device, out_dir: tmp, erts_include: erts_include)

    {undefined, 0} = System.cmd("xcrun", ["-sdk", "iphoneos", "nm", "-u", archive])

    allow_enif =
      undefined
      |> String.split("\n", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.filter(&String.starts_with?(&1, "_enif_"))
      |> Enum.uniq()
      |> Enum.map(&"-Wl,-U,#{&1}")

    # What the app's link supplies besides the archive: the manifest's
    # frameworks, Foundation/CoreFoundation and the ObjC runtime (mob core's
    # link), libc++ (clang++).
    frameworks =
      Enum.flat_map(
        manifest.ios.frameworks ++ ["Foundation", "CoreFoundation"],
        &["-framework", &1]
      )

    args =
      ["-sdk", "iphoneos", "clang++", "-arch", "arm64", "-miphoneos-version-min=17.0"] ++
        ["-dynamiclib", "-Wl,-all_load", archive, "-lobjc"] ++
        frameworks ++ allow_enif ++ ["-o", Path.join(tmp, "probe.dylib")]

    {out, status} = System.cmd("xcrun", args, stderr_to_stdout: true)
    assert status == 0, "linking #{archive} without dead-stripping failed:\n#{out}"
  end
end
