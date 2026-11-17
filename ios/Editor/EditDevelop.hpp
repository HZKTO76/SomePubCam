// P665 «Проявка» (Android gallery/editor/EditDevelop.java), header-only C++: the RGB a DNG of ours gives the camera's post pipeline
// (Engine/post/DevelopRun.hpp) - its level times the record's headroom, demosaiced:
// - the preview: the DNG binned so that a 2x2 cell of it is one pixel of at most PREVIEW_SIDE (a cell's R, mean G, B; superpixel);
// - the copy: the whole DNG demosaiced (Malvar-He-Cutler, mhc), as IEEE halves above HALF_ABOVE pixels.
// P696: a DNG without the record is developed from its own tags when the developer can take it (refusal, facts: the record made by
// Engine/post/DevelopDefaults.hpp).
#pragma once

#include "DngRaw.hpp"
#include "../Engine/post/DevelopDefaults.hpp"

#include <algorithm>
#include <array>
#include <cctype>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <functional>
#include <limits>
#include <optional>
#include <string>
#include <thread>
#include <vector>

namespace scam_edit {
namespace develop {

/// P696: a DNG's Software of SCAMERA (DngMetadata.software: "SCAMERA <version> (<code>) <commit>")
inline bool ours(const DngRaw::Info& info) {
    std::string s = info.software;
    size_t a = 0, b = s.size();
    while (a < b && uint8_t(s[a]) <= ' ') a++;
    while (b > a && uint8_t(s[b - 1]) <= ' ') b--;
    s = s.substr(a, b - a);
    if (s.size() < 7) return false;
    for (size_t i = 0; i < 7; i++) if (std::toupper(uint8_t(s[i])) != "SCAMERA"[i]) return false;
    return true;
}

/// The clockwise turn of the EXIF / TIFF orientation (1, 6, 3, 8; anything unknown upright), -1 for a mirrored one
inline int rotation(int orientation) {
    switch (orientation) {
        case 6: return 90;
        case 3: return 180;
        case 8: return 270;
        case 2: case 4: case 5: case 7: return -1;
        default: return 0;
    }
}

/// P696 / 6a4d3a46: why the developer cannot take a DNG without a record, none when it can: our Linear DNGs and single-site Bayer
/// DNGs (the demosaic here; a Quad DNG is not one, nor another app's LinearRaw) with an orientation without a mirror (the
/// pipeline's turn); a Bayer DNG of another app also needs its colour: a ColorMatrix and the as-shot white.
inline std::optional<std::string> refusal(const DngRaw::Info& info) {
    if (info.kind != DngRaw::KIND_BAYER && !(info.kind == DngRaw::KIND_RGB && ours(info))) return std::string("not a Bayer mosaic");
    if (info.cell != 1) return std::string("a Quad mosaic");
    if (rotation(info.orientation) < 0) return "a mirrored orientation " + std::to_string(info.orientation);
    if (!ours(info) && (!info.colour.hasMatrices() || !info.asShotGiven))
        return std::string("another app's DNG without its colour matrix or as-shot white");
    return std::nullopt;
}

/// Java's (int) Math.round(double): floor(v + 0.5) as a long (NaN 0), then its low 32 bits
inline int javaRoundInt(double v) {
    if (std::isnan(v)) return 0;
    const double r = std::floor(v + 0.5);
    const long long l = r >= 9.2233720368547758e18 ? std::numeric_limits<long long>::max()
                        : r <= -9.2233720368547758e18 ? std::numeric_limits<long long>::min() : (long long)r;
    return int(uint32_t(uint64_t(l)));
}

/// P696 EditDevelop.facts: what the DNG says for its record (DevelopDefaults::Facts)
inline scam_post::DevelopDefaults::Facts facts(const DngRaw::Info& info) {
    scam_post::DevelopDefaults::Facts f;
    const auto size = info.size(1);
    f.width = size[0];
    f.height = size[1];
    const DngColor& colour = info.colour;
    const std::vector<double>& n = colour.asShotNeutral;
    f.neutral = {float(n[0]), float(n[1]), float(n[2])};
    if (colour.hasMatrices()) {
        const std::vector<double> m = colour.cameraToXyzD50(n);
        bool finite = m.size() >= 9;
        std::vector<float> out(9);
        for (size_t i = 0; finite && i < 9; i++) {
            out[i] = float(m[i]);
            finite = std::isfinite(out[i]);
        }
        if (finite) f.cameraToXyzD50 = out;
        const std::vector<double> xy = colour.estimateXy(n);
        if (!xy.empty()) f.sceneCct = float(DngColor::cctDuv(xy)[0]);
    }
    f.noiseProfile = info.noiseProfile;
    f.iso = javaRoundInt(info.iso);
    f.exposureTime = info.exposureTime;
    f.fNumber = float(info.fNumber);
    f.focalMm = float(info.focalLength);
    f.rotationDeg = std::max(0, rotation(info.orientation));
    // P165: a SCAMERA merged DNG holds the RGB over its headroom, BaselineExposure = log2 of it; another app's exposure tag is its
    // own look, not a headroom
    f.headroom = ours(info) && info.baselineExposure > 0 && info.baselineExposure < 8 ? float(std::pow(2.0, info.baselineExposure)) : 1.f;
    f.whiteLevel = javaRoundInt(info.whiteLevel);
    f.blackLevel = float(info.blackLevel);
    f.software = info.software;
    f.shadingMap = info.shadingMap;
    f.shadingW = info.shadingW;
    f.shadingH = info.shadingH;
    return f;
}

/// the preview develop's longer side at most (px)
constexpr int PREVIEW_SIDE = 2048;
/// above this many pixels the RGB goes to the pipeline as halves (6 B a pixel instead of 12)
constexpr long long HALF_ABOVE = 16000000LL;

/// ParallelWork.forEach: rows split over the cores
inline void forEachRow(int rows, const std::function<void(int)>& body) {
    const int n = std::max(1, std::min(rows, int(std::thread::hardware_concurrency())));
    if (n <= 1) {
        for (int y = 0; y < rows; y++) body(y);
        return;
    }
    std::vector<std::thread> pool;
    for (int t = 0; t < n; t++)
        pool.emplace_back([&, t] {
            for (int y = t; y < rows; y += n) body(y);
        });
    for (std::thread& th : pool) th.join();
}

/// the colour (0 R, 1 G, 2 B) of the mosaic at (x, y) for DngRaw's phase codes (RGGB, GRBG, GBRG, BGGR)
inline int colour(int phase, int x, int y) {
    const int i = ((y & 1) << 1) | (x & 1);
    switch (phase) {
        case DngRaw::GRBG: return i == 1 ? 0 : i == 2 ? 2 : 1;
        case DngRaw::GBRG: return i == 1 ? 2 : i == 2 ? 0 : 1;
        case DngRaw::BGGR: return i == 0 ? 2 : i == 3 ? 0 : 1;
        default: return i == 0 ? 0 : i == 3 ? 2 : 1;
    }
}

/// the bin whose 2x2 cells give at most PREVIEW_SIDE on the longer side
inline int binFor(int w, int h) {
    int bin = 1;
    while (std::max(w, h) / (2 * bin) > PREVIEW_SIDE && bin < 16) bin *= 2;
    return bin;
}

/// RGB of every 2x2 cell (its R, the mean of its G, its B) times gain: (w / 2) x (h / 2) float pixels
inline std::vector<float> superpixel(const std::vector<float>& mosaic, int w, int h, int phase, float gain) {
    const int ow = w / 2, oh = h / 2;
    std::vector<float> out(size_t(ow) * oh * 3);
    forEachRow(oh, [&](int y) {
        for (int x = 0; x < ow; x++) {
            float r = 0, g = 0, b = 0;
            for (int k = 0; k < 4; k++) {
                const int sx = 2 * x + (k & 1), sy = 2 * y + (k >> 1);
                const float v = mosaic[size_t(sy) * w + sx];
                const int c = colour(phase, sx, sy);
                if (c == 0) r = v;
                else if (c == 2) b = v;
                else g += v;
            }
            const size_t o = (size_t(y) * ow + x) * 3;
            out[o] = r * gain;
            out[o + 1] = g * .5f * gain;
            out[o + 2] = b * gain;
        }
    });
    return out;
}

/// IEEE half of v (round to nearest even; above the largest half: infinity; NaN kept)
inline uint16_t toHalf(float v) {
    uint32_t bits;
    std::memcpy(&bits, &v, 4);
    const uint32_t sign = (bits >> 16) & 0x8000;
    int exp = int((bits >> 23) & 0xFF);
    uint32_t mant = bits & 0x7FFFFF;
    if (exp == 0xFF) return uint16_t(sign | 0x7C00 | (mant != 0 ? 0x200 : 0));
    exp = exp - 127 + 15;
    if (exp >= 0x1F) return uint16_t(sign | 0x7C00);
    if (exp <= 0) {
        if (exp < -10) return uint16_t(sign);
        mant |= 0x800000;
        const int shift = 14 - exp;
        uint32_t h = mant >> shift;
        const uint32_t rem = mant & ((1u << shift) - 1), halfway = 1u << (shift - 1);
        if (rem > halfway || (rem == halfway && (h & 1) != 0)) h++;
        return uint16_t(sign | h);
    }
    uint32_t h = (uint32_t(exp) << 10) | (mant >> 13);
    const uint32_t rem = mant & 0x1FFF;
    if (rem > 0x1000 || (rem == 0x1000 && (h & 1) != 0)) h++;
    return uint16_t(sign | h);
}

/// the mirror of i into 0..n-1 about the edge sample (keeps the CFA parity)
inline int mirror(int i, int n) {
    if (i < 0) i = -i;
    if (i >= n) i = 2 * (n - 1) - i;
    return std::max(0, std::min(n - 1, i));
}

inline float at(const float* m, int w, int h, int x, int y) { return m[size_t(mirror(y, h)) * w + mirror(x, w)]; }

/// 6a4d3a46 EditDevelop.preview of a Linear DNG: the bin that gives at most PREVIEW_SIDE on the longer side (no 2x2 cell)
inline int linearBinFor(int w, int h) { return (std::max(w, h) - 1) / PREVIEW_SIDE + 1; }

/// EditDevelop.preview of a Linear DNG: its decoded RGB (DngRaw::decodeForDevelop's floats) times the record's headroom
inline std::vector<float> linearPreview(std::vector<float> rgb, float headroom) {
    for (float& v : rgb) v *= headroom;
    return rgb;
}

/// EditDevelop.full of a Linear DNG: the whole RGB times the headroom as the pipeline takes it - float32 RGB (12 B a pixel) or,
/// with half, IEEE halves (6 B a pixel), native order - decoded straight into it (DngRaw::decodeRgbForDevelop)
inline std::vector<uint8_t> linearFull(const uint8_t* data, size_t size, int w, int h, bool fromRecord, bool list1, float headroom, bool half) {
    std::vector<uint8_t> out(size_t(w) * h * (half ? 6 : 12));
    uint8_t* base = out.data();
    const DngRaw::RgbSink sink = half ? DngRaw::RgbSink([base, headroom](size_t i, float v) {
        const uint16_t hv = toHalf(v * headroom);
        std::memcpy(base + i * 2, &hv, 2);
    })
                                      : DngRaw::RgbSink([base, headroom](size_t i, float v) {
        const float f = v * headroom;
        std::memcpy(base + i * 4, &f, 4);
    });
    DngRaw::decodeRgbForDevelop(data, size, w, h, fromRecord, list1, sink);
    return out;
}

/// one pixel of mhc (without the gain) into out
inline void mhcAt(const float* m, int w, int h, int phase, int x, int y, float out[3]) {
    const int c = colour(phase, x, y);
    const float v = at(m, w, h, x, y);
    if (c == 1) {
        out[1] = v;
        // the colour to the left / right of this green
        const int horizontal = colour(phase, x + 1, y);
        const float n2 = at(m, w, h, x, y - 2) + at(m, w, h, x, y + 2), e2 = at(m, w, h, x - 2, y) + at(m, w, h, x + 2, y);
        const float d1 = at(m, w, h, x - 1, y - 1) + at(m, w, h, x + 1, y - 1) + at(m, w, h, x - 1, y + 1) + at(m, w, h, x + 1, y + 1);
        const float hor = at(m, w, h, x - 1, y) + at(m, w, h, x + 1, y), ver = at(m, w, h, x, y - 1) + at(m, w, h, x, y + 1);
        // the colour in this row: 5 C + 4 (W + E) - (W2 + E2) - diagonals + (N2 + S2) / 2, / 8; the other one transposed
        const float inRow = (5 * v + 4 * hor - e2 - d1 + .5f * n2) / 8.f;
        const float inCol = (5 * v + 4 * ver - n2 - d1 + .5f * e2) / 8.f;
        out[horizontal] = inRow;
        out[2 - horizontal] = inCol;
    } else {
        out[c] = v;
        const float g4 = at(m, w, h, x - 1, y) + at(m, w, h, x + 1, y) + at(m, w, h, x, y - 1) + at(m, w, h, x, y + 1);
        const float c4 = at(m, w, h, x - 2, y) + at(m, w, h, x + 2, y) + at(m, w, h, x, y - 2) + at(m, w, h, x, y + 2);
        const float d4 = at(m, w, h, x - 1, y - 1) + at(m, w, h, x + 1, y - 1) + at(m, w, h, x - 1, y + 1) + at(m, w, h, x + 1, y + 1);
        out[1] = (4 * v + 2 * g4 - c4) / 8.f;
        out[2 - c] = (6 * v + 2 * d4 - 1.5f * c4) / 8.f;
    }
}

/// Malvar-He-Cutler (2004) demosaic of the mosaic (w x h, DngRaw's phase) times gain, never below 0: the RGB as the pipeline takes
/// it - float32 RGB (12 B a pixel) or, with half, IEEE halves (6 B a pixel), native order; the borders mirror about the edge sample.
inline std::vector<uint8_t> mhc(const std::vector<float>& mosaic, int w, int h, int phase, float gain, bool half) {
    std::vector<uint8_t> out(size_t(w) * h * (half ? 6 : 12));
    const float* m = mosaic.data();
    forEachRow(h, [&](int y) {
        float rgb[3] = {0, 0, 0};
        uint8_t* row = out.data() + size_t(y) * w * (half ? 6 : 12);
        for (int x = 0; x < w; x++) {
            mhcAt(m, w, h, phase, x, y, rgb);
            for (int c = 0; c < 3; c++) {
                const float v = std::max(0.f, rgb[c] * gain);
                if (half) {
                    const uint16_t hv = toHalf(v);
                    std::memcpy(row + (size_t(x) * 3 + c) * 2, &hv, 2);
                } else {
                    std::memcpy(row + (size_t(x) * 3 + c) * 4, &v, 4);
                }
            }
        }
    });
    return out;
}

} // namespace develop
} // namespace scam_edit
