#!/usr/bin/env python3
"""Compare a whole-board simulation's frames against a MAME capture.

Unlike tools/ss_video_check.py (which renders one frame from MAME's own state,
so the two sides are the same instant by construction), this compares two
independently RUNNING timelines. They diverge: CALC1's random source alone
guarantees it, and boot-phase software timers land a few frames apart. So a
frame is matched against a WINDOW of MAME frames and the best match reported,
and the alignment is expected to show up as a diagonal -- a constant offset
over a run of frames -- not as a single number.

  ss_sim_vs_mame.py --sim <dir> --capture <dir> [--window 12] [--offset N]
                    [--prefix sandscrp_frame_] [--best-of-run]

Report per frame: the best offset and its differing-pixel count, plus the
non-blank pixel count of both sides -- a 0-pixel difference between two blank
frames is not a match, and this is where that gets caught.
"""
import argparse, os, re, sys
import numpy as np

def load_ppm(p):
    with open(p, 'rb') as f:
        assert f.readline().strip() == b'P6'
        w, h = map(int, f.readline().split()); f.readline()
        return np.frombuffer(f.read(w*h*3), dtype=np.uint8).reshape(h, w, 3)

def load_raw(p):
    a = np.fromfile(p, dtype='<u4').reshape(224, 256)
    return np.stack([(a >> 16) & 0xff, (a >> 8) & 0xff, a & 0xff], -1).astype(np.uint8)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--sim', required=True); ap.add_argument('--capture', required=True)
    ap.add_argument('--window', type=int, default=12)
    ap.add_argument('--offset', type=int, default=None, help='fix the offset instead of searching')
    ap.add_argument('--prefix', default='sandscrp_frame_')
    a = ap.parse_args()

    sims = sorted(f for f in os.listdir(a.sim) if f.startswith(a.prefix) and f.endswith('.ppm'))
    if not sims:
        print(f"no {a.prefix}*.ppm in {a.sim}"); sys.exit(2)
    cache = {}
    def mame(n):
        if n not in cache:
            p = os.path.join(a.capture, 'frames', 'f%05d.raw' % n)
            cache[n] = load_raw(p) if os.path.exists(p) else None
        return cache[n]

    exact = near = 0
    offsets = []
    for fn in sims:
        F = int(re.search(r'(\d+)\.ppm$', fn).group(1))
        s = load_ppm(os.path.join(a.sim, fn)).astype(np.int16)
        s_nb = int(np.any(s != 0, axis=-1).sum())
        rng = [a.offset] if a.offset is not None else range(-a.window, a.window + 1)
        best = None
        for off in rng:
            m = mame(F + off)
            if m is None: continue
            n = int(np.any(s != m, axis=-1).sum())
            if best is None or n < best[0]: best = (n, off, int(np.any(m != 0, axis=-1).sum()))
        if best is None:
            print(f"  frame {F:5d}: no MAME frame in range"); continue
        n, off, m_nb = best
        offsets.append(off)
        tag = "EXACT" if n == 0 else ("close" if n < 500 else "")
        if n == 0: exact += 1
        if n < 500: near += 1
        print(f"  sim {F:5d} vs MAME {F+off:5d} (offset {off:+3d}): {n:6d} differing   "
              f"[non-blank sim {s_nb:5d} mame {m_nb:5d}] {tag}")
    if offsets:
        vals, counts = np.unique(offsets, return_counts=True)
        mode = int(vals[np.argmax(counts)])
        print(f"{exact}/{len(sims)} pixel-exact, {near}/{len(sims)} within 500 pixels; "
              f"most common offset {mode:+d} ({int(counts.max())}/{len(offsets)} frames)")

if __name__ == '__main__':
    main()
