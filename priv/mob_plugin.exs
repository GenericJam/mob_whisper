whisper = "c_src/whisper.cpp"

# whisper.cpp + ggml (CPU backend only) plus the NIF and the platform's mic
# capture. Same list for both platforms except the capture source; the
# ggml_arch_* wrappers pick ARM or x86 kernels by compile target (Android
# builds arm64, armv7 and the x86_64 emulator from this one list).
# ggml-backend-dl.cpp stays in although no backend is ever dlopen'd:
# ggml-backend-reg.cpp references its dl_* helpers, and a final link that
# doesn't dead-strip (mix mob.release --ios) fails without them (MOB-470).
common_sources =
  [
    "c_src/mob_whisper_nif.cpp",
    "c_src/resample.cpp",
    "c_src/ggml_arch_quants.c",
    "c_src/ggml_arch_repack.cpp",
    "#{whisper}/src/whisper.cpp"
  ] ++
    Enum.map(
      ~w(ggml.c ggml.cpp ggml-alloc.c ggml-backend.cpp ggml-backend-dl.cpp ggml-backend-meta.cpp
         ggml-backend-reg.cpp ggml-opt.cpp ggml-quants.c ggml-threading.cpp gguf.cpp),
      &"#{whisper}/ggml/src/#{&1}"
    ) ++
    Enum.map(
      ~w(ggml-cpu.c ggml-cpu.cpp ops.cpp vec.cpp binary-ops.cpp unary-ops.cpp repack.cpp
         traits.cpp quants.c iqp.cpp),
      &"#{whisper}/ggml/src/ggml-cpu/#{&1}"
    )

includes = [
  "c_src",
  "#{whisper}/include",
  "#{whisper}/src",
  "#{whisper}/ggml/include",
  "#{whisper}/ggml/src",
  "#{whisper}/ggml/src/ggml-cpu"
]

# What whisper.cpp's CMake build defines for a CPU-only static build
# (GGML_NATIVE=OFF: baseline armv8-a NEON, so it runs on Cortex-A53/A73 phones).
defines = [
  "-O3",
  "-DNDEBUG",
  "-DGGML_USE_CPU",
  "-DGGML_USE_CPU_REPACK",
  "-DGGML_SCHED_MAX_COPIES=4",
  "-D_XOPEN_SOURCE=600",
  ~s(-DWHISPER_VERSION="1.9.4"),
  "-fvisibility=hidden",
  "-ffunction-sections",
  "-fdata-sections"
]

android_defines = ["-D_GNU_SOURCE"]
ios_defines = ["-D_DARWIN_C_SOURCE"]

nif = fn platform, capture_source ->
  %{
    # The driver table derives the init symbol as <module>_nif_init, and
    # -DSTATIC_ERLANG_NIF_LIBNAME makes ERL_NIF_INIT emit exactly that.
    module: :mob_whisper_nif,
    lang: :cpp_archive,
    platform: platform,
    sources: common_sources ++ [capture_source],
    includes: includes,
    # .c sources (ggml) get the cflags, everything else the cxxflags.
    cxxflags: ["-std=c++17", "-DSTATIC_ERLANG_NIF_LIBNAME=mob_whisper_nif"] ++ defines,
    cflags: ["-std=gnu11"] ++ defines,
    cxxflags_android: android_defines,
    cflags_android: android_defines,
    cxxflags_ios: ios_defines,
    cflags_ios: ios_defines,
    nm_symbol: "mob_whisper_nif_nif_init"
  }
end

%{
  name: :mob_whisper,
  mob_version: "~> 0.9",
  plugin_spec_version: 1,
  # On-device proof for `mix mob.selftest` / mob_ci: three NIF answers that
  # need no model and no microphone (see Mob.Plugin.SelfTest).
  selftest: MobWhisper.SelfTest,
  nifs: [
    nif.(:android, "c_src/capture_android.cpp"),
    nif.(:ios, "c_src/capture_ios.mm")
  ],
  android: %{
    # The :microphone runtime permission itself is mob core's
    # (Mob.Permissions); this only makes sure the manifest declares it.
    permissions: ["android.permission.RECORD_AUDIO"]
  },
  ios: %{
    # NSMicrophoneUsageDescription is owned by the host template (mob core);
    # declaring it here would collide in the plist merge.
    frameworks: ["AVFoundation", "AudioToolbox"]
  },
  host_requirements: [
    "mob_whisper downloads its speech model (about 60 MB for :base_en) on first use over " <>
      "HTTPS. On Android the BEAM has no system CA store: call Mob.Certs.load_cacerts!/1 " <>
      "at boot (see Mob.Certs), or set config :mob_whisper, :model to {:file, path} for a " <>
      "model you ship yourself."
  ]
}
