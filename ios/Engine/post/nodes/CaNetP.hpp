// CaNetP (processing/opengl/postpipeline/CaNetP.java): P493 «Подавление аберраций» «Нейросеть» - the colour-fringe net CaNetP v4 with
// the camera's P399 inside, as the GLES fragment passes of shaders/canet/canet_p.glsl right after scamrgb (and its clip band), where
// scamrgb's purpleFringe (P399) ran. MODE 4 (full: P399's weight, the gate) -> MODE 0 (half: 4 features) -> MODE 5 (half: the mean
// of w) -> c1 .. c5 (MODE 1, a draw per 4 output channels) -> c6 (MODE 2: the half-res chroma correction) -> MODE 3 (full: the
// gated correction at the pixel's own luminance). Weights: the app's canet/canetp_v4.bin beside the shaders (sha256 and size checked
// once); anything wrong: P399 in scamrgb, never neither.
#pragma once

#include "../GLCore.hpp"
#include "../Pipeline.hpp"
#include "../Settings.hpp"

#include <array>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <functional>
#include <fstream>
#include <iterator>
#include <map>
#include <mutex>
#include <optional>
#include <string>
#include <vector>

namespace scam_post {

namespace CaNetP {

inline const char* SHADER = "canet/canet_p";
inline const char* WEIGHTS_SHA256 = "8b9be75e5bac76408353fcf60954786d452d380b048ea7a5b07f1176d7e60386";
/// c1 .. c6: {cin, cout, k, dilation}
inline const int LAYERS[6][4] = {{8, 16, 3, 1}, {16, 16, 3, 1}, {16, 16, 3, 2}, {16, 16, 3, 4}, {32, 16, 1, 1}, {16, 2, 3, 1}};
constexpr int64_t MAX_PIXELS = 64000000LL;
constexpr int STRIP = 64;
inline const std::string NEURAL = "neural", CLASSIC = "classic";

inline int texels(const int* l) {
    const int og = (l[1] + 3) / 4;
    return l[2] * l[2] * l[0] * og + og;
}
inline int totalTexels() {
    int n = 0;
    for (const auto& l : LAYERS) n += texels(l);
    return n;
}

enum class Route { NONE, CLASSIC, NEURAL };

inline Route route(float purple, const std::string& method, int64_t pixels, bool ready) {
    if (!(purple > 0.f)) return Route::NONE;
    if (method == CLASSIC) return Route::CLASSIC;
    return ready && pixels > 0 && pixels <= MAX_PIXELS ? Route::NEURAL : Route::CLASSIC;
}

/// «Подавление аберраций» as stored; Android's default «Классическое» (DEFAULT_METHOD)
inline std::string method() { return Settings::current().hybridString("fringe_method", CLASSIC) == NEURAL ? NEURAL : CLASSIC; }

inline float clampf(float v, float lo, float hi) { return std::isnan(v) ? lo : std::max(lo, std::min(hi, v)); }
inline std::string num(float v) {
    char b[32];
    std::snprintf(b, sizeof b, "%.4f", double(v));
    return b;
}

/// «Настройки нейросети»; every default is the trained value
struct NetSettings {
    float strength = 1.f;
    int reach = 12;
    float hueLo = 205.f, nearLo = 1.5f, ybLo = 0.05f;
    bool green = true, glow = true, boost = true;
    float boostMin = 0.3f;
    bool noFlip = true;

    static NetSettings read() {
        const Settings& p = Settings::current();
        NetSettings s;
        s.strength = clampf(p.hybridValue("fringe_net_strength", 1.f), 0.f, 1.f);
        s.reach = p.hybridValue("fringe_net_reach", 12.f) >= 9.f ? 12 : 6;
        s.hueLo = clampf(p.hybridValue("fringe_net_hue", 205.f), 180.f, 260.f);
        s.nearLo = clampf(p.hybridValue("fringe_net_near", 1.5f), 1.1f, 4.f);
        s.ybLo = clampf(p.hybridValue("fringe_net_light", 0.05f), 0.02f, 0.6f);
        s.green = p.hybridSwitch("fringe_net_green", true);
        s.glow = p.hybridSwitch("fringe_net_glow", true);
        s.boost = p.hybridSwitch("fringe_net_boost", true);
        s.noFlip = p.hybridSwitch("fringe_net_noflip", true);
        return s;
    }
    std::vector<std::pair<std::string, std::string>> gateDefines() const {
        return {{"MODE", "4"}, {"HUE_LO", num(hueLo)}, {"GREEN", green ? "1" : "0"}, {"SRC_RULES", glow ? "1" : "0"},
                {"NEAR_LO", num(nearLo)}, {"YB_LO", num(ybLo)}, {"REACH", std::to_string(reach)}};
    }
    std::vector<std::pair<std::string, std::string>> applyDefines() const {
        return {{"MODE", "3"}, {"BOOST", boost ? "1" : "0"}, {"BOOST_MIN", num(boostMin)}, {"NO_FLIP", noFlip ? "1" : "0"}};
    }
    float strengthUniform(float purple) const { return clampf(strength * purple, 0.f, 1.f); }
};

inline std::vector<std::pair<std::string, std::string>> layerDefines(int i) {
    const int* l = LAYERS[i];
    return {{"MODE", i == 5 ? "2" : "1"}, {"CIN", std::to_string(l[0])}, {"K", std::to_string(l[2])}, {"COUT", std::to_string(l[1])},
            {"POOL", i == 1 ? "1" : "0"}, {"UPCAT", i == 4 ? "1" : "0"}, {"GF", "4"}};
}

// ---- SHA-256 (the weights' check)
inline std::string sha256(const std::vector<uint8_t>& data) {
    static const uint32_t K[64] = {
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be,
        0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa,
        0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, 0x27b70a85,
        0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
        0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f,
        0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2};
    uint32_t h[8] = {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19};
    std::vector<uint8_t> m(data);
    const uint64_t bits = uint64_t(data.size()) * 8;
    m.push_back(0x80);
    while (m.size() % 64 != 56) m.push_back(0);
    for (int i = 7; i >= 0; i--) m.push_back(uint8_t(bits >> (i * 8)));
    auto rotr = [](uint32_t x, int n) { return (x >> n) | (x << (32 - n)); };
    for (size_t off = 0; off < m.size(); off += 64) {
        uint32_t w[64];
        for (int i = 0; i < 16; i++)
            w[i] = uint32_t(m[off + size_t(i) * 4]) << 24 | uint32_t(m[off + size_t(i) * 4 + 1]) << 16 | uint32_t(m[off + size_t(i) * 4 + 2]) << 8
                   | uint32_t(m[off + size_t(i) * 4 + 3]);
        for (int i = 16; i < 64; i++) {
            const uint32_t s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
            const uint32_t s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16] + s0 + w[i - 7] + s1;
        }
        uint32_t a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7];
        for (int i = 0; i < 64; i++) {
            const uint32_t t1 = hh + (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) + ((e & f) ^ (~e & g)) + K[i] + w[i];
            const uint32_t t2 = (rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) + ((a & b) ^ (a & c) ^ (b & c));
            hh = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2;
        }
        h[0] += a; h[1] += b; h[2] += c; h[3] += d; h[4] += e; h[5] += f; h[6] += g; h[7] += hh;
    }
    std::string out;
    char buf[9];
    for (uint32_t v : h) { std::snprintf(buf, sizeof buf, "%08x", v); out += buf; }
    return out;
}

/// The weights' bytes as floats after the sha256 and layout checks (an exception names what is wrong)
inline std::vector<float> parse(const std::vector<uint8_t>& blob) {
    const std::string sha = sha256(blob);
    if (sha != WEIGHTS_SHA256) throw std::runtime_error("weights sha256 " + sha + " != " + WEIGHTS_SHA256);
    if (blob.size() != size_t(16) * size_t(totalTexels()))
        throw std::runtime_error("weights " + std::to_string(blob.size()) + " B != " + std::to_string(16 * totalTexels()) + " B of the layer table");
    std::vector<float> out(blob.size() / 4);
    std::memcpy(out.data(), blob.data(), blob.size()); // little endian on every iOS / host target
    for (float v : out) if (!std::isfinite(v)) throw std::runtime_error("weights: a non-finite value");
    return out;
}

/// The v4 weights, read once from <shaders>/../canet/canetp_v4.bin (nullptr: unusable, the reason in `error`)
inline const std::vector<float>* weights(const std::string& shadersRoot, std::string& error) {
    static std::mutex lock;
    static std::optional<std::vector<float>> cached;
    static std::string cachedError;
    std::lock_guard<std::mutex> g(lock);
    if (cached) return &*cached;
    std::string root = shadersRoot;
    while (!root.empty() && root.back() == '/') root.pop_back();
    const size_t slash = root.find_last_of('/');
    const std::string path = (slash == std::string::npos ? std::string(".") : root.substr(0, slash)) + "/canet/canetp_v4.bin";
    try {
        std::ifstream in(path, std::ios::binary);
        if (!in) throw std::runtime_error("no " + path);
        std::vector<uint8_t> blob((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
        cached = parse(blob);
        return &*cached;
    } catch (const std::exception& e) {
        cachedError = e.what();
        error = cachedError;
        return nullptr;
    }
}

inline void use(GLProg& g, const std::vector<std::pair<std::string, std::string>>& defines) {
    for (const auto& [k, v] : defines) g.setDefine(k, v);
    g.useAssetProgram(SHADER, false);
}

/// Every program of a shot compiled before scamrgb draws, so a GPU that cannot build one gets P399
inline bool prepare(GLProg& g, const NetSettings& s, const std::function<void(const std::string&)>& log) {
    try {
        std::string error;
        if (!weights(g.shadersRoot(), error)) {
            log("fringe net (P493): weights unusable (" + error + "), P399");
            return false;
        }
        use(g, s.gateDefines());
        use(g, {{"MODE", "0"}});
        use(g, {{"MODE", "5"}});
        for (int i = 0; i < 6; i++) use(g, layerDefines(i));
        use(g, s.applyDefines());
        g.closed = true;
        return true;
    } catch (const std::exception& e) {
        log(std::string("fringe net (P493): ") + e.what() + ", P399");
        return false;
    }
}

/// Units 0, 1, 2 ... in order (GLProg.setTexture steps by 2: 12 inputs and the weights would pass the GLES minimum of 16)
inline void bindUnit(GLProg& g, const std::string& name, GLTexture& t, int unit) {
    t.bind(GL_TEXTURE0 + GLenum(unit));
    g.setVar(name, unit);
}

inline std::optional<std::array<float, 9>> inverse3(const std::array<float, 9>& m) {
    const double a = m[0], b = m[1], c = m[2], d = m[3], e = m[4], f = m[5], g = m[6], h = m[7], i = m[8];
    const double det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g);
    if (std::fabs(det) < 1e-12) return std::nullopt;
    return std::array<float, 9>{float((e * i - f * h) / det), float((c * h - b * i) / det), float((b * f - c * e) / det),
                                float((f * g - d * i) / det), float((a * i - c * g) / det), float((c * d - a * f) / det),
                                float((d * h - e * g) / det), float((b * g - a * h) / det), float((a * e - b * d) / det)};
}

inline void renderUniforms(GLProg& g, const std::array<float, 9>& toRender, const std::array<float, 9>& fromRender, const std::vector<float>& neutral,
                           float invWhite, float strength) {
    g.setVar("toRenderU", std::vector<float>(toRender.begin(), toRender.end()));
    g.setVar("fromRenderU", std::vector<float>(fromRender.begin(), fromRender.end()));
    g.setVar("neutralU", neutral[0], neutral[1], neutral[2]);
    g.setVar("invWhiteU", invWhite);
    g.setVar("strengthU", strength);
}

/// The base frames' white in the render's units: scamrgb's P399 white (the first channel to clip, white-balanced) through render()
inline float renderWhite(const float* clipLo, const std::vector<float>& wp, const std::array<float, 9>& toRender) {
    float white = 1.f;
    if (clipLo && clipLo[1] > 0.f) {
        white = 3.4028235e38f;
        for (int c = 0; c < 3; c++) white = std::min(white, clipLo[c] / std::max(wp[size_t(c)], 1e-6f));
        white = std::max(white, 1e-6f);
    }
    const float luma[3] = {0.2126f, 0.7152f, 0.0722f};
    float y = 0.f;
    for (int r = 0; r < 3; r++) {
        float v = 0.f;
        for (int c = 0; c < 3; c++) v += toRender[size_t(3 * r + c)] * white * wp[size_t(c)];
        y += luma[r] * v;
    }
    return y > 1e-6f ? y : white;
}

/// The net on `in` (scamrgb's output) into `out`; the textures it makes are gone when it returns
inline void run(GLProg& g, GLTexture& in, GLTexture& out, PostPipeline& p, const float* clipLo, const NetSettings& s, float purple,
                const std::array<float, 9>& toRender) {
    const auto t0 = std::chrono::steady_clock::now();
    std::string error;
    const std::vector<float>* w = weights(g.shadersRoot(), error);
    if (!w) throw std::runtime_error("fringe net weights: " + error);
    const auto fromRender = inverse3(toRender);
    if (!fromRender) throw std::runtime_error("fringe net: singular colour matrix");
    const std::vector<float> wp = *p.mParameters.whitePoint;
    const float invWhite = 1.f / renderWhite(clipLo, wp, toRender);
    const float strength = s.strengthUniform(purple);
    const Point full = in.mSize, half{(full.x + 1) / 2, (full.y + 1) / 2}, quarter{(half.x + 1) / 2, (half.y + 1) / 2};
    std::vector<Texture> owned;
    auto tex = [&](Point size, int channels) {
        owned.push_back(makeTexture(size, GLFormat(DataType::FLOAT_16, channels), nullptr, GL_NEAREST, GL_CLAMP_TO_EDGE));
        return owned.back();
    };
    auto layer = [&](int i, const std::vector<Texture>& inputs, GLTexture& wt, Point size) {
        const int* l = LAYERS[i];
        const int groups = i == 5 ? 1 : (l[1] + 3) / 4;
        std::vector<Texture> res;
        for (int og = 0; og < groups; og++) {
            use(g, layerDefines(i));
            for (size_t k = 0; k < inputs.size(); k++) bindUnit(g, "In" + std::to_string(k), *inputs[k], int(k));
            bindUnit(g, "Wt", wt, int(inputs.size()));
            g.setVar("dilU", l[3]);
            if (i != 5) g.setVar("ogU", og);
            res.push_back(tex(size, i == 5 ? 2 : 4));
            g.drawBlocks(res.back());
        }
        return res;
    };
    auto drawStrips = [&](GLTexture& target) { target.BufferLoad(); g.drawBlocks(target.mSize.x, target.mSize.y, STRIP); };
    auto freeAll = [&](const std::vector<Texture>& ts) { for (const Texture& t : ts) if (t) t->close(); };
    try {
        std::vector<Texture> wt;
        for (int i = 0, off = 0; i < 6; i++) {
            const int n = texels(LAYERS[i]);
            owned.push_back(makeTexture(Point{n, 1}, GLFormat(DataType::FLOAT_32, 4), w->data() + size_t(4) * size_t(off), GL_NEAREST, GL_CLAMP_TO_EDGE));
            wt.push_back(owned.back());
            off += n;
        }
        // MODE 4: P399's weight and the gate, full resolution (RG16F)
        Texture gate = tex(full, 2);
        use(g, s.gateDefines());
        bindUnit(g, "In0", in, 0);
        renderUniforms(g, toRender, *fromRender, wp, invWhite, strength);
        drawStrips(*gate);
        // MODE 0: the 4 features at half resolution; MODE 5: the half-res mean of w
        Texture feat = tex(half, 4);
        use(g, {{"MODE", "0"}});
        bindUnit(g, "In0", in, 0);
        renderUniforms(g, toRender, *fromRender, wp, invWhite, strength);
        g.drawBlocks(*feat);
        Texture featP = tex(half, 4); // RGBA: c1's inputs 6 .. 8 must read 0 (an R16F texture samples A as 1)
        use(g, {{"MODE", "5"}});
        bindUnit(g, "In0", *gate, 0);
        g.drawBlocks(*featP);
        const auto f1 = layer(0, {feat, featP}, *wt[0], half);
        feat->close(); featP->close();
        const auto f2 = layer(1, f1, *wt[1], quarter);
        const auto f3 = layer(2, f2, *wt[2], quarter);
        freeAll(f2);
        const auto f4 = layer(3, f3, *wt[3], quarter);
        freeAll(f3);
        std::vector<Texture> cat(f1);
        cat.insert(cat.end(), f4.begin(), f4.end());
        const auto f5 = layer(4, cat, *wt[4], half);
        freeAll(cat);
        const Texture delta = layer(5, f5, *wt[5], half)[0];
        freeAll(f5);
        // MODE 3: the gated correction, back to camera RGB
        use(g, s.applyDefines());
        bindUnit(g, "In0", in, 0);
        bindUnit(g, "In1", *delta, 1);
        bindUnit(g, "In2", *gate, 2);
        renderUniforms(g, toRender, *fromRender, wp, invWhite, strength);
        drawStrips(out);
        g.closed = true;
    } catch (...) {
        freeAll(owned);
        throw;
    }
    freeAll(owned);
    const auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - t0).count();
    char white[32];
    std::snprintf(white, sizeof white, "%.3f", double(1.f / invWhite));
    logI("SCAM_PIPELINE", "fringe net (P493) CaNetP v4 " + std::to_string(full.x) + "x" + std::to_string(full.y) + " reach "
         + std::to_string(s.reach) + " strength " + javaFloatString(strength) + " white " + white + " submit ms=" + std::to_string(ms));
}

} // namespace CaNetP
} // namespace scam_post
