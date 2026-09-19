#!/usr/bin/env python3
"""Split one sim/oracle/sandscrp_capture.lua state dump (state/s<F>.bin) into
the $readmemh files the video_state harness loads.

  ss_state.py <capture_dir> <F> <out_prefix> [--spr-frame N | --same-frame]

writes <out_prefix>{vram1,vram0,scroll1,scroll0,regs,palette}.hex (one 16-bit
word per line) and <out_prefix>spriteram.hex (one byte per line, the Pandora
byte of each word address). The Pandora RAM is taken from frame F-1's dump
(what eof(F-1) drew, i.e. what frame F shows), unless --same-frame is given.
Also prints the VIEW2 registers decoded.
"""
import os, struct, sys

def dump_path(d, F, back=8):
    """Prefer the IRQ-instant dump (state/i<F>.bin: exactly what MAME rendered
    frame F from) over the frame_done dump (state/s<F>.bin, a whole frame later).

    A frame with no i-dump is one in which the 68000 never read the IRQ cause,
    i.e. its vblank handler did not run, i.e. nothing it would have written was
    written: the state at the previous IRQ instant is still the state that frame
    was rendered from, so walk back to it (up to `back` frames). Boot frames
    before the game enables interrupts have no i-dump at all and fall back to
    the frame_done dump."""
    for k in range(back + 1):
        p = os.path.join(d, 'state', 'i%05d.bin' % (F - k))
        if F - k >= 0 and os.path.exists(p):
            if k:
                print(f"  note: no IRQ dump for frame {F}, using frame {F-k} (handler did not run)")
            return p
    return os.path.join(d, 'state', 's%05d.bin' % F)

def load(path):
    d = open(path, 'rb').read()
    assert len(d) == 0x4000 + 0x20 + 0x1000 + 0x2000, (path, len(d))
    vram = struct.unpack('<8192H', d[0:0x4000])
    regs = struct.unpack('<16H', d[0x4000:0x4020])
    pal  = struct.unpack('<2048H', d[0x4020:0x5020])
    spr  = struct.unpack('<4096H', d[0x5020:0x7020])
    return vram, regs, pal, spr

def wr(path, words, fmt):
    with open(path, 'w') as f:
        for w in words:
            f.write(fmt % w + '\n')

def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    same = '--same-frame' in sys.argv
    sprf = None
    for a in sys.argv[1:]:
        if a.startswith('--spr-frame='):
            sprf = int(a.split('=')[1])
    d, F, pre = args[0], int(args[1]), args[2]
    vram, regs, pal, spr = load(dump_path(d, F))
    sprF = sprf if sprf is not None else (F if same else F - 1)
    _, _, _, spr_prev = load(dump_path(d, sprF))
    wr(pre + 'vram1.hex',   vram[0x0000:0x0800], '%04x')
    wr(pre + 'vram0.hex',   vram[0x0800:0x1000], '%04x')
    wr(pre + 'scroll1.hex', vram[0x1000:0x1800], '%04x')
    wr(pre + 'scroll0.hex', vram[0x1800:0x2000], '%04x')
    wr(pre + 'regs.hex',    regs, '%04x')
    wr(pre + 'palette.hex', pal, '%04x')
    wr(pre + 'spriteram.hex', [w & 0xff for w in spr_prev], '%02x')
    r = regs
    print(f"F={F}: FG(layer1) scroll x={r[0]>>6} ({r[0]:04x}) y={r[1]>>6} ({r[1]:04x}); BG(layer0) x={r[2]>>6} ({r[2]:04x}) y={r[3]>>6} ({r[3]:04x}); "
          f"ctrl={r[4]:04x} (BG dis={r[4]>>12&1} ls={r[4]>>11&1} fx={r[4]>>9&1} fy={r[4]>>8&1}; FG dis={r[4]>>4&1} ls={r[4]>>3&1} fx={r[4]>>1&1} fy={r[4]&1}); r5={r[5]:04x}; sprites from F={sprF}")
    cats = {}
    for L, base in (('FG', 0x0000), ('BG', 0x0800)):
        for i in range(1024):
            a = vram[base + 2*i]
            if vram[base + 2*i + 1] or a:
                cats[(L, (a >> 8) & 7)] = cats.get((L, (a >> 8) & 7), 0) + 1
    print("  non-zero tiles by (layer, category):", dict(sorted(cats.items())))
    nspr = sum(1 for i in range(512) if any(spr_prev[8*i+k] & 0xff for k in range(3, 8)))
    print(f"  sprite entries with any non-zero byte 3..7: {nspr}")

if __name__ == '__main__':
    main()
