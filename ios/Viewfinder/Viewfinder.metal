// The live viewfinder's look on the camera's frames: Android's ISP viewfinder pass (shaders/preview/main_fs.glsl with
// lensfilter_live.glsl spliced in, and lensfilter_prep.glsl), ported to Metal for the AVCaptureVideoDataOutput frames:
//  - the lens filter's diffusion (the only filters offered: Glimmerglass, Black Pro-Mist, Pro-Mist, CineBloom, and the film's own
//    diffusion) from the half-size blur pyramid, with DiffusionModel's level weights (Viewfinder/ViewfinderLook.mm);
//  - the film / LUT table (FilmChain) on the display values, mixed by its strength;
//  - the «Oldstyle» mode's style (utils/import_oldstyle_adjust.glsl oldstyleStyle, spliced into main_fs by MainRenderer), the same
//    function, order and taps as Android's viewfinder;
//  - focus peaking on the camera's frame itself.
// The frame arrives upright (the output connection's rotation) and mirrored for the front lens (its mirroring), as Android's
// texture after uTexRotateMatrix / mirror.

#include <metal_stdlib>
using namespace metal;

struct VfOut {
    float4 position [[position]];
    float2 uv;     // the frame's coordinate (0..1, y down)
    float2 screen; // the picture's coordinate (0..1, y down)
};

// u[0]: xy uv scale (aspect fit around the centre), z the digital zoom (0 / 1: none), w unused
// u[1]: xy resolution (drawable pixels), z LUT size, w LUT strength
// u[2]: xyz LUT domain min
// u[3]: xyz 1 / (LUT domain max - min)
// u[4]: x LUT on, y lens filter levels (0: no pyramid), z peaking, w lens filter on
// u[5]: x lens filter strength, y 1: the frame is Display P3 (brought to sRGB, as Android's ISP frame and the LUT's input)
// u[6]: the frame's own diffusion weight (W0), u[7..18]: the weights of mip levels 0..11
// u[19]: x 1 with the «Oldstyle» style on (main_fs uOsOn); u[20..23]: uOs0..uOs3 (OldstyleStyle.uniforms)
constant int VF_U_W0 = 6;
constant int VF_U_OS = 19;

vertex VfOut vf_vertex(uint vid [[vertex_id]], constant float4 *u [[buffer(0)]]) {
    const float2 corners[4] = {float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1)};
    const float2 p = corners[vid];
    VfOut o;
    o.position = float4(p, 0, 1);
    o.screen = float2((p.x + 1) * 0.5, (1 - p.y) * 0.5);
    o.uv = (o.screen - 0.5) * u[0].xy / max(u[0].z, 1.0) + 0.5; // u[0].z: a digital zoom (ViewfinderRenderer.digitalZoom)
    return o;
}

static float3 lfLin(float3 c) { return pow(max(c, float3(0.0)), float3(2.2)); }
static float3 lfEnc(float3 c) { return pow(max(c, float3(0.0)), float3(1.0 / 2.2)); }
static float lfLuma(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }

// lensfilter_live.glsl lfLevel: level k of the pyramid at p, upsampled with a cubic B-spline from four bilinear taps
static float3 lfLevel(texture2d<float> t, sampler sm, float2 p, int k) {
    const float2 size = float2(t.get_width(uint(k)), t.get_height(uint(k)));
    const float2 q = p * size - 0.5;
    const float2 i = floor(q);
    const float2 f = q - i;
    const float2 f2 = f * f, f3 = f2 * f;
    const float2 w0 = (1.0 - 3.0 * f + 3.0 * f2 - f3) / 6.0;
    const float2 w1 = (4.0 - 6.0 * f2 + 3.0 * f3) / 6.0;
    const float2 w2 = (1.0 + 3.0 * f + 3.0 * f2 - 3.0 * f3) / 6.0;
    const float2 w3 = f3 / 6.0;
    const float2 g0 = w0 + w1, g1 = w2 + w3;
    const float2 h0 = (i - 0.5 + w1 / g0) / size, h1 = (i + 1.5 + w3 / g1) / size;
    const float lod = float(k);
    return g0.y * (g0.x * t.sample(sm, float2(h0.x, h0.y), level(lod)).rgb + g1.x * t.sample(sm, float2(h1.x, h0.y), level(lod)).rgb)
         + g1.y * (g0.x * t.sample(sm, float2(h0.x, h1.y), level(lod)).rgb + g1.x * t.sample(sm, float2(h1.x, h1.y), level(lod)).rgb);
}

static bool inside(float2 uv) { return all(uv >= 0.0) && all(uv <= 1.0); }

static float3 srgbDecode(float3 v) {
    v = clamp(v, 0.0, 1.0);
    return select(pow((v + 0.055) / 1.055, float3(2.4)), v / 12.92, v <= 0.04045);
}
static float3 srgbEncode(float3 v) {
    v = clamp(v, 0.0, 1.0);
    return select(1.055 * pow(v, float3(1.0 / 2.4)) - 0.055, v * 12.92, v <= 0.0031308);
}

// the camera's Display P3 frame (both use the sRGB transfer) in sRGB primaries, out-of-gamut colours clipped
static float3 frameColor(float3 c, constant float4 *u) {
    if (u[5].y < 0.5) return c;
    const float3 p = srgbDecode(c);
    const float3 l = float3(dot(p, float3(1.2249401, -0.2249404, 0.0)),
                            dot(p, float3(-0.0420569, 1.0420571, 0.0)),
                            dot(p, float3(-0.0196376, -0.0786361, 1.0982735)));
    return srgbEncode(l);
}

// ---- «Oldstyle» (P630c): utils/import_oldstyle_adjust.glsl ported line for line. main_fs's OS_TAP(off): the frame at whole screen
// pixels (px, py: a screen pixel in uv), moved by what the filter / LUT did to this pixel (shift). Uniforms (-1..1, discrete steps
// 0, 1/3, 2/3, 1): uOs0 tone, colour, exposure, warmth; uOs1 hue, highlights, shadows, warm boost; uOs2 cool boost, sharpness,
// vignette, aura; uOs3 halo, grain.
struct OsTaps {
    float2 uv;
    float2 px;
    float2 py;
    float3 shift;
};

static float3 osTap(texture2d<float> frame, sampler s, constant float4 *u, OsTaps t, float2 off) {
    return frameColor(frame.sample(s, t.uv + off.x * t.px + off.y * t.py).rgb, u) + t.shift;
}

static float osY(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }

static float3 osSat(float3 c, float s) {
    const float y = osY(c);
    return float3(y) + (c - float3(y)) * s;
}

// a hash of a whole cell position, 0..1
static float osHash(float2 p) {
    float3 q = fract(float3(p.xyx) * 0.1031);
    q += dot(q, q.yzx + 33.33);
    return fract((q.x + q.y) * q.z);
}

// the mean of eight samples on a ring of radius r (whole pixels)
static float3 osRing(texture2d<float> frame, sampler s, constant float4 *u, OsTaps t, float r) {
    float3 sum = float3(0.0);
    for (int i = 0; i < 8; i++) {
        const float a = float(i) * 0.7853982;
        sum += osTap(frame, s, u, t, floor(float2(cos(a), sin(a)) * r + 0.5));
    }
    return sum * 0.125;
}

static float3 oldstyleStyle(texture2d<float> frame, sampler s, constant float4 *u, OsTaps t, float3 c, float2 pos, float2 size) {
    const float4 os0 = u[VF_U_OS + 1], os1 = u[VF_U_OS + 2], os2 = u[VF_U_OS + 3], os3 = u[VF_U_OS + 4];
    const float tone = os0.x, colour = os0.y, expo = os0.z, warmth = os0.w;
    const float hue = os1.x, hl = os1.y, sh = os1.z, warmB = os1.w;
    const float coolB = os2.x, sharp = os2.y, vig = os2.z, aura = os2.w;
    const float halo = os3.x, grain = os3.y;
    const float longSide = max(size.x, size.y);
    // sharpness: away from the 3 x 3 binomial at the picture's step (OldstyleStyle.sharpStep), the blur itself at -100
    if (sharp != 0.0) {
        const float st = floor(max(1.0, longSide / 1600.0) + 0.5);
        const float3 blur = (4.0 * c + 2.0 * (osTap(frame, s, u, t, float2(st, 0.0)) + osTap(frame, s, u, t, float2(-st, 0.0))
                                            + osTap(frame, s, u, t, float2(0.0, st)) + osTap(frame, s, u, t, float2(0.0, -st)))
                             + osTap(frame, s, u, t, float2(st, st)) + osTap(frame, s, u, t, float2(-st, st))
                             + osTap(frame, s, u, t, float2(st, -st)) + osTap(frame, s, u, t, float2(-st, -st))) / 16.0;
        c = clamp(c + (sharp > 0.0 ? 1.5 * sharp : sharp) * (c - blur), 0.0, 1.0);
    }
    // aura: a wide soft glow of the light (two rings, 1.5 % and 3 % of the long side), screened over the picture
    if (aura > 0.0) {
        const float3 w = 0.5 * (osRing(frame, s, u, t, longSide * 0.015) + osRing(frame, s, u, t, longSide * 0.03));
        c = 1.0 - (1.0 - c) * (1.0 - 0.75 * aura * w * smoothstep(0.5, 1.0, osY(w)));
    }
    // halo: a tight glow round bright edges (a ring at 0.6 % of the long side brighter than the pixel)
    if (halo > 0.0) {
        const float3 m = osRing(frame, s, u, t, longSide * 0.006);
        c += halo * 0.9 * max(m - c, float3(0.0)) * smoothstep(0.5, 0.95, osY(m));
    }
    // exposure: +-1.5 EV on the linearised picture
    if (expo != 0.0) c = pow(clamp(pow(max(c, float3(0.0)), float3(2.2)) * exp2(1.5 * expo), 0.0, 1.0), float3(1.0 / 2.2));
    // the palette's «Тон»: up lighter and softer, down darker and denser
    if (tone != 0.0) {
        c = pow(max(c, float3(0.0)), float3(exp2(-0.7 * tone)));
        c = c - 0.35 * tone * c * (1.0 - c) * (2.0 * c - 1.0);
    }
    // the palette's «Цвет»: left a cool grey, right a warm salmon colour
    if (colour != 0.0) {
        c = osSat(c, colour < 0.0 ? 1.0 + 0.95 * colour : 1.0 + 0.55 * colour);
        c *= colour > 0.0 ? float3(1.0 + 0.07 * colour, 1.0 + 0.01 * colour, 1.0 - 0.06 * colour)
                          : float3(1.0 + 0.025 * colour, 1.0, 1.0 - 0.035 * colour);
    }
    // warmth of the light: the highlights towards warm (+) or cold (-)
    if (warmth != 0.0) c += float3(0.09, 0.015, -0.09) * warmth * smoothstep(0.35, 1.0, osY(c));
    // hue offset: the colours turned round the grey axis, up to 35 degrees
    if (hue != 0.0) {
        const float a = hue * 0.61, cs = cos(a), sn = sin(a);
        const float3 k = float3(0.5773503);
        c = c * cs + cross(k, c) * sn + k * dot(k, c) * (1.0 - cs);
    }
    // highlights and shadows
    if (hl != 0.0) {
        const float w = smoothstep(0.45, 1.0, osY(c));
        c = hl > 0.0 ? c + hl * w * 0.35 * (1.0 - c) : c * (1.0 + hl * w * 0.45);
    }
    if (sh != 0.0) {
        const float w = 1.0 - smoothstep(0.0, 0.55, osY(c));
        c = sh > 0.0 ? c + sh * w * 0.3 * (1.0 - c) : c * (1.0 + sh * w * 0.6);
    }
    // warm / cool boost: the saturation of the warm (red over blue) or the cool colours
    if (warmB != 0.0 || coolB != 0.0) {
        const float d = c.r - c.b;
        c = osSat(c, max(0.0, 1.0 + 0.9 * warmB * clamp(d * 4.0, 0.0, 1.0) + 0.9 * coolB * clamp(-d * 4.0, 0.0, 1.0)));
    }
    // vignette: the corners darker (+) or lighter (-), round in the picture whatever its orientation
    if (vig != 0.0) {
        const float f = smoothstep(0.35, 1.0, length(pos - 0.5 * size) / (0.5 * length(size)));
        c = vig > 0.0 ? c * (1.0 - 0.7 * vig * f * f) : c - vig * 0.4 * f * f * (1.0 - c);
    }
    // grain: a cell of 1 / OldstyleStyle.GRAIN_CELLS of the long side, strongest in the mid-tones
    if (grain > 0.0) {
        const float y = osY(c);
        c += (osHash(floor(pos / max(1.0, longSide / 1200.0))) - 0.5) * grain * 0.09 * (0.25 + 3.0 * y * (1.0 - y));
    }
    return clamp(c, 0.0, 1.0);
}

// lensfilter_prep.glsl's second target: the linear frame with its highlights' headroom, at half the viewport's size (half floats:
// no square roots); its mip levels are the pyramid
fragment float4 vf_prep(VfOut in [[stage_in]], texture2d<float> frame [[texture(0)]], constant float4 *u [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    if (!inside(in.uv)) return float4(0, 0, 0, 1);
    const float3 d = frameColor(frame.sample(s, in.uv).rgb, u);
    const float3 lin = lfLin(d);
    const float t = smoothstep(0.82, 0.92, lfLuma(d));
    return float4(lin * (1.0 + 3.0 * t), 1.0);
}

fragment float4 vf_main(VfOut in [[stage_in]], texture2d<float> frame [[texture(0)]], texture3d<float> lut [[texture(1)]],
                        texture2d<float> pyramid [[texture(2)]], constant float4 *u [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    constexpr sampler sm(filter::linear, mip_filter::linear, address::clamp_to_edge);
    // main_fs: the screen's pixel steps in uv, taken before any branch (the «Oldstyle» style's taps)
    const float2 px = dfdx(in.uv), py = dfdy(in.uv);
    if (!inside(in.uv)) return float4(0, 0, 0, 1);
    const float2 resolution = max(u[1].xy, float2(1.0));
    const float4 framePx = frame.sample(s, in.uv);
    const float3 base = frameColor(framePx.rgb, u);
    float3 color = base;
    // lensFilter(): the diffusion filters (uLf 1..6) - the frame times W0 plus the pyramid's levels times their weights
    const int levels = int(u[4].y);
    if (u[4].w > 0.5 && u[5].x > 0.0 && levels > 0) {
        const float3 c = lfLin(color);
        float3 o = u[VF_U_W0].rgb * c;
        for (int k = 1; k <= 12; k++) {
            if (k > levels) break;
            const float3 w = u[VF_U_W0 + k].rgb;
            if (w.r + w.g + w.b > 1e-5) o += w * lfLevel(pyramid, sm, in.screen, k - 1);
        }
        color = lfEnc(clamp(o, 0.0, 1.0));
    }
    // the film / LUT table (main_fs.glsl uLutOn)
    if (u[4].x > 0.5) {
        const float size = u[1].z;
        const float3 lc = (clamp((clamp(color, 0.0, 1.0) - u[2].xyz) * u[3].xyz, 0.0, 1.0) * (size - 1.0) + 0.5) / size;
        color = mix(color, lut.sample(s, lc).rgb, u[1].w);
    }
    // the «Oldstyle» style (main_fs uOsOn): its taps the frame moved by what the filter / LUT did to this pixel
    if (u[VF_U_OS].x > 0.5) {
        OsTaps t;
        t.uv = in.uv;
        t.px = px;
        t.py = py;
        t.shift = color - base;
        color = oldstyleStyle(frame, s, u, t, clamp(color, 0.0, 1.0), floor(in.position.xy), resolution);
    }
    // focus peaking on the camera's frame itself (the filter and the LUT are no edges)
    if (u[4].z > 0.5) {
        float4 avg = float4(0.0);
        for (int i = -1; i <= 1; i++) {
            for (int j = -1; j <= 1; j++) avg += frame.sample(s, in.uv + float2(i * 2, j * 2) / resolution);
        }
        avg /= 9.0;
        const float diff = dot(abs(framePx - avg), float4(0.299, 0.587, 0.114, 0.0));
        const float w = (diff * diff) / (0.05 + diff * diff);
        color += float3(1.0, 0.0, 1.0) * 32.0 * diff * w;
    }
    return float4(clamp(color, 0.0, 1.0), 1.0);
}
