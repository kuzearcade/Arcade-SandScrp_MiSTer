#!/usr/bin/env python3
"""Independent reference renderer for one Sand Scorpion frame: a direct
transcription of MAME's own algorithms (kaneko_tmap.cpp prepare_common +
tilemap.cpp's scroll/flip arithmetic, kan_pand.cpp draw/update,
sandscrp.cpp screen_update, emupal xGRB_555) in Python.

It exists so a disagreement between the RTL and MAME can be attributed:
  RTL vs this  -> an RTL bug
  this vs MAME -> a misreading of the reference
Neither tool shares code with the other; both read the same MAME state dump
(tools/ss_state.py) and the same ROM zips.

  ss_refrender.py --capture <dir> --frame F [--zip mame_roms/sandscrp.zip]
                  [--out ref.ppm] [--spr-frame N] [--no-sprites] [--sprite-flip]
"""
import argparse, os, sys
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from decode_kaneko_gfx import region_bytes
import zipfile

W, H = 256, 224
ROW0 = 16
DX = {0: 0x5b, 1: 0x5d}          # set_offset(0x5b, 0, 256, 224): layer 1 is dx+2

def load_state(path):
    d = np.fromfile(path, dtype='<u2')
    return dict(vram=d[0:0x2000], regs=d[0x2000:0x2010], pal=d[0x2010:0x2810], spr=d[0x2810:0x4810])

def tile_pixels(rom, code, px, py, lsb):
    """4bpp pixel of a 16x16 row_2x2_group_packed tile (arrays in, array out)."""
    addr = code.astype(np.int64) * 128 + (py >> 3) * 64 + (px >> 3) * 32 + (py & 7) * 4 + ((px & 7) >> 1)
    b = rom[addr & (len(rom) - 1)]
    if lsb:
        return np.where((px & 1) == 0, b & 15, b >> 4)
    return np.where((px & 1) == 0, b >> 4, b & 15)

def render_layer(st, rom, layer):
    """Return (pen, colour, category) arrays of shape (H, W) for one VIEW2 layer.
    layer 0 = m_tmap[0] ("BG", VRAM 0x1000/regs 2,3); layer 1 = m_tmap[1] ("FG")."""
    regs = st['regs']; ctrl = int(regs[4])
    # word offsets into the 0x2000-word VRAM: 0x000 layer-1 tiles, 0x800 layer-0
    # tiles, 0x1000 layer-1 line scroll, 0x1800 layer-0 line scroll
    base  = 0x800 if layer == 0 else 0x000
    sbase = 0x1800 if layer == 0 else 0x1000
    reg_x = int(regs[2] if layer == 0 else regs[0])
    reg_y = int(regs[3] if layer == 0 else regs[1])
    disabled = bool(ctrl >> (12 if layer == 0 else 4) & 1)
    ls_en    = bool(ctrl >> (11 if layer == 0 else 3) & 1)
    flip_x   = bool(ctrl >> 9 & 1)                        # prepare_common: bits 9/8 for BOTH layers
    flip_y   = bool(ctrl >> 8 & 1)
    pen = np.zeros((H, W), np.int64); col = np.zeros((H, W), np.int64); cat = np.zeros((H, W), np.int64)
    if disabled:
        return pen, col, cat
    y = np.arange(ROW0, ROW0 + H)[:, None]
    sy = reg_y >> 6
    u_y = ((sy - y + 32) if flip_y else (y + sy)) & 0x1ff
    vs = st['vram'][sbase:sbase + 0x200].astype(np.int64)[u_y[:, 0]][:, None] if ls_en else 0
    rs = ((reg_x + vs) & 0xffff) >> 6
    x = np.arange(W)[None, :]
    u_x = ((rs - x - DX[layer]) if flip_x else (x + rs + DX[layer])) & 0x1ff
    idx = (u_y >> 4) * 32 + (u_x >> 4)
    attr = st['vram'][base + 2 * idx].astype(np.int64)
    code = st['vram'][base + 2 * idx + 1].astype(np.int64) & 0x1fff   # % total_elements (8192)
    px = (u_x & 15) ^ np.where(attr & 1, 15, 0)                       # TILE_FLIPX == attr bit 0
    py = (u_y & 15) ^ np.where(attr & 2, 15, 0)
    pen = tile_pixels(rom, code, px, py, lsb=True)
    return pen, (attr >> 2) & 0x3f, (attr >> 8) & 7

def render_sprites(spr, rom, flip=False):
    """kan_pand.cpp draw(): 512 entries into a 256x256 plane, later entries on top."""
    plane = np.zeros((256, 256), np.int64)
    x = y = 0
    b = (spr & 0xff).astype(np.int64)          # one byte per word address
    for offs in range(0, 0x1000, 8):
        dx = int(b[offs + 4]); dy = int(b[offs + 5])
        tc = int(b[offs + 3]); attr = int(b[offs + 7])
        flipx = bool(attr & 0x80); flipy = bool(attr & 0x40)
        tile = ((attr & 0x3f) << 8) | int(b[offs + 6])
        if tc & 1: dx |= 0x100
        if tc & 2: dy |= 0x100
        if tc & 4: x += dx; y += dy
        else:      x = dx;  y = dy
        sx, sy = x, y
        if flip:
            sx = 240 - sx; sy = 240 - sy; flipx = not flipx; flipy = not flipy
        sx = ((sx & 0x1ff) ^ 0x100) - 0x100     # util::sext(v, 9)
        sy = ((sy & 0x1ff) ^ 0x100) - 0x100
        if sx > 255 or sx < -15 or sy > 255 or sy < -15:
            continue
        gx = np.arange(16)[None, :].repeat(16, 0); gy = np.arange(16)[:, None].repeat(16, 1)
        tx = 15 - gx if flipx else gx
        ty = 15 - gy if flipy else gy
        pen = tile_pixels(rom, np.full((16, 16), tile & 0x1fff), tx, ty, lsb=False)
        px = sx + gx; py = sy + gy
        m = (pen != 0) & (px >= 0) & (px < 256) & (py >= 0) & (py < 256)
        plane[py[m], px[m]] = ((tc & 0xf0) >> 4) * 16 + pen[m]
    return plane

def decode_rgb(v):
    g = (v >> 10) & 31; r = (v >> 5) & 31; b = v & 31      # xGRB_555
    e = lambda c: (c << 3) | (c >> 2)                      # pal5bit
    return np.stack([e(r), e(g), e(b)], -1).astype(np.uint8)

def render(st, spr_st, v2rom, sprom, sprites=True, sprite_flip=False):
    p0, c0, k0 = render_layer(st, v2rom, 0)
    p1, c1, k1 = render_layer(st, v2rom, 1)
    o0 = p0 != 0; o1 = p1 != 0
    pick1 = o1 & (~o0 | (k1 >= k0))                        # equal category: layer 1 drawn second
    pen = np.where(pick1, p1, p0); col = np.where(pick1, c1, c0); cat = np.where(pick1, k1, k0)
    tile_op = o0 | o1
    sp = np.zeros((H, W), np.int64)
    if sprites:
        sp = render_sprites(spr_st['spr'], sprom, sprite_flip)[ROW0:ROW0 + H, 0:W]
    spr_op = sp != 0
    tile_over = tile_op & ((cat >= 4) | ~spr_op)
    index = np.where(tile_over, 0x400 + col * 16 + pen, np.where(spr_op, sp, 0))
    return decode_rgb(st['pal'][index].astype(np.int64))

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--capture', required=True); ap.add_argument('--frame', type=int, required=True)
    ap.add_argument('--spr-frame', type=int, default=None)
    ap.add_argument('--zip', action='append', default=None)
    ap.add_argument('--out', default='ref.ppm'); ap.add_argument('--no-sprites', action='store_true')
    ap.add_argument('--sprite-flip', action='store_true')
    a = ap.parse_args()
    zips = [zipfile.ZipFile(z) for z in (a.zip or ['mame_roms/sandscrp.zip'])]
    v2rom = np.frombuffer(region_bytes(zips, 'view2')[0], np.uint8)
    sprom = np.frombuffer(region_bytes(zips, 'sprites')[0], np.uint8)
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from ss_state import dump_path
    st = load_state(dump_path(a.capture, a.frame))
    sf = a.spr_frame if a.spr_frame is not None else a.frame - 1
    spr_st = load_state(dump_path(a.capture, sf))
    img = render(st, spr_st, v2rom, sprom, not a.no_sprites, a.sprite_flip)
    with open(a.out, 'wb') as f:
        f.write(b'P6\n%d %d\n255\n' % (W, H)); f.write(img.tobytes())
    print(f"wrote {a.out} (frame {a.frame}, sprites from {sf})")

if __name__ == '__main__':
    main()
