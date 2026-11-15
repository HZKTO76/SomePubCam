// Reference comparison of two 8-bit photos for speed work (PERF_PLAN.md): PSNR (RGB), SSIM (luma, 11-tap Gaussian sigma 1.5,
// Wang et al. constants), CIEDE2000 mean / max (sRGB -> Lab D65), and a banding check (on the reference's smooth areas, the
// candidate's step histogram against the reference's: a gradient that gained flat runs and larger steps).
// Inputs: "SCRG" / "SCR8" w h c + RGBA8 rows (post_node_check / shot_run_check dumps), or raw RGBA8 with --size WxH.
// Usage: image_metrics <reference> <candidate> [--size WxH] [--check]   (--check: exit 1 when a threshold fails)
// Thresholds: SSIM >= 0.995, PSNR >= 45 dB, mean dE2000 <= 1.0, max dE2000 <= 3.0, banding ratio <= 1.05.
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <stdexcept>
#include <string>
#include <vector>

struct Image { int w = 0, h = 0; std::vector<uint8_t> rgba; };

static Image load(const std::string& path, int w, int h) {
    std::ifstream f(path, std::ios::binary);
    if (!f) throw std::runtime_error("cannot read " + path);
    std::vector<uint8_t> all((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
    Image im;
    uint32_t head[4] = {};
    if (all.size() >= 16) std::memcpy(head, all.data(), 16);
    if ((head[0] == 0x47524353u || head[0] == 0x38524353u) && head[3] == 4) { // "SCRG" / "SCR8"
        im.w = int(head[1]); im.h = int(head[2]);
        im.rgba.assign(all.begin() + 16, all.end());
    } else {
        im.w = w; im.h = h; im.rgba = std::move(all);
    }
    if (im.w <= 0 || im.h <= 0 || im.rgba.size() < size_t(im.w) * im.h * 4) throw std::runtime_error(path + ": no RGBA8 image (give --size)");
    im.rgba.resize(size_t(im.w) * im.h * 4);
    return im;
}

static double srgbToLinear(double v) { v /= 255.0; return v <= 0.04045 ? v / 12.92 : std::pow((v + 0.055) / 1.055, 2.4); }

static void lab(const uint8_t* p, const double* lut, double& L, double& a, double& b) {
    const double r = lut[p[0]], g = lut[p[1]], bl = lut[p[2]];
    double x = (0.4124564 * r + 0.3575761 * g + 0.1804375 * bl) / 0.95047;
    double y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * bl;
    double z = (0.0193339 * r + 0.1191920 * g + 0.9503041 * bl) / 1.08883;
    auto f = [](double t) { return t > 216.0 / 24389.0 ? std::cbrt(t) : (24389.0 / 27.0 * t + 16.0) / 116.0; };
    x = f(x); y = f(y); z = f(z);
    L = 116.0 * y - 16.0; a = 500.0 * (x - y); b = 200.0 * (y - z);
}

// CIEDE2000 (Sharma, Wu, Dalal 2005), kL = kC = kH = 1
static double de2000(double L1, double a1, double b1, double L2, double a2, double b2) {
    const double kPi = 3.14159265358979323846, d2r = kPi / 180.0;
    const double C1 = std::hypot(a1, b1), C2 = std::hypot(a2, b2), Cm = 0.5 * (C1 + C2);
    const double G = 0.5 * (1 - std::sqrt(std::pow(Cm, 7) / (std::pow(Cm, 7) + std::pow(25.0, 7))));
    const double a1p = (1 + G) * a1, a2p = (1 + G) * a2;
    const double C1p = std::hypot(a1p, b1), C2p = std::hypot(a2p, b2);
    auto hue = [&](double b, double ap) { if (b == 0 && ap == 0) return 0.0; double h = std::atan2(b, ap) / d2r; return h < 0 ? h + 360 : h; };
    const double h1p = hue(b1, a1p), h2p = hue(b2, a2p);
    const double dLp = L2 - L1, dCp = C2p - C1p;
    double dhp = 0;
    if (C1p * C2p != 0) { dhp = h2p - h1p; if (dhp > 180) dhp -= 360; else if (dhp < -180) dhp += 360; }
    const double dHp = 2 * std::sqrt(C1p * C2p) * std::sin(dhp * d2r / 2);
    const double Lpm = 0.5 * (L1 + L2), Cpm = 0.5 * (C1p + C2p);
    double hpm = h1p + h2p;
    if (C1p * C2p != 0) {
        if (std::fabs(h1p - h2p) <= 180) hpm *= 0.5;
        else hpm = (h1p + h2p < 360) ? 0.5 * (h1p + h2p + 360) : 0.5 * (h1p + h2p - 360);
    }
    const double T = 1 - 0.17 * std::cos((hpm - 30) * d2r) + 0.24 * std::cos(2 * hpm * d2r) + 0.32 * std::cos((3 * hpm + 6) * d2r)
                     - 0.20 * std::cos((4 * hpm - 63) * d2r);
    const double dTheta = 30 * std::exp(-std::pow((hpm - 275) / 25, 2));
    const double RC = 2 * std::sqrt(std::pow(Cpm, 7) / (std::pow(Cpm, 7) + std::pow(25.0, 7)));
    const double SL = 1 + 0.015 * std::pow(Lpm - 50, 2) / std::sqrt(20 + std::pow(Lpm - 50, 2));
    const double SC = 1 + 0.045 * Cpm, SH = 1 + 0.015 * Cpm * T;
    const double RT = -std::sin(2 * dTheta * d2r) * RC;
    return std::sqrt(std::pow(dLp / SL, 2) + std::pow(dCp / SC, 2) + std::pow(dHp / SH, 2) + RT * (dCp / SC) * (dHp / SH));
}

static void blur(const std::vector<float>& in, std::vector<float>& out, int w, int h) {
    float k[11]; float s = 0;
    for (int i = 0; i < 11; i++) { k[i] = std::exp(-0.5f * float((i - 5) * (i - 5)) / (1.5f * 1.5f)); s += k[i]; }
    for (float& v : k) v /= s;
    std::vector<float> tmp(in.size());
    for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) {
        float a = 0; for (int i = 0; i < 11; i++) a += k[i] * in[size_t(y) * w + std::clamp(x + i - 5, 0, w - 1)];
        tmp[size_t(y) * w + x] = a;
    }
    out.assign(in.size(), 0.f);
    for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) {
        float a = 0; for (int i = 0; i < 11; i++) a += k[i] * tmp[size_t(std::clamp(y + i - 5, 0, h - 1)) * w + x];
        out[size_t(y) * w + x] = a;
    }
}

int main(int argc, char** argv) {
    try {
        if (argc == 2 && !std::strcmp(argv[1], "--selftest")) {
            // Sharma et al.'s table: pairs 1, 7, 17 and 34 (2.0425, 0.0, 27.1492, 0.9082)
            const double t[][7] = {{50, 2.6772, -79.7751, 50, 0, -82.7485, 2.0425}, {50, 0, 0, 50, -1, 2, 2.3669},
                                   {50, 2.5, 0, 73, 25, -18, 27.1492}, {2.0776, 0.0795, -1.135, 0.9033, -0.0636, -0.5514, 0.9082}};
            int bad = 0;
            for (const auto& r : t) {
                const double d = de2000(r[0], r[1], r[2], r[3], r[4], r[5]);
                std::printf("dE2000 %.4f (table %.4f)\n", d, r[6]);
                bad += std::fabs(d - r[6]) > 1e-4;
            }
            return bad ? 1 : 0;
        }
        if (argc < 3) { std::fprintf(stderr, "usage: %s <reference> <candidate> [--size WxH] [--check]\n", argv[0]); return 2; }
        int w = 0, h = 0;
        bool check = false;
        for (int i = 3; i < argc; i++) {
            if (!std::strcmp(argv[i], "--check")) check = true;
            else if (!std::strcmp(argv[i], "--size") && i + 1 < argc) std::sscanf(argv[++i], "%dx%d", &w, &h);
        }
        const Image ref = load(argv[1], w, h), cand = load(argv[2], w, h);
        if (ref.w != cand.w || ref.h != cand.h) throw std::runtime_error("sizes differ");
        const int W = ref.w, H = ref.h;
        const size_t n = size_t(W) * H;
        // PSNR over RGB, the differing values
        double se = 0; size_t differ = 0; int maxAbs = 0;
        for (size_t i = 0; i < n; i++) for (int c = 0; c < 3; c++) {
            const int d = int(ref.rgba[4 * i + c]) - int(cand.rgba[4 * i + c]);
            se += double(d) * d; if (d) differ++; maxAbs = std::max(maxAbs, std::abs(d));
        }
        const double mse = se / double(3 * n);
        const double psnr = mse == 0 ? 999.0 : 10 * std::log10(255.0 * 255.0 / mse);
        // SSIM on luma
        std::vector<float> x(n), y(n);
        for (size_t i = 0; i < n; i++) {
            x[i] = 0.299f * ref.rgba[4 * i] + 0.587f * ref.rgba[4 * i + 1] + 0.114f * ref.rgba[4 * i + 2];
            y[i] = 0.299f * cand.rgba[4 * i] + 0.587f * cand.rgba[4 * i + 1] + 0.114f * cand.rgba[4 * i + 2];
        }
        std::vector<float> xx(n), yy(n), xy(n), mx, my, sxx, syy, sxy;
        for (size_t i = 0; i < n; i++) { xx[i] = x[i] * x[i]; yy[i] = y[i] * y[i]; xy[i] = x[i] * y[i]; }
        blur(x, mx, W, H); blur(y, my, W, H); blur(xx, sxx, W, H); blur(yy, syy, W, H); blur(xy, sxy, W, H);
        const double C1 = std::pow(0.01 * 255, 2), C2 = std::pow(0.03 * 255, 2);
        double ssim = 0;
        for (size_t i = 0; i < n; i++) {
            const double a = mx[i], b = my[i];
            const double va = sxx[i] - a * a, vb = syy[i] - b * b, cov = sxy[i] - a * b;
            ssim += ((2 * a * b + C1) * (2 * cov + C2)) / ((a * a + b * b + C1) * (va + vb + C2));
        }
        ssim /= double(n);
        // CIEDE2000 (only the differing pixels: 0 elsewhere)
        double lut[256];
        for (int i = 0; i < 256; i++) lut[i] = srgbToLinear(i);
        double deSum = 0, deMax = 0;
        for (size_t i = 0; i < n; i++) {
            const uint8_t* p = &ref.rgba[4 * i];
            const uint8_t* q = &cand.rgba[4 * i];
            if (p[0] == q[0] && p[1] == q[1] && p[2] == q[2]) continue;
            double L1, a1, b1, L2, a2, b2;
            lab(p, lut, L1, a1, b1); lab(q, lut, L2, a2, b2);
            const double d = de2000(L1, a1, b1, L2, a2, b2);
            deSum += d; deMax = std::max(deMax, d);
        }
        const double deMean = deSum / double(n);
        // banding: on the reference's smooth areas (local luma std < 2 levels), the share of neighbour steps of 0 and of >= 2
        // levels along rows; a banded gradient has more of both (flat runs and jumps). Ratio: candidate / reference of those
        // shares' sum (1 = the same structure).
        size_t smooth = 0, refBand = 0, candBand = 0;
        for (int yy0 = 0; yy0 < H; yy0++) for (int xx0 = 1; xx0 < W; xx0++) {
            const size_t i = size_t(yy0) * W + xx0;
            const double v = sxx[i] - double(mx[i]) * mx[i];
            if (v > 4.0 || mx[i] < 8) continue;
            smooth++;
            for (int c = 0; c < 3; c++) {
                const int dr = std::abs(int(ref.rgba[4 * i + c]) - int(ref.rgba[4 * (i - 1) + c]));
                const int dc = std::abs(int(cand.rgba[4 * i + c]) - int(cand.rgba[4 * (i - 1) + c]));
                refBand += dr >= 2; candBand += dc >= 2;
            }
        }
        const double banding = smooth == 0 ? 1.0 : double(candBand + 1) / double(refBand + 1);
        const bool ok = ssim >= 0.995 && psnr >= 45.0 && deMean <= 1.0 && deMax <= 3.0 && banding <= 1.05;
        std::printf("%dx%d: %zu of %zu values differ (max %d), PSNR %.2f dB, SSIM %.6f, dE2000 mean %.4f max %.3f, banding x%.3f "
                    "(%zu smooth px) -> %s\n", W, H, differ, 3 * n, maxAbs, psnr, ssim, deMean, deMax, banding, smooth, ok ? "PASS" : "FAIL");
        return check && !ok ? 1 : 0;
    } catch (const std::exception& e) {
        std::fprintf(stderr, "image_metrics: %s\n", e.what());
        return 2;
    }
}
