#define LAYOUT //
#define PSF_H 2
#define ITERS 3
#define TILE 32
LAYOUT
precision highp float; precision highp int; precision highp sampler2D; precision highp image2D;
// P725 (owner, 2026-11-17: «Начни переписывать сейчас»; LG V50: the RL stages' 12 full-frame passes 428 ms of GPU, each a
// 5 x 5 convolution of an R16F plane): one Richardson-Lucy stage of why/sharp_rl.glsl - all its ITERS iterations, ratio and
// estimate update, and the last iteration's rl_blend - in one compute pass. A work group takes a TILE x TILE block of the output
// and keeps the estimate and the ratio of the block and its halo (2 x PSF_H a convolution) in shared memory: the frame is read
// once and written once instead of 2 x ITERS times. The same terms as why/sharp_rl: the convolutions add the same taps with the
// same weights in the same order (row by row, left to right), round to fp16 as its R16F planes stored them (the ratio, every
// estimate but the last), read the planes clamped at the frame's edge (a tap past the edge reads the edge pixel, as
// clamp-to-edge / clamp() did); the last iteration's estimate goes into the blend unrounded, as in why/sharp_rl mode 2. Without
// the TV damping (dampU 0, the default; WhyLumaSharpen keeps the passes for it). Out: r32f, the fp16 value of the stage output
// (why/sharp_place copies it into the R16F plane: the same halves). tools/check_sharp_rl_cs.py: bit for bit on llvmpipe.
uniform sampler2D Observed;
uniform ivec2 originU;              // the band's first tile row (pixels)
uniform float psfU[81];
uniform float amountU;
uniform float haloU;
uniform float marginU;
uniform float macroU;
uniform float protectShadowsU;
uniform float protectHighlightsU;
uniform int nbU;
uniform float edgeGuardU;
layout(r32f, binding = 0) uniform highp writeonly image2D outPlane;

// (consts, not #defines: GLInterface replaces a whole #define line that names a define it sets)
const int HALO = 2 * PSF_H * ITERS;
const int R = TILE + 2 * HALO;
shared float estS[R * R];
shared float ratioS[R * R];

float h16(float x) { return unpackHalf2x16(packHalf2x16(vec2(x, 0.0))).x; }
// a value as an R16F plane stores it (the ratio, the estimates, the output); the GL leaves that rounding to the GPU: to the
// nearest here, as packHalf2x16 - a GPU whose R16F stores round otherwise differs by half an ulp of the stored values
float store16(float x) { return unpackHalf2x16(packHalf2x16(vec2(x, 0.0))).x; }

ivec2 base, last;

// the slot of the frame pixel clamp(base + q): a tap past the frame's edge reads the edge pixel
int slot(ivec2 q) {
    ivec2 c = clamp(base + q, ivec2(0), last) - base;
    return c.y * R + c.x;
}

float convolveEst(ivec2 s) {
    float acc = 0.0;
    for (int dy = -PSF_H; dy <= PSF_H; dy++) {
        int row = (dy < 0 ? -dy : dy) * (PSF_H + 1);
        for (int dx = -PSF_H; dx <= PSF_H; dx++) {
            float w = psfU[row + (dx < 0 ? -dx : dx)];
            if (w > 0.0) acc += estS[slot(s + ivec2(dx, dy))] * w;
        }
    }
    return h16(acc);
}

float convolveRatio(ivec2 s) {
    float acc = 0.0;
    for (int dy = -PSF_H; dy <= PSF_H; dy++) {
        int row = (dy < 0 ? -dy : dy) * (PSF_H + 1);
        for (int dx = -PSF_H; dx <= PSF_H; dx++) {
            float w = psfU[row + (dx < 0 ? -dx : dx)];
            if (w > 0.0) acc += ratioS[slot(s + ivec2(dx, dy))] * w;
        }
    }
    return h16(acc);
}

// why/sharp_rl mode 2 after the estimate: rl_blend with Observed (the same code)
float blend(ivec2 xy, float est) {
    float o = texelFetch(Observed, xy, 0).r;
    float diff = (est - o) * amountU * smoothstep(0.002, 0.02, o);
    if (protectShadowsU > 0.001 || protectHighlightsU > 0.001) {
        float sl = 0.2 * protectShadowsU;
        float hl = 1.0 - 0.2 * protectHighlightsU;
        float mask = 1.0;
        if (hl < 0.999 && o > hl) mask = o >= 1.0 ? 0.0 : ((1.0 - o) / (1.0 - hl)) * ((1.0 - o) / (1.0 - hl));
        if (sl > 0.001 && o < sl) mask = (o / sl) * (o / sl);
        diff *= clamp(mask, 0.0, 1.0);
    }
    int nb = nbU > 0 ? nbU : 1;
    float lmin = o, lmax = o;
    for (int dy = -nb; dy <= nb; dy++) {
        for (int dx = -nb; dx <= nb; dx++) {
            float v = texelFetch(Observed, clamp(xy + ivec2(dx, dy), ivec2(0), last), 0).r;
            lmin = min(lmin, v);
            lmax = max(lmax, v);
        }
    }
    float lc = lmax - lmin;
    float macro = macroU > 0.0 ? macroU : 0.4;
    float margin = marginU > 0.0 ? marginU : 0.15;
    float ef = smoothstep(max(0.01, macro * 0.375), macro, lc);
    float md = 0.25 * (1.0 - haloU);
    float damp = mix(1.0, md, ef);
    if (lc > macro) damp = mix(damp, 0.5 * md, smoothstep(macro, macro * 1.75, lc));
    float v = o + diff * damp;
    if (haloU > 0.001) {
        float mg = (1.0 - ef) * (0.03 + lc * margin);
        float s = clamp(haloU, 0.0, 1.0);
        if (v > lmax + mg) v = lmax + mg + (v - lmax - mg) * (1.0 - s);
        else if (v < lmin - mg) v = lmin - mg - (lmin - mg - v) * (1.0 - s);
    }
    if (edgeGuardU > 0.0 && haloU > 0.001) {
        int gr = nb + 1;
        float gmin = lmin, gmax = lmax;
        for (int dy = -gr; dy <= gr; dy++) {
            for (int dx = -gr; dx <= gr; dx++) {
                if (max(abs(dx), abs(dy)) <= nb) continue;
                float w = texelFetch(Observed, clamp(xy + ivec2(dx, dy), ivec2(0), last), 0).r;
                gmin = min(gmin, w);
                gmax = max(gmax, w);
            }
        }
        float g = edgeGuardU * clamp(haloU, 0.0, 1.0) * smoothstep(1.0, 2.0, log2((gmax + 0.002) / (gmin + 0.002)));
        v = mix(v, clamp(v, gmin * 0.99, gmax * 1.01), g);
    }
    return max(v, 0.0);
}

void main() {
    last = textureSize(Observed, 0) - ivec2(1);
    ivec2 tile0 = ivec2(gl_WorkGroupID.xy) * TILE + originU;
    base = tile0 - ivec2(HALO);
    int n = int(gl_WorkGroupSize.x * gl_WorkGroupSize.y);
    int li = int(gl_LocalInvocationIndex);
    // the estimate of iteration 0: Observed (R16F) over the block and its halo, at the frame pixels the slots stand for
    for (int i = li; i < R * R; i += n) {
        ivec2 s = ivec2(i % R, i / R);
        estS[i] = texelFetch(Observed, clamp(base + s, ivec2(0), last), 0).r;
    }
    barrier();
    for (int it = 0; it < ITERS; it++) {
        // the ratio over the slots 2 x PSF_H x it + PSF_H from the shared block's edge (frame pixels only: a slot past the
        // edge is never read - slot() reads the edge pixel's)
        int m = 2 * PSF_H * it + PSF_H;
        int w = R - 2 * m;
        for (int i = li; i < w * w; i += n) {
            ivec2 s = ivec2(m) + ivec2(i % w, i / w);
            ivec2 p = base + s;
            if (p.x < 0 || p.y < 0 || p.x > last.x || p.y > last.y) continue;
            float b = convolveEst(s);
            float o = texelFetch(Observed, p, 0).r;
            ratioS[s.y * R + s.x] = store16(clamp(o / max(b, 0.0001), 0.05, 10.0));
        }
        barrier();
        m += PSF_H;
        w = R - 2 * m;
        if (it < ITERS - 1) {
            // each slot's estimate from its own previous estimate and the ratio around it: in place
            for (int i = li; i < w * w; i += n) {
                ivec2 s = ivec2(m) + ivec2(i % w, i / w);
                ivec2 p = base + s;
                if (p.x < 0 || p.y < 0 || p.x > last.x || p.y > last.y) continue;
                int k = s.y * R + s.x;
                estS[k] = store16(max(0.0, estS[k] * convolveRatio(s)));
            }
            barrier();
        } else {
            // the block itself (m == HALO): the last estimate unrounded into the blend
            for (int i = li; i < w * w; i += n) {
                ivec2 s = ivec2(m) + ivec2(i % w, i / w);
                ivec2 p = base + s;
                if (p.x < 0 || p.y < 0 || p.x > last.x || p.y > last.y) continue;
                float est = max(0.0, estS[s.y * R + s.x] * convolveRatio(s));
                imageStore(outPlane, p, vec4(store16(blend(p, est)), 0.0, 0.0, 0.0));
            }
        }
    }
}
