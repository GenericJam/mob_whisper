// iOS microphone capture via AudioQueue, which converts the hardware format
// to 16 kHz mono s16 itself. AVAudioSession is switched to PlayAndRecord for
// the recording and restored to the previous category afterwards.
//
// Manual retain/release: the cpp_archive build compiles every source of the
// NIF with one flag set, and the C++ sources don't take -fobjc-arc.
#include "capture.h"

#import <AVFoundation/AVFoundation.h>
#include <AudioToolbox/AudioToolbox.h>

#include <atomic>
#include <mutex>

#if __has_feature(objc_arc)
#error "capture_ios.mm uses manual retain/release; build it without -fobjc-arc"
#endif

namespace mob_whisper {
namespace {

constexpr int kBuffers = 3;
constexpr UInt32 kBufferBytes = kTargetRate / 10 * sizeof(int16_t);  // 100 ms

std::mutex g_ctl;  // serialises capture_start/capture_stop
std::mutex g_mu;   // guards g_samples between the queue thread and capture_stop
AudioQueueRef g_queue = nullptr;
std::atomic<bool> g_running{false};
std::vector<int16_t> g_samples;
NSString *g_prev_category = nil;
NSString *g_prev_mode = nil;
AVAudioSessionCategoryOptions g_prev_options = 0;

void on_input(void *, AudioQueueRef queue, AudioQueueBufferRef buffer, const AudioTimeStamp *,
              UInt32, const AudioStreamPacketDescription *) {
    const size_t max_samples = static_cast<size_t>(kTargetRate) * kMaxSeconds;
    const int16_t *data = static_cast<const int16_t *>(buffer->mAudioData);
    const size_t n = buffer->mAudioDataByteSize / sizeof(int16_t);
    {
        std::lock_guard<std::mutex> lock(g_mu);
        for (size_t i = 0; i < n && g_samples.size() < max_samples; i++) g_samples.push_back(data[i]);
    }
    if (g_running.load()) AudioQueueEnqueueBuffer(queue, buffer, 0, nullptr);
}

void restore_session() {
    @autoreleasepool {
        AVAudioSession *s = [AVAudioSession sharedInstance];
        [s setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil];
        if (g_prev_category) {
            [s setCategory:g_prev_category
                      mode:(g_prev_mode ?: AVAudioSessionModeDefault)
                   options:g_prev_options
                     error:nil];
        }
        [g_prev_category release];
        [g_prev_mode release];
        g_prev_category = nil;
        g_prev_mode = nil;
    }
}

}  // namespace

const char *capture_start() {
    std::lock_guard<std::mutex> ctl(g_ctl);
    if (g_queue) return "busy";

    @autoreleasepool {
        AVAudioSession *s = [AVAudioSession sharedInstance];
        if (s.recordPermission != AVAudioSessionRecordPermissionGranted) return "permission";
        g_prev_category = [s.category copy];
        g_prev_mode = [s.mode copy];
        g_prev_options = s.categoryOptions;
        NSError *err = nil;
        BOOL ok = [s setCategory:AVAudioSessionCategoryPlayAndRecord
                            mode:AVAudioSessionModeMeasurement
                         options:AVAudioSessionCategoryOptionDefaultToSpeaker |
                                 AVAudioSessionCategoryOptionAllowBluetooth
                           error:&err];
        if (ok) ok = [s setActive:YES error:&err];
        if (!ok) {
            restore_session();
            return "audio";
        }
    }

    AudioStreamBasicDescription fmt = {};
    fmt.mSampleRate = kTargetRate;
    fmt.mFormatID = kAudioFormatLinearPCM;
    fmt.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked;
    fmt.mBytesPerPacket = 2;
    fmt.mFramesPerPacket = 1;
    fmt.mBytesPerFrame = 2;
    fmt.mChannelsPerFrame = 1;
    fmt.mBitsPerChannel = 16;

    AudioQueueRef queue = nullptr;
    // NULL run loop: the queue calls back on its own internal thread.
    if (AudioQueueNewInput(&fmt, on_input, nullptr, nullptr, kCFRunLoopCommonModes, 0, &queue) != noErr) {
        restore_session();
        return "audio";
    }
    {
        std::lock_guard<std::mutex> lock(g_mu);
        g_samples.clear();
        g_samples.reserve(static_cast<size_t>(kTargetRate) * 10);
    }
    for (int i = 0; i < kBuffers; i++) {
        AudioQueueBufferRef buf = nullptr;
        if (AudioQueueAllocateBuffer(queue, kBufferBytes, &buf) == noErr) {
            AudioQueueEnqueueBuffer(queue, buf, 0, nullptr);
        }
    }
    g_running.store(true);
    if (AudioQueueStart(queue, nullptr) != noErr) {
        g_running.store(false);
        AudioQueueDispose(queue, true);
        restore_session();
        return "audio";
    }
    g_queue = queue;
    return nullptr;
}

const char *capture_stop(std::vector<int16_t> &out) {
    std::lock_guard<std::mutex> ctl(g_ctl);
    if (!g_queue) return "not_capturing";

    g_running.store(false);
    AudioQueueStop(g_queue, true);  // synchronous: no callback runs after this
    AudioQueueDispose(g_queue, true);
    g_queue = nullptr;
    restore_session();

    std::lock_guard<std::mutex> lock(g_mu);
    out.swap(g_samples);
    std::vector<int16_t>().swap(g_samples);
    return nullptr;
}

}  // namespace mob_whisper
