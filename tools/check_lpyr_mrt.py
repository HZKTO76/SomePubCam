#!/usr/bin/env python3
"""P727: level 1 of the fusion pyramid's lumas L, weights p and (G, Fpp) in one pass into three targets (why/lpyr MODE 11, MRT)
gives the three passes of before (MODE 0 into RGBA16F, MODE 1 into RGBA16F, MODE 7 into RG16F) bit for bit, on the GPU (moderngl).

whyLow frames of odd sizes with shadows, mid tones, lights over white and saturated colour; the fusion's uniforms of the log of
a shot and others (exposures, layer weights, AE, centre, smoothness, gamma, the saturated-light share, the warm bias), GAMMA_TYPE
0 / 1, EDGE_BANDS 0 / 1, MRT_GF 1 (the bands) and 0 (L and p only). Drawn in 64-row bands as GLProg.drawBlocks.
"""
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


def main():
    try:
        import moderngl
    except ImportError:
        print('moderngl missing: lpyr MRT check skipped')
        return 0
    try:
        ctx = moderngl.create_standalone_context(backend='egl', require=430)
    except Exception:
        ctx = moderngl.create_standalone_context(require=430)
    programs = {}

    def prog(**defines):
        key = tuple(sorted(defines.items()))
        if key not in programs:
            src = expand_imports((SH / 'why/lpyr.glsl').read_text(encoding='utf-8'))
            for k, v in defines.items():
                src = set_define(src, k, str(v))
            programs[key] = ctx.program(vertex_shader=VS, fragment_shader='#version 310 es\nprecision highp int;\n' + src)
        return programs[key]

    quad = ctx.buffer(np.array([-1, -1, 1, -1, -1, 1, 1, 1], 'f4').tobytes())

    def draw(p, targets, source, uniforms):
        fb = ctx.framebuffer(targets)
        fb.use()
        vao = ctx.vertex_array(p, [(quad, '2f', 'vPosition')])
        source.use(0)
        p['InputBuffer'].value = 0
        for k, v in uniforms.items():
            if k in p:
                p[k].value = v
        w, h = targets[0].size
        for y in range(0, h, 64):
            ctx.viewport = (0, y, w, min(64, h - y))
            vao.render(mode=moderngl.TRIANGLE_STRIP, vertices=4)
        vao.release()
        fb.release()

    def target(w, h, c):
        t = ctx.texture((w, h), c, dtype='f2')
        t.filter = (moderngl.NEAREST, moderngl.NEAREST)
        return t

    rng = np.random.default_rng(7270)

    def frame(w, h):
        y, x = np.mgrid[0:h, 0:w].astype(np.float32)
        base = 0.002 * np.exp2(10 * x / w)                                  # shadows to lights, 10 EV
        img = np.stack([base * (1 + 0.5 * np.sin(y * 0.2)), base, base * (1 + 0.5 * np.cos(x * 0.13))], -1)
        img[(x // 17 + y // 11) % 7 == 0] *= np.array([3.0, 0.4, 0.2], np.float32)  # saturated colour
        img[(x - w * 0.8) ** 2 + (y - h * 0.5) ** 2 < 60] = 4.0                   # a light over white
        img *= (1 + 0.05 * rng.standard_normal(img.shape)).astype(np.float32)
        out = np.ones((h, w, 4), np.float32)
        out[..., :3] = np.maximum(img, 0)
        t = ctx.texture((w, h), 4, out.astype(np.float16).tobytes(), dtype='f2')
        t.filter = (moderngl.NEAREST, moderngl.NEAREST)
        return t

    shots = [
        {'expU': (1.0, 1.0, 1.0, 1.3702698), 'layerU': (0.7, 2.0, 1.0, 1.0), 'aeU': 1.0384, 'centerU': 1.0, 'smoothU': 0.45,
         'gammaInvU': 1 / 2.2, 'toeU': 0.05, 'satLightU': (0.6, 1.2, 0.5, 1.0), 'satLevelU': (0.8, 1.0), 'warmU': (0.0, 0.0),
         'bandEdgeU': (0.0, 0.0, 0.002, 1.0)},
        {'expU': (0.5, 1.0, 2.0, 4.0), 'layerU': (0.8, 1.0, 0.7, 0.5), 'aeU': 2.9, 'centerU': 0.6, 'smoothU': 0.25,
         'gammaInvU': 1 / 2.4, 'toeU': 0.03, 'satLightU': (0.0, 0.0, 0.0, 0.0), 'satLevelU': (0.0, 0.0), 'warmU': (0.2, 0.5),
         'bandEdgeU': (0.0, 0.0, 0.01, 0.5)},
    ]
    cases = equal = 0
    for w, h in ((203, 157), (96, 61)):
        src = frame(w, h)
        lw, lh = (w + 1) // 2, (h + 1) // 2
        for gamma in (0, 1):
            for bands in (0, 1):
                for u in shots:
                    common = {'GAMMA_TYPE': gamma}
                    if bands:
                        common['EDGE_BANDS'] = 1
                    refs = []
                    for mode, c in ((0, 4), (1, 4), (7, 2)):
                        t = target(lw, lh, c)
                        draw(prog(MODE=mode, **common), [t], src, u)
                        v = np.frombuffer(t.read(), np.float16).astype(np.float32)
                        check(np.isfinite(v).all() and np.ptp(v) > 0.01, 'MODE %d drew a flat or broken plane' % mode)
                        refs.append(t)
                    for mrt_gf in (1, 0):
                        outs = [target(lw, lh, 4), target(lw, lh, 4)] + ([target(lw, lh, 2)] if mrt_gf else [])
                        draw(prog(MODE=11, MRT_GF=mrt_gf, **common), outs, src, u)
                        for name, a, b in zip(('L', 'p', '(G, Fpp)'), refs, outs):
                            same = a.read() == b.read()
                            cases += 1
                            equal += same
                            check(same, '%dx%d gamma %d bands %d MRT_GF %d: %s differs from its own pass' % (w, h, gamma, bands, mrt_gf, name))
                        for t in outs:
                            t.release()
                    for t in refs:
                        t.release()
        src.release()
    print('     %d level-1 planes of the fusion pyramid from one MRT pass: %d bit for bit their own passes' % (cases, equal))
    print('lpyr MRT %s' % ('OK' if not FAILURES else 'FAILED'))
    return 1 if FAILURES else 0


if __name__ == '__main__':
    sys.exit(main())
