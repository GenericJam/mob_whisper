# Changelog

All notable changes to **mob_whisper** are documented here.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning: [SemVer](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Added
- **On-device self-test** (MOB-411). `MobWhisper.SelfTest` implements
  `Mob.Plugin.SelfTest` and is declared in the manifest as `selftest:`. It
  asks the NIF three things that need no model and no microphone:
  `nif_loaded/0` is `true`, `load_model/1` on a missing path answers
  `{:error, :load_failed}` (whisper.cpp ran), `capture_stop/0` while idle
  answers `{:error, :not_capturing}` (the capture backend is linked). Run it
  with `mix mob.selftest` from a host app (mob_dev 0.7.17). Requires mob
  0.9.15.

## [0.1.0] - 2026-10-03

### Added
- **Offline speech-to-text as a `MobSpeech` engine** (`engine: MobWhisper`,
  MOB-381): records 16 kHz mono from the microphone while listening (AAudio on
  Android, AudioQueue on iOS) and transcribes with whisper.cpp v1.9.4 (CPU,
  vendored) when stopped. Sends `{:speech, :state, :listening}` then one
  `{:speech, :final, text}` or `{:speech, :error, reason}`; cancel aborts a
  running transcription.
- Models `:base_en` (default, base.en q5_1, 59.7 MB) and `:tiny_en` (tiny.en
  q8_0, 43.6 MB) downloaded on first use from a pinned Hugging Face revision and
  SHA-256 checked; `{:file, path}` for your own. `MobWhisper.prefetch/1`
  (`notify: pid` gets `{:mob_whisper, :model, :ready | {:error, reason}}`, e.g.
  to tell the user a download failed), `MobWhisper.transcribe/2`,
  `MobWhisper.status/0`.
- Device-verified on a Moto G 2021 (Android 11, Snapdragon 662): Mac-spoken
  sentences transcribed correctly, 1.4-2.6 s from stop to text for 5-10 s of
  speech with `:base_en`. iOS builds but is not device-verified.
- Requires mob_dev ≥ 0.7.13 (cpp_archive C sources and x86_64).
