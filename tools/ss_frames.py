#!/usr/bin/env python3
"""Sand Scorpion oracle frame tools (sim/oracle/sandscrp_capture.lua output).

  ss_frames.py topng   <capture_dir> <F> [<F> ...]   raw frame -> frames/f<F>.ppm
  ss_frames.py crc     <capture_dir>                 frame -> crc32, non-blank pixel count, run lengths
  ss_frames.py diff    <a.ppm|raw> <b.ppm|raw> [out.ppm]   pixel diff count (+ optional diff image)
  ss_frames.py dedupe  <capture_dir>                 list distinct-scene runs (first frame of each)

Frames are 256x224 u32 host-endian xRGB as MAME's screen:pixels() writes
them (0x00RRGGBB little-endian on x86). The PPM written here is plain RGB.
"""
import os, sys, zlib
import numpy as np

W, H = 256, 224

def load_raw(path):
    a = np.fromfile(path, dtype='<u4')
    if a.size != W * H:
        raise SystemExit(f"{path}: {a.size} pixels, expected {W*H}")
    a = a.reshape(H, W)
    rgb = np.stack([(a >> 16) & 0xff, (a >> 8) & 0xff, a & 0xff], axis=-1).astype(np.uint8)
    return rgb

def load_ppm(path):
    with open(path, 'rb') as f:
        assert f.readline().strip() == b'P6'
        line = f.readline()
        while line.startswith(b'#'):
            line = f.readline()
        w, h = map(int, line.split())
        maxv = int(f.readline())
        data = np.frombuffer(f.read(w * h * 3), dtype=np.uint8).reshape(h, w, 3)
    return data

def load_any(path):
    return load_ppm(path) if path.endswith('.ppm') else load_raw(path)

def save_ppm(path, rgb):
    h, w, _ = rgb.shape
    with open(path, 'wb') as f:
        f.write(b'P6\n%d %d\n255\n' % (w, h))
        f.write(rgb.tobytes())

def frame_path(d, F):
    return os.path.join(d, 'frames', 'f%05d.raw' % F)

def main():
    if len(sys.argv) < 3:
        print(__doc__); sys.exit(2)
    cmd, arg = sys.argv[1], sys.argv[2]
    if cmd == 'topng':
        for F in sys.argv[3:]:
            F = int(F)
            rgb = load_raw(frame_path(arg, F))
            out = os.path.join(arg, 'frames', 'f%05d.ppm' % F)
            save_ppm(out, rgb); print('wrote', out)
    elif cmd in ('crc', 'dedupe'):
        files = sorted(f for f in os.listdir(os.path.join(arg, 'frames')) if f.endswith('.raw'))
        prev = None; run_start = 0
        for i, fn in enumerate(files):
            F = int(fn[1:6])
            raw = open(frame_path(arg, F), 'rb').read()
            crc = zlib.crc32(raw) & 0xffffffff
            if cmd == 'crc':
                a = np.frombuffer(raw, dtype='<u4')
                nb = int(np.count_nonzero(a & 0xffffff))
                print(f"{F:5d} {crc:08x} nonblank={nb}")
            else:
                if crc != prev:
                    if prev is not None:
                        print(f"  frames {run_start}-{F-1} ({F-run_start} frames) crc {prev:08x}")
                    run_start = F
                    prev = crc
        if cmd == 'dedupe' and prev is not None:
            print(f"  frames {run_start}-{F} ({F-run_start+1} frames) crc {prev:08x}")
    elif cmd == 'diff':
        a = load_any(arg); b = load_any(sys.argv[3])
        if a.shape != b.shape:
            raise SystemExit(f"shape mismatch {a.shape} vs {b.shape}")
        d = np.any(a != b, axis=-1)
        n = int(d.sum())
        nb_a = int(np.any(a != 0, axis=-1).sum()); nb_b = int(np.any(b != 0, axis=-1).sum())
        print(f"differing pixels: {n} of {a.shape[0]*a.shape[1]}  (non-blank a={nb_a} b={nb_b})")
        if n:
            ys, xs = np.nonzero(d)
            print(f"  bbox x {xs.min()}-{xs.max()} y {ys.min()}-{ys.max()}")
        if len(sys.argv) > 4:
            img = (a // 3).astype(np.uint8)
            img[d] = [255, 0, 255]
            save_ppm(sys.argv[4], img); print('wrote', sys.argv[4])
        sys.exit(1 if n else 0)
    else:
        print(__doc__); sys.exit(2)

if __name__ == '__main__':
    main()
