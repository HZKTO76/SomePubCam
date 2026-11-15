#!/usr/bin/env python3
"""The fast merge of a phone burst against the phone's own output (research/phone-merge-ref-*): every result sampled as the
phone's diagnostics sample it (pixels (4x, 4y), through half floats) and compared pairwise.

  phone_ref_compare.py <name> <file.pfm | file.pfm.xz | replay.f32> [<name> <file> ...]
PSNR over the first one's p99.9; «within scale»: the samples under it in both (the few blown HDR samples aside).
"""
import lzma
import math
import struct
import sys

import numpy as np
def pfm(p):
    import io
    data = lzma.decompress(open(p, 'rb').read()) if p.endswith('.xz') else open(p, 'rb').read()
    f = io.BytesIO(data); f.readline(); w, h = map(int, f.readline().split()); s = float(f.readline())
    return np.frombuffer(f.read(), '<f4' if s < 0 else '>f4').reshape(h, w, 3)[::-1].astype(np.float64)
def f32(p):
    raw=open(p,'rb').read(); m,w,h,c=struct.unpack('<4I',raw[:16])
    a=np.frombuffer(raw[16:16+w*h*c*4],np.float32).reshape(h,w,c)
    return a[::4,::4].astype(np.float16).astype(np.float64)
def load(p): return pfm(p) if '.pfm' in p else f32(p)
def cmp(na,a,nb,b):
    scale=float(np.percentile(a,99.9)); d=np.abs(a-b)/scale
    m=(a<scale)&(b<scale)
    db=lambda e: 99.0 if e == 0 else 10*math.log10(1/e)
    print(f'{nb} vs {na}: PSNR {db(np.mean(d**2)):.2f} dB, within scale {db(np.mean(d[m]**2)):.2f} dB, '
          f'equal {np.mean(a==b):.4f}, |d|>1% {np.mean(d>0.01):.5f}, max {d.max():.3f}')
names=sys.argv[1::2]; files=sys.argv[2::2]
arr=[load(f) for f in files]
for i in range(len(arr)):
    for j in range(i+1,len(arr)): cmp(names[i],arr[i],names[j],arr[j])
