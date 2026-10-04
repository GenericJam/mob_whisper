// mob_whisper_nif — whisper.cpp speech-to-text + microphone capture for Mob.
//
// Statically linked into the app (cpp_archive, see priv/mob_plugin.exs); the
// Erlang stub is src/mob_whisper_nif.erl. Model load and capture start/stop
// (tens to ~150 ms) run on dirty IO; transcription (seconds of CPU) runs on a
// native thread and replies with a message, so it never holds a scheduler.
#include <erl_nif.h>

#include <atomic>
#include <cstring>
#include <mutex>
#include <new>
#include <string>
#include <system_error>
#include <thread>
#include <vector>

#include "capture.h"
#include "whisper.h"

#ifdef __ANDROID__
#include <android/log.h>
#endif

namespace {

struct Model {
    whisper_context *ctx = nullptr;
    std::mutex mu;  // one whisper_full at a time per context
    // Jobs are numbered from 1; abort/2 names the one to stop. A single slot
    // is enough: the server runs one session job at a time, and naming the
    // job (not "whatever runs next") means a stale abort can't hit a later
    // job and an early one still stops a job queued behind the mutex.
    std::atomic<uint64_t> next_id{0};
    std::atomic<uint64_t> abort_id{0};
};

ErlNifResourceType *g_model_type = nullptr;

void model_dtor(ErlNifEnv *, void *obj) {
    Model *m = static_cast<Model *>(obj);
    if (m->ctx) whisper_free(m->ctx);
    m->~Model();
}

ERL_NIF_TERM atom(ErlNifEnv *env, const char *name) { return enif_make_atom(env, name); }

ERL_NIF_TERM error(ErlNifEnv *env, const char *reason) {
    return enif_make_tuple2(env, atom(env, "error"), atom(env, reason));
}

ERL_NIF_TERM ok(ErlNifEnv *env, ERL_NIF_TERM value) {
    return enif_make_tuple2(env, atom(env, "ok"), value);
}

bool get_string(ErlNifEnv *env, ERL_NIF_TERM term, std::string &out) {
    ErlNifBinary bin;
    if (!enif_inspect_binary(env, term, &bin)) return false;
    out.assign(reinterpret_cast<const char *>(bin.data), bin.size);
    return out.find('\0') == std::string::npos;
}

// whisper.cpp/ggml log only errors, to logcat on Android; the rest is noise
// on a phone (per-call timings, model hyper-parameters).
void log_cb(enum ggml_log_level level, const char *text, void *) {
#ifdef __ANDROID__
    if (level == GGML_LOG_LEVEL_ERROR) __android_log_print(ANDROID_LOG_ERROR, "mob_whisper", "%s", text);
#else
    (void)level;
    (void)text;
#endif
}

// load_model(Path :: binary()) -> {ok, Model} | {error, load_failed | badarg}
ERL_NIF_TERM load_model(ErlNifEnv *env, int, const ERL_NIF_TERM argv[]) {
    std::string path;
    if (!get_string(env, argv[0], path)) return enif_make_badarg(env);

    whisper_context_params cparams = whisper_context_default_params();
    cparams.use_gpu = false;
    whisper_context *ctx = whisper_init_from_file_with_params(path.c_str(), cparams);
    if (!ctx) return error(env, "load_failed");

    void *mem = enif_alloc_resource(g_model_type, sizeof(Model));
    Model *m = new (mem) Model();
    m->ctx = ctx;
    ERL_NIF_TERM term = enif_make_resource(env, m);
    enif_release_resource(m);
    return ok(env, term);
}

// One transcription, run on its own native thread: a Mob app's BEAM has a
// single dirty CPU scheduler, and seconds of whisper inference there would
// stall every other dirty NIF (crypto, …) for the duration.
struct Job {
    Model *model;  // kept alive with enif_keep_resource until the job ends
    uint64_t id;
    std::vector<float> samples;
    std::string language;
    int threads;
    int audio_ctx;
    ErlNifPid caller;
    ErlNifEnv *msg_env;  // owns `ref` and the reply
    ERL_NIF_TERM ref;
};

bool aborted(const Job &job) { return job.model->abort_id.load() == job.id; }

bool should_abort(void *data) { return aborted(*static_cast<Job *>(data)); }

ERL_NIF_TERM run_job(Job &job) {
    Model *m = job.model;
    ErlNifEnv *env = job.msg_env;

    std::lock_guard<std::mutex> lock(m->mu);
    if (aborted(job)) return error(env, "cancelled");

    whisper_full_params p = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    p.n_threads = job.threads;
    p.language = job.language.c_str();
    p.detect_language = false;
    p.translate = false;
    p.no_context = true;
    p.no_timestamps = true;
    p.print_progress = false;
    p.print_realtime = false;
    p.print_special = false;
    p.print_timestamps = false;
    p.suppress_blank = true;
    p.suppress_nst = true;
    p.audio_ctx = job.audio_ctx;
    p.greedy.best_of = 1;
    p.abort_callback = should_abort;
    p.abort_callback_user_data = &job;

    int rc = whisper_full(m->ctx, p, job.samples.data(), static_cast<int>(job.samples.size()));
    if (aborted(job)) return error(env, "cancelled");
    if (rc != 0) return error(env, "transcribe_failed");

    std::string text;
    const int segments = whisper_full_n_segments(m->ctx);
    for (int i = 0; i < segments; i++) text += whisper_full_get_segment_text(m->ctx, i);

    ERL_NIF_TERM bin;
    unsigned char *buf = enif_make_new_binary(env, text.size(), &bin);
    std::memcpy(buf, text.data(), text.size());
    return ok(env, bin);
}

void job_thread(Job *job) {
    ERL_NIF_TERM result = run_job(*job);
    ERL_NIF_TERM msg = enif_make_tuple3(job->msg_env, atom(job->msg_env, "mob_whisper_result"),
                                        job->ref, result);
    enif_send(nullptr, &job->caller, job->msg_env, msg);
    enif_free_env(job->msg_env);
    enif_release_resource(job->model);
    delete job;
}

// transcribe(Model, Pcm, Language, Threads, AudioCtx) -> {ok, Ref, JobId} | {error, Reason}
//   Starts the transcription and returns at once; the calling process later
//   receives {mob_whisper_result, Ref, {ok, Text} | {error, cancelled | transcribe_failed}}.
//   abort(Model, JobId) cancels it.
//   Pcm: 16 kHz mono signed 16-bit little-endian samples.
//   Language: ISO code ("en"), "auto" to detect.
//   AudioCtx: encoder frames to run (0 = the full 30 s window); see
//             MobWhisper.Audio.audio_ctx/1.
ERL_NIF_TERM transcribe(ErlNifEnv *env, int, const ERL_NIF_TERM argv[]) {
    Model *m = nullptr;
    ErlNifBinary pcm;
    std::string language;
    int threads = 0, audio_ctx = 0;
    if (!enif_get_resource(env, argv[0], g_model_type, reinterpret_cast<void **>(&m)) ||
        !enif_inspect_binary(env, argv[1], &pcm) || pcm.size % 2 != 0 ||
        !get_string(env, argv[2], language) || !enif_get_int(env, argv[3], &threads) ||
        !enif_get_int(env, argv[4], &audio_ctx) || threads < 1 || audio_ctx < 0) {
        return enif_make_badarg(env);
    }

    Job *job = new Job();
    job->model = m;
    const uint64_t id = m->next_id.fetch_add(1) + 1;
    job->id = id;
    job->language = language;
    job->threads = threads;
    job->audio_ctx = audio_ctx;
    enif_self(env, &job->caller);
    job->samples.resize(pcm.size / 2);
    for (size_t i = 0; i < job->samples.size(); i++) {
        int16_t s;
        std::memcpy(&s, pcm.data + i * 2, 2);
        job->samples[i] = s / 32768.0f;
    }
    job->msg_env = enif_alloc_env();
    job->ref = enif_make_ref(job->msg_env);
    ERL_NIF_TERM ref = enif_make_copy(env, job->ref);

    enif_keep_resource(m);
    try {
        std::thread(job_thread, job).detach();
    } catch (const std::system_error &) {
        enif_release_resource(m);
        enif_free_env(job->msg_env);
        delete job;
        return error(env, "transcribe_failed");
    }
    // Not job->id: the detached thread may already have finished and freed it.
    return enif_make_tuple3(env, atom(env, "ok"), ref, enif_make_uint64(env, id));
}

// abort(Model, JobId) -> ok. Makes that transcribe/5 job reply {error, cancelled}
// promptly, whether it is running or still waiting for the model.
ERL_NIF_TERM abort_transcription(ErlNifEnv *env, int, const ERL_NIF_TERM argv[]) {
    Model *m = nullptr;
    ErlNifUInt64 id = 0;
    if (!enif_get_resource(env, argv[0], g_model_type, reinterpret_cast<void **>(&m)) ||
        !enif_get_uint64(env, argv[1], &id)) {
        return enif_make_badarg(env);
    }
    m->abort_id.store(id);
    return atom(env, "ok");
}

// capture_start() -> ok | {error, busy | unavailable | permission | audio}
ERL_NIF_TERM capture_start(ErlNifEnv *env, int, const ERL_NIF_TERM[]) {
    const char *err = mob_whisper::capture_start();
    return err ? error(env, err) : atom(env, "ok");
}

// capture_stop() -> {ok, Pcm} | {error, not_capturing}
ERL_NIF_TERM capture_stop(ErlNifEnv *env, int, const ERL_NIF_TERM[]) {
    std::vector<int16_t> samples;
    const char *err = mob_whisper::capture_stop(samples);
    if (err) return error(env, err);

    ERL_NIF_TERM bin;
    unsigned char *buf = enif_make_new_binary(env, samples.size() * 2, &bin);
    for (size_t i = 0; i < samples.size(); i++) {
        uint16_t u = static_cast<uint16_t>(samples[i]);
        buf[i * 2] = static_cast<unsigned char>(u & 0xff);
        buf[i * 2 + 1] = static_cast<unsigned char>(u >> 8);
    }
    return ok(env, bin);
}

ERL_NIF_TERM nif_loaded(ErlNifEnv *env, int, const ERL_NIF_TERM[]) { return atom(env, "true"); }

int load(ErlNifEnv *env, void **, ERL_NIF_TERM) {
    whisper_log_set(log_cb, nullptr);
    g_model_type = enif_open_resource_type(env, nullptr, "mob_whisper_model", model_dtor,
                                           ERL_NIF_RT_CREATE, nullptr);
    return g_model_type ? 0 : 1;
}

ErlNifFunc nif_funcs[] = {
    {"nif_loaded", 0, nif_loaded, 0},
    {"load_model", 1, load_model, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"transcribe", 5, transcribe, 0},
    {"abort", 2, abort_transcription, 0},
    {"capture_start", 0, capture_start, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"capture_stop", 0, capture_stop, ERL_NIF_DIRTY_JOB_IO_BOUND},
};

}  // namespace

ERL_NIF_INIT(mob_whisper_nif, nif_funcs, load, nullptr, nullptr, nullptr)
