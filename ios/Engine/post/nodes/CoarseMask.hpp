// CoarseMask.java one to one. P713 (speed): the highlight landing's mask (why/hlmask.glsl, a gaussian of 1.2 % of the frame's
// width over the share of the ceiling on whyLow) on a coarser grid. A gaussian of sigma texels needs no more than ~sigma / 6 of its
// samples per sigma: the share is averaged over Plan::block x Plan::block whyLow texels (DECIMATE 1), the two blur passes run on that
// grid with the sigma that is left once the averaging block's and the bilinear read's spread are taken out, and the combine reads
// the result bilinearly through Plan::grid (HL_COARSE 1). The grid has Plan::margin texels on every side whose blocks lie outside
// the frame: their texels are the frame's edge texels (clamped), as the clamped gaussian on whyLow sees beyond its edges.
// tools/check_hlmask_coarse.py: the mask within 0.008 of the whyLow one (1 - 2 half-float steps of the share), the photo within one
// 8-bit level.
#pragma once

#include <algorithm>
#include <array>
#include <cmath>
#include <optional>

namespace scam_post {
namespace CoarseMask {

/// the blur's sigma on the coarse grid is about this many coarse texels (the block is sigma / this, rounded)
constexpr float TEXELS_PER_SIGMA = 6.f;
/// the largest block (a 200 MP whyLow of 8160 texels: sigma 98, block 8, sigma 12.2 coarse texels)
constexpr int MAX_BLOCK = 8;

/// one shot's coarse grid
struct Plan {
    /// whyLow texels a side of a block
    int block = 0;
    /// the coarse grid's size, margins included
    int width = 0, height = 0;
    /// coarse texels of margin on each side
    int margin = 0;
    /// whyLow texels per coarse texel along x and y (whyLow's size / the inner grid's: about block)
    float scaleX = 0.f, scaleY = 0.f;
    /// the gaussian's sigma in coarse texels
    float sigma = 0.f;
    /// the frame's uv to the grid's uv: uv * (x, y) + (z, w)
    std::array<float, 4> grid{};

    Plan(int block, int innerW, int innerH, int margin, float scaleX, float scaleY, float sigma)
        : block(block), width(innerW + 2 * margin), height(innerH + 2 * margin), margin(margin), scaleX(scaleX), scaleY(scaleY),
          sigma(sigma) {
        grid = {float(innerW) / float(width), float(innerH) / float(height), float(margin) / float(width), float(margin) / float(height)};
    }
};

/// Java's Math.round(float)
inline int roundF(float a) { return std::isnan(a) ? 0 : int(std::floor(double(a) + 0.5)); }

/// the coarse grid for a whyLow of lowW x lowH and a gaussian of sigma whyLow texels; none when it is off (on false) or the block
/// would be 1 (sigma under 9 texels: whyLow under ~750 texels wide)
inline std::optional<Plan> plan(int lowW, int lowH, float sigma, bool on) {
    if (!on || lowW <= 0 || lowH <= 0 || !(sigma > 0.f)) return std::nullopt;
    const int block = std::min(MAX_BLOCK, roundF(sigma / TEXELS_PER_SIGMA));
    if (block < 2) return std::nullopt;
    const int innerW = std::max(1, roundF(float(lowW) / float(block))), innerH = std::max(1, roundF(float(lowH) / float(block)));
    const float scaleX = float(lowW) / float(innerW), scaleY = float(lowH) / float(innerH);
    // the block's mean adds (k^2 - 1) / 12 to the variance, the bilinear read about k^2 / 12 on average
    const double variance = double(sigma) * double(sigma) - double(block * block - 1) / 12.0 - double(block * block) / 12.0;
    const float coarseSigma = float(std::sqrt(std::max(variance, 0.25)) / (0.5 * double(scaleX + scaleY)));
    const int margin = int(std::ceil(3.0 * double(coarseSigma))) + 1;
    return Plan(block, innerW, innerH, margin, scaleX, scaleY, coarseSigma);
}

} // namespace CoarseMask
} // namespace scam_post
