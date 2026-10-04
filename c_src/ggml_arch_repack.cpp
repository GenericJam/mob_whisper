// See ggml_arch_quants.c: one architecture's repack kernels per target.
#if defined(__aarch64__) || defined(__arm__)
#include "whisper.cpp/ggml/src/ggml-cpu/arch/arm/repack.cpp"
#elif defined(__x86_64__)
#include "whisper.cpp/ggml/src/ggml-cpu/arch/x86/repack.cpp"
#else
#error "mob_whisper: no ggml kernels vendored for this architecture"
#endif
