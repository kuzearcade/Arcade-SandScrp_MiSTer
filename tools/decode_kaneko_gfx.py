#!/usr/bin/env python3
"""Reference decoder for the two Kaneko 16x16x4 tile layouts Sand Scorpion
uses, transcribed from MAME src/emu/video/generic.cpp so the RTL's byte/
nibble addressing can be checked against MAME's gfx_element, not guessed.

  gfx_8x8x4_row_2x2_group_packed_msb  (Pandora sprites, "sprites" region)
     planeoffset { 0,1,2,3 }
     xoffset     { STEP8(0,4), STEP8(4*8*8,4) }        hi nibble = left pixel
     yoffset     { STEP8(0,32), STEP8(4*8*8*2,32) }
     charincrement 16*16*4 = 1024 bits = 128 bytes
  gfx_8x8x4_row_2x2_group_packed_lsb  (VIEW2 tiles, "view2" region)
     same, but xoffset = { 4,0,12,8,20,16,28,24, 256+4,256+0,... }
     i.e. low nibble = left pixel within each byte.

Both: a 16x16 tile is 128 bytes = four 8x8 blocks of 32 bytes in the order
TL (bytes 0-31), TR (32-63), BL (64-95), BR (96-127); a block row is 4 bytes.
MAME reads a pixel's 4 planes as consecutive BITS at
bit = yoffset[y] + xoffset[x] + planeoffset[p]; drawgfx.cpp's decode uses
`src[bit/8] & (0x80 >> (bit%8))` (bit 0 of a byte is its MSB) and plane p
sets pixel bit (depth-1-p), so planeoffset {0,1,2,3} at xoffset 0 is the
HIGH nibble read straight (byte>>4) and xoffset 4 is the low nibble.

Pixel formula (derived, and asserted below against a direct transcription):
  byte  = tile*128 + (y>>3)*64 + (x>>3)*32 + (y&7)*4 + ((x&7)>>1)
  nibble: msb layout -> pixel = (x&1)==0 ? byte>>4 : byte&15
          lsb layout -> pixel = (x&1)==0 ? byte&15 : byte>>4

Usage:
  decode_kaneko_gfx.py --zip mame_roms/sandscrp.zip --region view2 --tiles 0-255 --out sheet.ppm
  decode_kaneko_gfx.py --zip mame_roms/sandscrp.zip --region sprites --tiles 0x100-0x1ff --out spr.ppm
"""
import argparse, zipfile, sys

def STEP8(s, st): return [s + i*st for i in range(8)]

LAYOUT = {
  'msb': dict(plane=[0,1,2,3], x=STEP8(0,4)+STEP8(4*8*8,4), y=STEP8(0,4*8)+STEP8(4*8*8*2,4*8), inc=16*16*4),
  'lsb': dict(plane=[0,1,2,3],
              x=[1*4,0*4,3*4,2*4,5*4,4*4,7*4,6*4, 256+1*4,256+0*4,256+3*4,256+2*4,256+5*4,256+4*4,256+7*4,256+6*4],
              y=STEP8(0,4*8)+STEP8(4*8*8*2,4*8), inc=16*16*4),
}

def decode_mame(rom, layout, tile, x, y):
    """Literal transcription of gfx_element::decode_element bit gathering."""
    L = LAYOUT[layout]
    base = tile * L['inc']
    v = 0
    for p, po in enumerate(L['plane']):
        bit = base + L['y'][y] + L['x'][x] + po
        if rom[bit >> 3] & (0x80 >> (bit & 7)):
            v |= 1 << (3 - p)
    return v

def decode_fast(rom, layout, tile, x, y):
    b = rom[tile*128 + (y>>3)*64 + (x>>3)*32 + (y&7)*4 + ((x&7)>>1)]
    if layout == 'msb':
        return (b >> 4) if (x & 1) == 0 else (b & 15)
    return (b & 15) if (x & 1) == 0 else (b >> 4)

def region_bytes(zips, region):
    def rd(n):
        for z in zips:
            if n in z.namelist(): return z.read(n)
        raise SystemExit(f"{n} not in zips")
    if region == 'sprites':
        return rd('5.ic16') + rd('6.ic17'), 'msb'
    if region == 'view2':
        a, b = rd('3.ic33'), rd('4.ic32')      # ROM_LOAD16_BYTE: 3.ic33 even, 4.ic32 odd
        out = bytearray(len(a)*2); out[0::2] = a; out[1::2] = b
        return bytes(out), 'lsb'
    if region == 'sprites_b':
        return rd('ss502.ic16'), 'msb'
    if region == 'view2_b':
        return rd('ss501.ic30'), 'lsb'
    raise SystemExit(region)

PAL = [(0,0,0),(255,255,255),(255,0,0),(0,255,0),(0,0,255),(255,255,0),(255,0,255),(0,255,255),
       (128,128,128),(192,192,192),(128,0,0),(0,128,0),(0,0,128),(128,128,0),(128,0,128),(0,128,128)]

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--zip', action='append', required=True)
    ap.add_argument('--region', required=True, choices=['sprites','view2','sprites_b','view2_b'])
    ap.add_argument('--tiles', default='0-255')
    ap.add_argument('--cols', type=int, default=16)
    ap.add_argument('--out', required=True)
    ap.add_argument('--selfcheck', action='store_true', help='assert decode_fast == literal MAME transcription over the tile range')
    a = ap.parse_args()
    zips = [zipfile.ZipFile(z) for z in a.zip]
    rom, layout = region_bytes(zips, a.region)
    lo, hi = (int(v, 0) for v in a.tiles.split('-'))
    n = hi - lo + 1
    rows = (n + a.cols - 1) // a.cols
    W, H = a.cols*16, rows*16
    img = bytearray(W*H*3)
    for i in range(n):
        t = lo + i
        ox, oy = (i % a.cols)*16, (i // a.cols)*16
        for y in range(16):
            for x in range(16):
                v = decode_fast(rom, layout, t, x, y)
                if a.selfcheck:
                    assert v == decode_mame(rom, layout, t, x, y), (t, x, y)
                r, g, b = PAL[v]
                o = ((oy+y)*W + ox+x)*3
                img[o], img[o+1], img[o+2] = r, g, b
    with open(a.out, 'wb') as f:
        f.write(b'P6\n%d %d\n255\n' % (W, H)); f.write(img)
    print(f"{a.region} ({layout}): {len(rom)} bytes = {len(rom)//128} tiles; wrote tiles {lo}-{hi} to {a.out}"
          + (" (selfcheck OK)" if a.selfcheck else ""))

if __name__ == '__main__':
    main()
