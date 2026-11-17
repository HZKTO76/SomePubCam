#!/usr/bin/env python3
"""P733: why/combine.glsl COLOUR_IS_LOW 1 gives the photo the same pixels, bit for bit.

Where the colour source is whyLow itself on its grid (no bracket denoise, colourFU == fU), the colour's 4 x 4 B-spline takes the low
loop's taps and weights in the same order instead of 16 fetches of its own. Rendered with the photo's defines, GATHER_TAPS 0 and 1,
V2_COLOUR 0 and 1, both signedColourU values, several seeds and the grids f 2 and 3, over deterministic random textures (WhyColour
the same texels as WhyLow, bright spots, odd sizes so the windows hit every border): the RGBA32F outputs must be equal.
"""
import sys
import zlib
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import check_post_bands as cb  # noqa: E402
from check_combine_gather import PHOTO  # noqa: E402

FAILURES = []


def check(cond, msg):
    if not cond:
        print('FAIL ' + msg)
        FAILURES.append(msg)


def source(colour_low, extra):
    src = cb.expand((cb.SH / 'why/combine.glsl').read_text(encoding='utf-8'))
    for k, v in PHOTO + list(extra):
        src = cb.set_define(src, k, v)
    src = cb.set_define(src, 'COLOUR_IS_LOW', '1' if colour_low else '0')
    return cb.with_header(src)


def main():
    try:
        import moderngl
    except ImportError:
        print('moderngl missing: P733 combine colour check skipped')
        return 0
    try:
        ctx = moderngl.create_standalone_context(backend='egl', require=430)
    except Exception:
        ctx = moderngl.create_standalone_context(require=430)
    W, H = 173, 131
    one = {'WhyFused', 'WhyDetailRef', 'WhyLumaS', 'WhySceneY'}
    tried = 0
    variants = ((('GATHER_TAPS', '0'),), (('GATHER_TAPS', '1'),), (('GATHER_TAPS', '1'), ('V2_COLOUR', '1'), ('DETAIL_SPLIT', '1')),
                (('GATHER_TAPS', '1'), ('SUN_BLOOM', '1'), ('HL_OPPOSED', '1')))
    for extra in variants:
        progs = {c: ctx.program(vertex_shader=cb.VS, fragment_shader=source(c, extra)) for c in (0, 1)}
        for seed in range(3):
            for f in (2, 3):
                for signed in (0, 1):
                    LW, LH = (W + f - 1) // f, (H + f - 1) // f
                    lows = {'WhyLow', 'WhyColour', 'WhyFused', 'WhyDetailRef', 'WhyHl', 'WhySky'}
                    outs = {}
                    for c in (0, 1):
                        prog = progs[c]
                        rng = np.random.default_rng(seed * 11 + f)
                        arrays = {}
                        names = sorted(n for n in prog if isinstance(prog[n], moderngl.Uniform) and prog[n].gl_type == 0x8B5E)
                        for name in names + ['WhyLow']:
                            if name in arrays or name == 'WhyColour':
                                continue
                            w, h = (LW, LH) if name in lows else (W, H)
                            comps = 1 if name in one else 4
                            a = rng.uniform(-0.05, 1.3, (h, w, comps)).astype('f4')
                            a[rng.random((h, w)) < 0.05] *= 6.0
                            arrays[name] = a
                        arrays['WhyColour'] = arrays['WhyLow']
                        textures = []
                        for unit, name in enumerate(names):
                            a = arrays[name]
                            t = ctx.texture((a.shape[1], a.shape[0]), a.shape[2], a.tobytes(), dtype='f4')
                            t.filter = (moderngl.NEAREST, moderngl.NEAREST)
                            t.repeat_x = t.repeat_y = False
                            t.use(unit)
                            prog[name].value = unit
                            textures.append(t)
                        urng = np.random.default_rng(zlib.crc32(b'combine') + seed)
                        for name in sorted(n for n in prog if isinstance(prog[n], moderngl.Uniform)):
                            m = prog[name]
                            if m.gl_type in (0x8B5E, 0x8B5F, 0x8DD2, 0x8DCA):
                                continue
                            n = m.array_length * m.dimension
                            if m.gl_type in (0x1404, 0x8B53, 0x8B54, 0x8B55, 0x1405, 0x8DC6, 0x8DC7, 0x8DC8, 0x8B56):
                                vals = [int(v) for v in urng.integers(0, 3, n)]
                            else:
                                vals = [float(v) for v in urng.uniform(0.1, 1.0, n)]
                            try:
                                m.value = vals[0] if n == 1 else (tuple(vals) if m.array_length == 1 else
                                                                  [tuple(vals[i * m.dimension:(i + 1) * m.dimension]) if m.dimension > 1
                                                                   else vals[i] for i in range(m.array_length)])
                            except Exception:
                                pass
                        for k, v in (('fU', f), ('colourFU', f), ('signedColourU', signed), ('detailRefU', 1), ('sharpU', 1),
                                     ('fullInputU', 1), ('edgeHoldU', 0.8), ('edgeHoldLightU', 0.5), ('detailGainU', 1.3),
                                     ('aeU', 0.6), ('sharpToneU', 1.0), ('clipU', 1.4), ('detailSplitU', 2)):
                            if k in prog:
                                prog[k].value = v
                        out = ctx.texture((W, H), 4, dtype='f4')
                        fb = ctx.framebuffer([out])
                        fb.use()
                        ctx.viewport = (0, 0, W, H)
                        quad = ctx.buffer(np.array([-1, -1, 1, -1, -1, 1, 1, 1], 'f4').tobytes())
                        vao = ctx.vertex_array(prog, [(quad, '2f', 'vPosition')])
                        vao.render(mode=5, vertices=4)
                        ctx.finish()
                        outs[c] = out.read()
                        for t in textures + [out]:
                            t.release()
                        vao.release()
                        quad.release()
                        fb.release()
                    tried += 1
                    a = np.frombuffer(outs[0], 'f4')
                    check(np.ptp(a) > 0.01, '%s seed %d f %d: a flat render' % (dict(extra), seed, f))
                    if outs[0] != outs[1]:
                        b = np.frombuffer(outs[1], 'u4').reshape(H, W, 4)
                        ys, xs = np.nonzero((np.frombuffer(outs[0], 'u4').reshape(H, W, 4) != b).any(-1))
                        check(False, 'combine %s seed %d f %d signed %d: %d pixels differ with COLOUR_IS_LOW 1, first at %s'
                              % (dict(extra), seed, f, signed, ys.size, (int(xs[0]), int(ys[0]))))
        for p in progs.values():
            p.release()
    print('     why/combine (photo defines) COLOUR_IS_LOW 0 / 1: %d renders, %s'
          % (tried, 'bit for bit equal' if not FAILURES else 'DIFFERENT'))
    check(tried >= 40, 'at least 40 renders (%d)' % tried)
    print('ALL OK' if not FAILURES else 'FAILED: %d' % len(FAILURES))
    return 1 if FAILURES else 0


if __name__ == '__main__':
    sys.exit(main())
