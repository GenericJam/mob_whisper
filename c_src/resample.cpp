#include "capture.h"

#include <algorithm>
#include <cmath>

namespace mob_whisper {

std::vector<int16_t> resample_to_16k(const std::vector<int16_t> &in, int rate) {
    if (rate == kTargetRate || rate <= 0 || in.empty()) return in;

    const double step = static_cast<double>(rate) / kTargetRate;  // input samples per output
    const size_t n_out = static_cast<size_t>(std::floor(in.size() / step));
    std::vector<int16_t> out;
    out.reserve(n_out);

    if (step > 1.0) {
        for (size_t i = 0; i < n_out; i++) {
            size_t lo = static_cast<size_t>(std::floor(i * step));
            size_t hi = std::min(in.size(), static_cast<size_t>(std::floor((i + 1) * step)));
            if (hi <= lo) hi = lo + 1;
            long sum = 0;
            for (size_t j = lo; j < hi; j++) sum += in[j];
            out.push_back(static_cast<int16_t>(sum / static_cast<long>(hi - lo)));
        }
    } else {
        for (size_t i = 0; i < n_out; i++) {
            double pos = i * step;
            size_t j = static_cast<size_t>(pos);
            double frac = pos - j;
            int a = in[j];
            int b = j + 1 < in.size() ? in[j + 1] : a;
            out.push_back(static_cast<int16_t>(std::lround(a + (b - a) * frac)));
        }
    }
    return out;
}

}  // namespace mob_whisper
