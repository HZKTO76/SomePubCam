// DcpProfile / DcpProfiles.activeToXyz (processing/color): a matrix-only DNG camera profile (ColorMatrix1/2, ForwardMatrix1/2,
// the calibration illuminants; hue tables and tone curves only noted) and the active profile's camera RAW -> XYZ D50 for the
// shot's neutral. Java float / double arithmetic kept step by step. The iOS app passes the selected file's path in the prefs
// ("ios_dcp_path", PostSettings.json) beside pref_dcp_profile_key.
#pragma once

#include "../Settings.hpp"

#include <array>
#include <cmath>
#include <cstdint>
#include <algorithm>
#include <fstream>
#include <functional>
#include <iterator>
#include <optional>
#include <set>
#include <stdexcept>
#include <string>
#include <vector>

namespace scam_post {

struct DcpProfile {
    static constexpr size_t MAX_BYTES = 16u * 1024u * 1024u;
    using F9 = std::array<float, 9>;
    std::optional<F9> color1, color2, forward1, forward2;
    int light1 = 21, light2 = 21;
    bool hasLookTables = false;

    struct Invalid : std::runtime_error { using std::runtime_error::runtime_error; };

    static int temperature(int light) {
        switch (light) {
        case 1: return 5500; case 21: return 6504; case 17: case 3: return 2856; case 18: return 4874;
        case 19: return 6774; case 20: return 5503; case 22: return 7504; case 23: return 5003;
        case 9: return 5500; case 10: return 6500; case 11: return 7500; case 12: return 6430;
        case 13: return 5000; case 14: return 4230; case 15: return 3450; case 16: return 2925;
        default: throw Invalid("unknown illuminant: " + std::to_string(light));
        }
    }

    static DcpProfile parse(const std::vector<uint8_t>& bytes) {
        if (bytes.size() < 8 || bytes.size() > MAX_BYTES) throw Invalid("file size");
        bool little;
        if (bytes[0] == 'I' && bytes[1] == 'I') little = true;
        else if (bytes[0] == 'M' && bytes[1] == 'M') little = false;
        else throw Invalid("TIFF/DCP header");
        auto u16 = [&](size_t p) -> uint32_t {
            return little ? uint32_t(bytes[p]) | uint32_t(bytes[p + 1]) << 8 : uint32_t(bytes[p]) << 8 | uint32_t(bytes[p + 1]);
        };
        auto u32 = [&](size_t p) -> uint32_t {
            return little ? uint32_t(bytes[p]) | uint32_t(bytes[p + 1]) << 8 | uint32_t(bytes[p + 2]) << 16 | uint32_t(bytes[p + 3]) << 24
                          : uint32_t(bytes[p]) << 24 | uint32_t(bytes[p + 1]) << 16 | uint32_t(bytes[p + 2]) << 8 | uint32_t(bytes[p + 3]);
        };
        const size_t limit = bytes.size();
        auto range = [&](uint64_t p, uint64_t n) -> size_t {
            if (p > limit || n > limit - p) throw Invalid("data beyond the end of the file");
            return size_t(p);
        };
        const uint32_t magic = u16(2);
        if (magic != 42 && magic != 0x4352) throw Invalid("DCP signature");
        DcpProfile p;
        uint64_t offset = u32(4);
        std::set<uint64_t> visited;
        while (offset != 0) {
            if (visited.size() >= 16 || !visited.insert(offset).second) throw Invalid("IFD loop");
            const size_t pos = range(offset, 2);
            const uint32_t count = u16(pos);
            range(offset + 2, 12ull * count + 4);
            for (uint32_t i = 0; i < count; i++) {
                const size_t e = pos + 2 + 12 * size_t(i);
                const uint32_t tag = u16(e), type = u16(e + 2);
                const uint64_t n = u32(e + 4);
                if (tag == 50937 || tag == 50938 || tag == 50939 || tag == 50940 || tag == 50981 || tag == 50982) p.hasLookTables = true;
                if (tag == 50778 || tag == 50779) {
                    if (type != 3 || n != 1) throw Invalid("illuminant type");
                    const int light = int(u16(e + 8));
                    temperature(light); // an unsupported custom illuminant is refused, never guessed
                    if (tag == 50778) p.light1 = light; else p.light2 = light;
                }
                if (tag == 50721 || tag == 50722 || tag == 50964 || tag == 50965) {
                    if (n != 9 || (type != 5 && type != 10)) throw Invalid("a 3x3 matrix is required");
                    const size_t at = range(u32(e + 8), 72);
                    F9 m{};
                    for (size_t j = 0; j < 9; j++) {
                        const double num = type == 10 ? double(int32_t(u32(at + j * 8))) : double(u32(at + j * 8));
                        const double den = type == 10 ? double(int32_t(u32(at + j * 8 + 4))) : double(u32(at + j * 8 + 4));
                        if (den == 0 || !std::isfinite(num / den) || std::fabs(num / den) > 100) throw Invalid("matrix value");
                        m[j] = float(num / den);
                    }
                    if (!inverse(m)) throw Invalid("singular matrix");
                    if (tag == 50721) p.color1 = m;
                    else if (tag == 50722) p.color2 = m;
                    else if (tag == 50964) p.forward1 = m;
                    else p.forward2 = m;
                }
            }
            offset = u32(pos + 2 + size_t(count) * 12);
        }
        if (!p.color1) throw Invalid("no ColorMatrix1");
        if (!p.color2) { p.color2 = p.color1; p.light2 = p.light1; p.forward2 = p.forward1; }
        return p;
    }

    /// Camera neutral before white balance, e.g. [green/red, 1, green/blue]; nullopt where Java throws IllegalArgumentException.
    std::optional<F9> cameraToXyz(const float* neutral) const {
        for (int i = 0; i < 3; i++) if (!std::isfinite(neutral[i]) || neutral[i] <= 0) return std::nullopt;
        double t = .5;
        const double a = temperature(light1), z = temperature(light2);
        for (int i = 0; i < 16 && a != z; i++) {
            const auto inv = inverse(lerp(*color1, *color2, t));
            if (!inv) return std::nullopt;
            const auto xyz = map(*inv, neutral);
            const double sum = xyz[0] + xyz[1] + xyz[2], x = xyz[0] / sum, y = xyz[1] / sum; // a float sum (Java)
            const double n = (x - .3320) / (.1858 - y);
            const double kelvin = std::max(1667.0, std::min(25000.0, 449 * n * n * n + 3525 * n * n + 6823.3 * n + 5520.33));
            double next = (1 / kelvin - 1 / a) / (1 / z - 1 / a);
            if (!std::isfinite(next)) return std::nullopt;
            next = std::max(0.0, std::min(1.0, next));
            if (std::fabs(t - next) < .0001) { t = next; break; }
            t = (t + next) / 2;
        }
        static const float D50[3] = {.9642f, 1, .8249f};
        if (forward1 && forward2) {
            F9 f = lerp(*forward1, *forward2, t);
            // a forward matrix maps a balanced neutral to D50: small profile rounding errors normalised
            for (int r = 0; r < 3; r++) {
                const float sum = f[size_t(r * 3)] + f[size_t(r * 3 + 1)] + f[size_t(r * 3 + 2)];
                if (std::fabs(sum) < 1e-6f) return std::nullopt;
                for (int c = 0; c < 3; c++) f[size_t(r * 3 + c)] *= D50[r] / sum / neutral[c];
            }
            return f;
        }
        static const F9 BRADFORD{.8951f, .2664f, -.1614f, -.7502f, 1.7135f, .0367f, .0389f, -.0685f, 1.0296f};
        const auto toXyz = inverse(lerp(*color1, *color2, t));
        if (!toXyz) return std::nullopt;
        const auto white = map(*toXyz, neutral);
        const auto cone = map(BRADFORD, white.data()), target = map(BRADFORD, D50);
        F9 scale{};
        for (int i = 0; i < 3; i++) {
            if (cone[size_t(i)] <= 1e-6f) return std::nullopt;
            scale[size_t(i * 4)] = target[size_t(i)] / cone[size_t(i)];
        }
        const auto bInv = inverse(BRADFORD);
        if (!bInv) return std::nullopt;
        return multiply(multiply(*bInv, multiply(scale, BRADFORD)), *toXyz);
    }

    static F9 lerp(const F9& a, const F9& b, double t) {
        F9 r{};
        for (size_t i = 0; i < 9; i++) r[i] = float(a[i] * (1 - t) + b[i] * t);
        return r;
    }
    static F9 multiply(const F9& a, const F9& b) {
        F9 r{};
        for (int y = 0; y < 3; y++)
            for (int x = 0; x < 3; x++)
                for (int k = 0; k < 3; k++) r[size_t(y * 3 + x)] += a[size_t(y * 3 + k)] * b[size_t(k * 3 + x)];
        return r;
    }
    static std::array<float, 3> map(const F9& a, const float* v) {
        return {a[0] * v[0] + a[1] * v[1] + a[2] * v[2], a[3] * v[0] + a[4] * v[1] + a[5] * v[2], a[6] * v[0] + a[7] * v[1] + a[8] * v[2]};
    }
    static std::optional<F9> inverse(const F9& m) {
        F9 r{m[4] * m[8] - m[5] * m[7], m[2] * m[7] - m[1] * m[8], m[1] * m[5] - m[2] * m[4],
             m[5] * m[6] - m[3] * m[8], m[0] * m[8] - m[2] * m[6], m[2] * m[3] - m[0] * m[5],
             m[3] * m[7] - m[4] * m[6], m[1] * m[6] - m[0] * m[7], m[0] * m[4] - m[1] * m[3]};
        const float det = m[0] * r[0] + m[1] * r[3] + m[2] * r[6];
        if (!std::isfinite(det) || std::fabs(det) < 1e-8f) return std::nullopt;
        for (float& v : r) v /= det;
        return r;
    }
};

namespace DcpProfiles {
/// The active profile's camera -> XYZ D50 (nullopt: none chosen, unreadable or unusable for this neutral).
inline std::optional<DcpProfile::F9> activeToXyz(const float* neutral, const std::function<void(const std::string&)>& log) {
    const Settings& s = Settings::current();
    const std::string id = s.getString("pref_dcp_profile_key", "");
    const std::string path = s.getString("ios_dcp_path", "");
    if (id.empty() || path.empty()) return std::nullopt;
    try {
        std::ifstream in(path, std::ios::binary);
        if (!in) throw DcpProfile::Invalid("the file did not open");
        std::vector<uint8_t> bytes((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
        return DcpProfile::parse(bytes).cameraToXyz(neutral);
    } catch (const std::exception& e) {
        log(std::string("DCP: profile unavailable: ") + id + " (" + e.what() + ")");
        return std::nullopt;
    }
}
} // namespace DcpProfiles

} // namespace scam_post
