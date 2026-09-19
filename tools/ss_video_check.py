#!/usr/bin/env python3
"""M1 gate: render N frames of a MAME capture through sim/rtl/video_state and
report, per frame, the differing-pixel count against MAME's own frame.

Frame alignment (measured 2026-09-19, not assumed -- see docs/known-issues.md
SS-2). With the capture's IRQ-instant dumps (state/i<F>.bin, read at the 68000's
first IRQ-cause read of frame F, which is the instant MAME rendered frame F):

    MAME frame F  <-  VIEW2 state from dump F, Pandora table from dump F-1

The Pandora offset is the chip's own double buffer: eof(F-1) drew the table as
it stood at that instant, and screen_update shows that buffer from frame F on.

Three-way, so a mismatch is attributable:
  RTL vs MAME   what actually matters
  ref vs MAME   tools/ss_refrender.py, an independent Python transcription of
                MAME's own algorithms, from the same dump -- if this differs
                too, the dump does not describe what MAME drew (a frame the
                capture cannot reproduce), not the RTL
  RTL vs ref    an RTL bug, and nothing else

  tools/ss_video_check.py <capture_dir> [--flip] [--frames 560,1400,...]
                          [--keep] [--summary-only]
"""
import argparse, os, subprocess, sys
import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HARNESS = os.path.join(ROOT, "sim", "rtl", "video_state")

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
    ap.add_argument("capture")
    ap.add_argument("--flip", action="store_true")
    ap.add_argument("--frames", default="")
    ap.add_argument("--keep", action="store_true", help="keep each rendered .ppm as cmp_<F>.ppm")
    ap.add_argument("--summary-only", action="store_true")
    a = ap.parse_args()
    frames = [int(x) for x in a.frames.split(",") if x]
    rows, total_bad, exact = [], 0, 0
    for F in frames:
        pre = os.path.join(HARNESS, "dump", "chk_")
        subprocess.run([sys.executable, os.path.join(ROOT, "tools", "ss_state.py"),
                        a.capture, str(F), pre, "--spr-frame=%d" % (F-1)],
                       check=True, stdout=subprocess.DEVNULL)
        out = os.path.join(HARNESS, "cmp_%05d.ppm" % F if a.keep else "chk.ppm")
        r = subprocess.run([os.path.join(HARNESS, "obj_dir", "Vvideo_state_top"), pre, out,
                            "1" if a.flip else "0"], capture_output=True, text=True, cwd=HARNESS)
        if r.returncode:
            print(r.stdout, r.stderr); sys.exit(1)
        passcyc = [l for l in r.stdout.splitlines() if l.startswith("pandora:")]
        rtl = load_ppm(out)
        mame = load_raw(os.path.join(a.capture, "frames", "f%05d.raw" % F))
        refp = os.path.join(HARNESS, "ref.ppm")
        rr = subprocess.run([sys.executable, os.path.join(ROOT, "tools", "ss_refrender.py"),
                             "--capture", a.capture, "--frame", str(F), "--spr-frame", str(F-1),
                             "--out", refp] + (["--sprite-flip"] if a.flip else []),
                            capture_output=True, text=True, cwd=ROOT)
        if rr.returncode:
            print(rr.stdout, rr.stderr); sys.exit(1)
        ref = load_ppm(refp)
        n_rm = int(np.any(rtl != mame, axis=-1).sum())
        n_fm = int(np.any(ref != mame, axis=-1).sum())
        n_rf = int(np.any(rtl != ref, axis=-1).sum())
        nb = int(np.any(mame != 0, axis=-1).sum())
        total_bad += n_rf
        if n_rf == 0: exact += 1
        rows.append((F, n_rm, n_fm, n_rf))
        if not a.summary_only:
            flag = "OK" if n_rf == 0 else "RTL BUG"
            note = "" if n_rm == n_fm else "   (RTL and ref disagree with MAME differently)"
            print(f"  frame {F:5d}: RTL-vs-MAME {n_rm:6d}   ref-vs-MAME {n_fm:6d}   RTL-vs-ref {n_rf:6d}  {flag}"
                  f"   [MAME non-blank {nb:5d}]{note}")
    ident = sum(1 for r in rows if r[1] == 0)
    print(f"{exact}/{len(frames)} frames RTL == reference model, {ident}/{len(frames)} also pixel-exact vs MAME"
          + (" [FLIP]" if a.flip else ""))
    sys.exit(0 if exact == len(frames) else 1)

if __name__ == "__main__":
    main()
