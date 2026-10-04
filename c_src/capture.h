// Microphone capture for mob_whisper: one process-wide recording at a time,
// returned as 16 kHz mono signed 16-bit PCM (what whisper.cpp consumes).
//
// Implementations: capture_android.cpp (AAudio, resolved with dlopen so the
// app needs no extra link flag) and capture_ios.mm (AudioQueue + AVAudioSession).
#pragma once

#include <cstdint>
#include <vector>

namespace mob_whisper {

// Longest recording kept; samples past this are dropped (a stuck button must
// not grow memory without bound). 120 s of 16 kHz s16 is ~3.8 MB.
constexpr int kMaxSeconds = 120;
constexpr int kTargetRate = 16000;

// Start capturing. Returns nullptr on success, otherwise the reason as an
// atom name: "busy" (already capturing), "unavailable" (no audio API),
// "permission" (the OS refused the microphone), "audio" (any other failure).
const char *capture_start();

// Stop capturing and move the recording (16 kHz mono s16) into `out`.
// Returns nullptr on success, "not_capturing", or "audio" when the stream
// failed mid-recording (the truncated audio is discarded).
const char *capture_stop(std::vector<int16_t> &out);

// Down-mix is done by the platform code; this converts a mono recording made
// at `rate` Hz to 16 kHz. Averages each output sample's input window when
// downsampling (a box low-pass: enough for speech at 44.1/48 kHz), linear
// interpolation when upsampling.
std::vector<int16_t> resample_to_16k(const std::vector<int16_t> &in, int rate);

}  // namespace mob_whisper
