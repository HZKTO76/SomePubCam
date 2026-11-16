#pragma once

#include <algorithm>
#include <cmath>

namespace scam_highlight {

inline float smooth(float x) {
    const float t = std::clamp(x, 0.f, 1.f);
    return t * t * (3.f - 2.f * t);
}

// Base and Short are in the same linear units, with 1 at the base clip.
inline float transition(float level) {
    return smooth((level - 0.70f) / 0.12f) * (1.f - smooth((level - 0.88f) / 0.11f));
}

inline float confidence(float base, float shortLevel, float tolerance, bool baseClipped) {
    const float error = baseClipped ? std::max(0.f, base - shortLevel) : std::abs(base - shortLevel);
    const float allowance = std::max(tolerance, 0.025f + 0.05f * std::max(0.f, base));
    return 1.f - smooth((error - allowance) / (2.f * allowance));
}

inline float tapWeight(float delta, float sigma) {
    const float d = delta / std::max(sigma, 1e-6f);
    const float range = std::max(0.f, 1.f - d * d / 9.f);
    return range * range;
}

} // namespace scam_highlight
