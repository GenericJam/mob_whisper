// ggml's CPU backend needs exactly one architecture's quantised kernels. The
// cpp_archive build compiles one source list for every Android ABI (arm64,
// armv7, x86_64 emulator), so the choice is made here by the compiler's target.
#if defined(__aarch64__) || defined(__arm__)
#include "whisper.cpp/ggml/src/ggml-cpu/arch/arm/quants.c"
#elif defined(__x86_64__)
#include "whisper.cpp/ggml/src/ggml-cpu/arch/x86/quants.c"
#else
#error "mob_whisper: no ggml kernels vendored for this architecture"
#endif
