// Android microphone capture via AAudio (API 26+).
//
// libaaudio is resolved with dlopen/dlsym rather than linked: the host's native
// build links the app library with a fixed set of system libs, and a plugin
// can't add -laaudio to it. The NDK header still supplies types and constants.
//
// A reader thread does blocking AAudioStream_read calls (no real-time data
// callback to keep lock-free), down-mixes to mono and appends to a buffer at
// the stream's actual rate; capture_stop() resamples to 16 kHz once.
#include "capture.h"

#include <aaudio/AAudio.h>
#include <android/log.h>
#include <dlfcn.h>

#include <atomic>
#include <mutex>
#include <thread>

namespace mob_whisper {
namespace {

#define LOGW(...) __android_log_print(ANDROID_LOG_WARN, "mob_whisper", __VA_ARGS__)

struct AAudioApi {
    decltype(&AAudio_createStreamBuilder) createStreamBuilder;
    decltype(&AAudioStreamBuilder_setDirection) setDirection;
    decltype(&AAudioStreamBuilder_setSampleRate) setSampleRate;
    decltype(&AAudioStreamBuilder_setChannelCount) setChannelCount;
    decltype(&AAudioStreamBuilder_setFormat) setFormat;
    decltype(&AAudioStreamBuilder_setSharingMode) setSharingMode;
    decltype(&AAudioStreamBuilder_setInputPreset) setInputPreset;  // API 28; may be null
    decltype(&AAudioStreamBuilder_openStream) openStream;
    decltype(&AAudioStreamBuilder_delete) builderDelete;
    decltype(&AAudioStream_requestStart) requestStart;
    decltype(&AAudioStream_requestStop) requestStop;
    decltype(&AAudioStream_read) read;
    decltype(&AAudioStream_close) close;
    decltype(&AAudioStream_getSampleRate) getSampleRate;
    decltype(&AAudioStream_getChannelCount) getChannelCount;
    decltype(&AAudio_convertResultToText) resultText;
};

const AAudioApi *api() {
    static AAudioApi a;
    static bool ok = [] {
        void *lib = dlopen("libaaudio.so", RTLD_NOW | RTLD_LOCAL);
        if (!lib) return false;
#define SYM(field, name) a.field = reinterpret_cast<decltype(a.field)>(dlsym(lib, #name))
        SYM(createStreamBuilder, AAudio_createStreamBuilder);
        SYM(setDirection, AAudioStreamBuilder_setDirection);
        SYM(setSampleRate, AAudioStreamBuilder_setSampleRate);
        SYM(setChannelCount, AAudioStreamBuilder_setChannelCount);
        SYM(setFormat, AAudioStreamBuilder_setFormat);
        SYM(setSharingMode, AAudioStreamBuilder_setSharingMode);
        SYM(setInputPreset, AAudioStreamBuilder_setInputPreset);
        SYM(openStream, AAudioStreamBuilder_openStream);
        SYM(builderDelete, AAudioStreamBuilder_delete);
        SYM(requestStart, AAudioStream_requestStart);
        SYM(requestStop, AAudioStream_requestStop);
        SYM(read, AAudioStream_read);
        SYM(close, AAudioStream_close);
        SYM(getSampleRate, AAudioStream_getSampleRate);
        SYM(getChannelCount, AAudioStream_getChannelCount);
        SYM(resultText, AAudio_convertResultToText);
#undef SYM
        return a.createStreamBuilder && a.setDirection && a.setSampleRate && a.setChannelCount &&
               a.setFormat && a.setSharingMode && a.openStream && a.builderDelete &&
               a.requestStart && a.requestStop && a.read && a.close && a.getSampleRate &&
               a.getChannelCount && a.resultText;
    }();
    return ok ? &a : nullptr;
}

std::mutex g_ctl;  // serialises capture_start/capture_stop (owns g_stream, g_reader, g_rate)
std::mutex g_mu;   // guards g_samples between the reader thread and capture_stop
AAudioStream *g_stream = nullptr;
std::thread g_reader;
std::atomic<bool> g_running{false};
std::vector<int16_t> g_samples;  // mono, at g_rate
int g_rate = kTargetRate;

void reader_loop(const AAudioApi *a, AAudioStream *stream, int channels, size_t max_samples) {
    std::vector<int16_t> buf(static_cast<size_t>(1024) * channels);
    while (g_running.load()) {
        // 100 ms timeout so a stop request is noticed promptly.
        aaudio_result_t n = a->read(stream, buf.data(), 1024, 100 * 1000 * 1000LL);
        if (n < 0) {
            LOGW("AAudioStream_read: %s", a->resultText(n));
            break;
        }
        std::lock_guard<std::mutex> lock(g_mu);
        for (aaudio_result_t f = 0; f < n && g_samples.size() < max_samples; f++) {
            int sum = 0;
            for (int c = 0; c < channels; c++) sum += buf[f * channels + c];
            g_samples.push_back(static_cast<int16_t>(sum / channels));
        }
    }
}

}  // namespace

const char *capture_start() {
    const AAudioApi *a = api();
    if (!a) return "unavailable";

    std::lock_guard<std::mutex> ctl(g_ctl);
    if (g_stream) return "busy";

    AAudioStreamBuilder *b = nullptr;
    if (a->createStreamBuilder(&b) != AAUDIO_OK) return "audio";
    a->setDirection(b, AAUDIO_DIRECTION_INPUT);
    a->setSampleRate(b, kTargetRate);
    a->setChannelCount(b, 1);
    a->setFormat(b, AAUDIO_FORMAT_PCM_I16);
    a->setSharingMode(b, AAUDIO_SHARING_MODE_SHARED);
    if (a->setInputPreset) a->setInputPreset(b, AAUDIO_INPUT_PRESET_VOICE_RECOGNITION);

    AAudioStream *stream = nullptr;
    aaudio_result_t r = a->openStream(b, &stream);
    a->builderDelete(b);
    if (r != AAUDIO_OK) {
        LOGW("AAudioStreamBuilder_openStream: %s", a->resultText(r));
        // Without RECORD_AUDIO the legacy (AudioRecord) path refuses to open.
        return r == AAUDIO_ERROR_NO_SERVICE || r == AAUDIO_ERROR_INTERNAL ? "permission" : "audio";
    }
    r = a->requestStart(stream);
    if (r != AAUDIO_OK) {
        LOGW("AAudioStream_requestStart: %s", a->resultText(r));
        a->close(stream);
        return "audio";
    }

    g_stream = stream;
    g_rate = a->getSampleRate(stream);
    int channels = a->getChannelCount(stream);
    if (channels < 1) channels = 1;
    {
        std::lock_guard<std::mutex> lock(g_mu);
        g_samples.clear();
        g_samples.reserve(static_cast<size_t>(g_rate) * 10);
    }
    g_running.store(true);
    g_reader = std::thread(reader_loop, a, stream, channels,
                           static_cast<size_t>(g_rate) * kMaxSeconds);
    return nullptr;
}

const char *capture_stop(std::vector<int16_t> &out) {
    const AAudioApi *a = api();
    std::lock_guard<std::mutex> ctl(g_ctl);
    if (!a || !g_stream) return "not_capturing";

    g_running.store(false);
    if (g_reader.joinable()) g_reader.join();
    a->requestStop(g_stream);
    a->close(g_stream);
    g_stream = nullptr;

    std::lock_guard<std::mutex> lock(g_mu);
    out = resample_to_16k(g_samples, g_rate);
    std::vector<int16_t>().swap(g_samples);
    return nullptr;
}

}  // namespace mob_whisper
