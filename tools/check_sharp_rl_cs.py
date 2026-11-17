#!/usr/bin/env python3
"""P725: one Richardson-Lucy stage of WhyLumaSharpen as one compute pass (why/sharp_rl_cs) gives the R16F plane of its 2 x ITERS
fragment passes (why/sharp_rl, PSF_HALF 2 through textureGather, as the app draws them) bit for bit, on the GPU (moderngl).

The stage of the app: per iteration why/sharp_rl mode 0 (the ratio, R16F), mode 1 (the estimate, R16F), the last mode 2 (the
blend with the halo control, the edge guard, the protections). The compute pass: TILE x TILE blocks with their halo in shared
memory, dispatched in bands of tile rows (originU), its r32f output copied into an R16F plane by why/sharp_place. Frames of odd
sizes (blocks past the right and bottom edges, a frame smaller than one block), the two PSFs of the defaults (Airy 1.0, Gaussian
0.5; both half 2) and others of half 1 and 2, 1 .. 4 iterations, tiles of 16 and 32, the halo control off and on, the edge
guard, the protections. The halves must be equal - and a halo one pixel short must not be (the check can fail).
Optional: --image photo.jpg adds its luma (crops of 640 x 480 at four places) as Observed.
"""
import math
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from check_colour_output import SH, expand_imports, set_define  # noqa: E402

FAILURES = []
VS = '#version 310 es\nin vec4 vPosition;\nvoid main(){gl_Position=vPosition;}\n'


def check(cond, msg):
    if not cond:
        FAILURES.append(msg)
        print('FAIL: ' + msg)


def gauss_quadrant(sigma):
    r = int(math.ceil(sigma * 3.5))
    g = np.array([math.exp(-i * i / (2 * sigma * sigma)) for i in range(-r, r + 1)])
    g /= g.sum()
    return quadrant_of(np.outer(g, g))


def j1_over_x(x):
    ax = abs(x)
    if ax < 1e-4:
        return 0.5
    if ax <= 3.75:
        y = (ax / 3.75) ** 2
        return 0.5 + y * (-0.56249982 + y * (0.21093573 + y * (-0.03954289 + y * (0.00443319 + y * -0.00031761))))
    z = 3.75 / ax
    y = z * z
    p = 0.79788458 + y * (-7.7e-7 + y * (-0.0055274 + y * (9.512e-5 + y * -0.00137237)))
    q = 0.046875 + y * (-0.00020033 + y * (0.00844919 + y * -0.00088126))
    return (p / math.sqrt(ax)) * math.cos(ax - 2.3561945 + z * q) / ax


def airy_quadrant(rad):
    """WhyLumaSharpen.airy + psf (the same arithmetic in doubles)."""
    half = min(int(math.ceil(rad * 1.85)), 16)
    k = np.zeros((2 * half + 1, 2 * half + 1))
    offs = [-0.375, -0.125, 0.125, 0.375]

    def at(d):
        v = 2 * j1_over_x(d / rad * 3.831706)
        return v * v
    for dy in range(-half, half + 1):
        for dx in range(-half, half + 1):
            d = math.hypot(dx, dy)
            v = at(d) if d > 1.5 else sum(at(math.hypot(dx + ox, dy + oy)) for oy in offs for ox in offs) / 16
            k[dy + half, dx + half] = 0 if v <= 1e-5 else v
    k /= k.sum()
    return quadrant_of(k)


def quadrant_of(k):
    full = k.shape[0] // 2
    half = min(full, 8)
    total = k[full - half:full + half + 1, full - half:full + half + 1].sum()
    q = np.zeros(81, np.float32)
    for y in range(half + 1):
        for x in range(half + 1):
            q[y * (half + 1) + x] = k[full + y, full + x] / total
    return half, q


H16 = 'float store16(float x) { return unpackHalf2x16(packHalf2x16(vec2(x, 0.0))).x; }'


def trunc(src):
    """llvmpipe stores a float into an R16F target rounded toward zero, packHalf2x16 to the nearest: the check's compute pass
    rounds as the target here does (a GPU's own R16F store and packHalf2x16 may round either way: up to one half ulp per stored
    value, see the tolerance case)."""
    assert H16 in src
    return src.replace(H16, 'float store16(float x) { uint b = floatBitsToUint(x); uint e = (b >> 23) & 255u;'
                       ' if (e < 113u || e > 142u) return unpackHalf2x16(packHalf2x16(vec2(x, 0.0))).x;'
                       ' return uintBitsToFloat(b & 0xFFFFE000u); }')


def main(argv):
    try:
        import moderngl
    except ImportError:
        print('moderngl missing: sharp_rl_cs check skipped')
        return 0
    try:
        ctx = moderngl.create_standalone_context(backend='egl', require=430)
    except Exception:
        ctx = moderngl.create_standalone_context(require=430)

    def frag(name, **defines):
        src = expand_imports((SH / ('why/%s.glsl' % name)).read_text(encoding='utf-8'))
        for k, v in defines.items():
            src = set_define(src, k, str(v))
        return ctx.program(vertex_shader=VS, fragment_shader='#version 310 es\nprecision highp int;\n' + src)

    computes = {}

    def comp(half, iters, tile, nearest=False):
        key = (half, iters, tile, nearest)
        if key not in computes:
            src = (SH / 'why/sharp_rl_cs.glsl').read_text(encoding='utf-8')
            if not nearest:
                src = trunc(src)
            src = set_define(src, 'PSF_H', str(half))
            src = set_define(src, 'ITERS', str(iters))
            src = set_define(src, 'TILE', str(tile))
            src = set_define(src, 'LAYOUT', 'layout(local_size_x = 16, local_size_y = 8, local_size_z = 1) in;')
            computes[key] = ctx.compute_shader('#version 310 es\n' + src)
        return computes[key]

    p_rl = {2: frag('sharp_rl', PSF_HALF=2), 1: frag('sharp_rl', PSF_HALF=1), 0: frag('sharp_rl')}
    p_place = frag('sharp_place')
    quad = ctx.buffer(np.array([-1, -1, 1, -1, -1, 1, 1, 1], 'f4').tobytes())

    def draw(p, target, textures, uniforms):
        fb = ctx.framebuffer([target])
        fb.use()
        vao = ctx.vertex_array(p, [(quad, '2f', 'vPosition')])
        for i, (name, t) in enumerate(textures.items()):
            t.use(i)
            p[name].value = i
        for k, v in uniforms.items():
            if k in p:
                p[k].value = v
        w, h = target.size
        for y in range(0, h, 64):  # the app's bands
            ctx.viewport = (0, y, w, min(64, h - y))
            vao.render(mode=moderngl.TRIANGLE_STRIP, vertices=4)
        vao.release()
        fb.release()

    def plane(w, h, dtype='f2', data=None):
        t = ctx.texture((w, h), 1, data, dtype=dtype)
        t.filter = (moderngl.NEAREST, moderngl.NEAREST)
        t.repeat_x = t.repeat_y = False
        return t

    def reference(obs, half, q, iters, u):
        w, h = obs.size
        ratio = plane(w, h)
        est = obs
        p = p_rl[half]
        for it in range(iters):
            p['psfU'].write(q[:p['psfU'].array_length].tobytes())
            draw(p, ratio, {'Observed': obs, 'Estimate': est}, {'modeU': 0, 'psfHalfU': half})
            nxt = plane(w, h)
            p['psfU'].write(q[:p['psfU'].array_length].tobytes())
            uni = dict(u)
            uni.update({'modeU': 2 if it == iters - 1 else 1, 'psfHalfU': half, 'dampU': 0.0})
            draw(p, nxt, {'Observed': obs, 'Estimate': est, 'Ratio': ratio}, uni)
            est = nxt
        return np.frombuffer(est.read(), np.uint16).reshape(h, w)

    def fused(obs, half, q, iters, u, tile, band_tiles, short=0, nearest=False):
        w, h = obs.size
        c = comp(half, iters, tile, nearest) if not short else short_program(half, iters, tile)
        out = plane(w, h, 'f4')
        obs.use(0)
        c['Observed'].value = 0
        c['psfU'].write(q[:c['psfU'].array_length].tobytes())
        for k, v in u.items():
            if k in c:
                c[k].value = v
        out.bind_to_image(0, read=False, write=True)
        tx, ty = (w + tile - 1) // tile, (h + tile - 1) // tile
        for t0 in range(0, ty, band_tiles):
            c['originU'].value = (0, t0 * tile)
            c.run(tx, min(band_tiles, ty - t0), 1)
        ctx.memory_barrier()
        res = plane(w, h)
        draw(p_place, res, {'InputBuffer': out}, {'originU': (0, 0)})
        return np.frombuffer(res.read(), np.uint16).reshape(h, w)

    def short_program(half, iters, tile):
        # the halo one pixel short: the check must see it
        key = ('short', half, iters, tile)
        if key not in computes:
            src = trunc((SH / 'why/sharp_rl_cs.glsl').read_text(encoding='utf-8'))
            src = src.replace('const int HALO = 2 * PSF_H * ITERS;', 'const int HALO = 2 * PSF_H * ITERS - 1;')
            src = set_define(src, 'PSF_H', str(half))
            src = set_define(src, 'ITERS', str(iters))
            src = set_define(src, 'TILE', str(tile))
            src = set_define(src, 'LAYOUT', 'layout(local_size_x = 16, local_size_y = 8, local_size_z = 1) in;')
            computes[key] = ctx.compute_shader('#version 310 es\n' + src)
        return computes[key]

    rng = np.random.default_rng(7250)

    def synthetic(w, h):
        y, x = np.mgrid[0:h, 0:w].astype(np.float32)
        img = 0.05 + 0.25 * (np.sin(x * 0.31) * np.cos(y * 0.17) > 0) + 0.1 * (x > w / 2)
        img[(y // 37 + x // 23) % 5 == 0] = 2.5          # lights over the clip
        img[:, :6] = 0.002                                 # a dark border against them
        img[(x - w * 0.7) ** 2 + (y - h * 0.3) ** 2 < 90] = 0.9
        img *= (1 + 0.08 * rng.standard_normal((h, w))).astype(np.float32)
        return np.maximum(img, 0).astype(np.float32)

    frames = [('synthetic 203x157', synthetic(203, 157)), ('synthetic 64x48', synthetic(64, 48)),
              ('synthetic 13x9', synthetic(13, 9)), ('synthetic 320x97', synthetic(320, 97))]
    if '--image' in argv:
        from PIL import Image
        im = np.asarray(Image.open(argv[argv.index('--image') + 1]).convert('RGB'), np.float32) / 255.0
        lin = np.where(im <= 0.04045, im / 12.92, ((im + 0.055) / 1.055) ** 2.4)
        luma = lin @ np.array([0.2126, 0.7152, 0.0722], np.float32)
        H0, W0 = luma.shape
        for k, (fy, fx) in enumerate([(0.2, 0.2), (0.5, 0.5), (0.75, 0.3), (0.3, 0.8)]):
            y0, x0 = int(H0 * fy), int(W0 * fx)
            frames.append(('photo crop %d' % k, luma[y0:y0 + 480, x0:x0 + 640].copy()))

    stages = [('airy 1.0', airy_quadrant(1.0)), ('gauss 0.5', gauss_quadrant(0.5)), ('gauss 0.4 (half 1)', gauss_quadrant(0.28)),
              ('airy 0.6', airy_quadrant(0.6))]
    variants = [
        {'amountU': 1.0, 'haloU': 1.0, 'marginU': 0.15, 'macroU': 0.4, 'edgeGuardU': 1.0, 'protectShadowsU': 0.0,
         'protectHighlightsU': 1.0, 'nbU': 1},
        {'amountU': 1.5, 'haloU': 0.0, 'marginU': 0.0, 'macroU': 0.0, 'edgeGuardU': 0.0, 'protectShadowsU': 1.0,
         'protectHighlightsU': 0.0, 'nbU': 2},
    ]
    cases = equal = 0
    worst = [0.0, 0.0]
    for fname, data in frames:
        h, w = data.shape
        obs = plane(w, h, 'f2', data.astype(np.float16).tobytes())
        for sname, (half, q) in stages:
            if half > 2:
                continue
            for iters in (1, 3, 4) if fname.startswith('synthetic 203') else (3,):
                for vi, u in enumerate(variants):
                    ref = reference(obs, half, q, iters, u)
                    for tile, band in ((16, 2), (32, 1)):
                        if (2 * (tile + 4 * half * iters) ** 2) * 4 > 32768:
                            continue
                        got = fused(obs, half, q, iters, u, tile, band)
                        bad = int((got != ref).sum())
                        cases += 1
                        equal += bad == 0
                        if tile == 32:
                            # the shader as shipped (stores rounded to the nearest) against llvmpipe's truncating R16F
                            # planes: the most a GPU whose stores round otherwise than packHalf2x16 can differ
                            near = fused(obs, half, q, iters, u, tile, band, nearest=True).view(np.float16).astype(np.float32)
                            r32 = ref.view(np.float16).astype(np.float32)
                            rel = np.abs(near - r32) / np.maximum(np.abs(r32), 1e-3)
                            worst[0] = max(worst[0], float(rel.max()))
                            worst[1] = max(worst[1], float(rel.mean()))
                        check(bad == 0, '%s, %s x%d, variant %d, tile %d: %d of %d halves differ (max %d)' % (
                            fname, sname, iters, vi, tile, bad, ref.size,
                            int(np.abs(got.view(np.float16).astype(np.float32) - ref.view(np.float16).astype(np.float32)).max() * 1e6)))
        obs.release()
    # the check sees a halo one pixel short
    data = synthetic(203, 157)
    obs = plane(203, 157, 'f2', data.astype(np.float16).tobytes())
    half, q = airy_quadrant(1.0)
    ref = reference(obs, half, q, 3, variants[0])
    short = fused(obs, half, q, 3, variants[0], 16, 2, short=1)
    differ = int((short != ref).sum())
    check(differ > 0, 'a halo one pixel short went unnoticed')
    print('     %d RL stages as one compute pass: %d bit for bit the fragment passes; a halo 1 px short: %d halves differ'
          % (cases, equal, differ))
    print('     rounding the stores to the nearest instead of toward zero: at most %.3f %% of a value, %.4f %% on average'
          % (100 * worst[0], 100 * worst[1]))
    # an fp16 step is 0.1 % of a value: the stores' rounding moves the plane by about a step at most
    check(worst[0] < 0.01 and worst[1] < 0.002, 'another rounding of the stores changes the plane by more than 1 % / 0.2 % on average')
    print('sharp_rl_cs %s' % ('OK' if not FAILURES else 'FAILED'))
    return 1 if FAILURES else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
