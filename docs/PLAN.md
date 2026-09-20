# Arcade-SandScrp_MiSTer — Project Plan (draft for review, 2026-09-19)

Sand Scorpion (FACE, 1992; MAME `kaneko/sandscrp.cpp`, three sets:
`sandscrp`, `sandscrpa` "Earlier", `sandscrpb` "Kuai Da Shizi Huangdi,
Revised Hardware") as a MiSTer FPGA core, built the way
`Arcade-NMK16_MiSTer` was built: RTL that behaves like the board, MAME as the
behavioural oracle, Verilator harnesses before hardware, the DE10-Nano as the
final proof, and the same user-facing feature set (OSD DIPs, Orientation,
Flip screen, CRT Adjust, direct-video menu split, Autofire, Pause, High
scores, Cheats, Savestates, keyboard mapping, `.mra` per set, an
`autofire_releases/` mirror).

Section 1 is the hardware as MAME describes it, section 2 the architecture and
what is copied from NMK16, section 3 the milestones and their gates, section 4
the exhaustive lessons list from NMK16 mapped onto this board, section 5 the
open questions to settle first.

**This file is the plan as written on 2026-09-19 and is kept that way** — it is
not edited to match what happened, so that the two can be compared. Wording
like "nothing below has been built" is true of the day it was written and
nothing else. For where the work actually stands, read
`docs/hw-bringup.md`; its milestone status summary is the live one, and the
dated sections under it hold the evidence. As of 2026-09-20, M0 to M3 are done
and measured, M4 has a top level that builds and meets timing but has never run
on a board, and M5's features are all instantiated and none verified.

---

## 0. Facts that shape the plan

- **One board, one rbf, three `.mra`.** All three sets share one machine
  config; they differ only in program ROMs (`sandscrp`/`sandscrpa`) and in
  ROM packaging (`sandscrpb` uses single 1 MB mask ROMs instead of byte
  pairs). No runtime game modes, no `game_sel` byte, no protection MCU, no
  custom PROMs. This is a much smaller target than NMK16: the whole
  project is one hardware core plus the shared feature set.
- **Two Kaneko custom chips have to be written from scratch:** VIEW2 (two
  16x16 tilemaps with per-line scroll and 8 priority classes) and PANDORA
  (a framebuffered sprite chip). Plus CALC1 (`kaneko_hit` type 0: compare,
  overlap, multiply, random) and HELP1 (undocumented; MAME does not model
  it, so nothing to do). MAME's own emulation is the only reference for all
  of them — the "match MAME" accuracy target from NMK16 applies as-is.
- **Everything else is NMK16 code:** 68000 (fx68k) with the ROM caches, Z80
  (T80) sound CPU with a banked ROM window, YM2203 (jt03) with its I/O
  ports, OKIM6295 (jt6295) with the fetch-hazard cache, the SDRAM
  controller and arbitration, video retimer, CRT Adjust chain, hiscore and
  cheats glue, savestate engine and CPU park monitors, autofire, keyboard,
  the tops' OSD wiring, the sim models, the oracle tooling, the `.mra`
  generators and the board scripts.
- **The ROMs are not on this machine.** `mame_roms/` has no `sandscrp*.zip`
  (the NMK16 checkout only carries nmk16 sets). The local MAME binary
  (`mame/mame`, 0.289 source tree) and the split `cheat0279` database
  (`~/Downloads/cheat0279/cheat/sandscrp*.xml`: Infinite Credits, P1/P2
  Infinite Lives, Infinite Bombs, Invincibility, Maximum Weapon Power,
  Infinite Shot/Missile, Rapid Fire) are present. `hiscore.dat`
  (`mame/plugins/hiscore/hiscore.dat` line 6438) has an entry shared by all
  three sets: `maincpu,program,702014,50,00,1b` and `700048,4,00,00`, i.e.
  0x50 bytes at main-RAM offset 0x2014 and 4 bytes at 0x0048.
- **The raster is not documented anywhere MAME knows.** The driver uses
  `set_refresh_hz(60)`, `set_vblank_time(2500 us) /* not accurate */`,
  `set_size(256,256)`, `set_visarea(0,255,16,239)`. Sibling Kaneko boards
  guess 57.4-60 Hz the same way. The pixel clock is almost certainly
  12 MHz/2 = 6 MHz (VIEW2 boards), which with a 384-pixel line gives the
  15.625 kHz line rate a 15 kHz monitor expects; 264 lines then gives
  59.19 Hz, 260 gives 60.1 Hz. This is an open item (section 5) and must be
  a parameter, never a magic number.

---

## 1. The hardware, from the driver (the specification)

### 1.1 CPUs, clocks, memory maps

| Part | Clock | Notes |
|---|---|---|
| TMP68HC000N-12 | 12 MHz (12 MHz XTAL) | `fx68k`; 3/10 phase accumulator on a 40 MHz `clk_sys`, exactly the `game_powerins` clocking already proven in `tdragon2_core.sv` |
| Z8400AB1 Z80A | 4 MHz | `T80`; MAME says "Reads the DSWs: it can't be disabled" |
| YM2203C + Y3014B | 4 MHz | `jt03`; **DSW1 on port A, DSW2 on port B** (`IOA_in`/`IOB_in`, which jt03 exposes) |
| OKIM6295 | 12 MHz/6 = 2 MHz, **pin 7 HIGH** | `jt6295` with `ss=1`; 2 MHz/132 = 15.15 kHz sample rate |
| Watchdog | 3 s (MAME's guess) | read of `0xEC0000` resets it; CALC1 register 0 read also resets it |

**68000 map** (`sandscrp_mem`):

| Range | Function |
|---|---|
| 000000-07FFFF | program ROM (512 KB, byte pair `11.bin`/`12.bin` or `1.ic4`/`2.ic5` or `11.ic4`/`12.ic5`) |
| 100001 (byte) | IRQ acknowledge/cause clear: bit 3 sprite, bit 4 "unknown", bit 5 vblank (writing a 1 clears that source); bit 0 is commented out as a possible sprite flip |
| 200000-20001F | CALC1 (`kaneko_hit` type 0), word registers |
| 300000-30001F | VIEW2 registers (16 words) |
| 400000-403FFF | VIEW2 VRAM map: 0000 layer-1 tiles (2 KB words), 1000 layer-0 tiles, 2000 layer-1 line scroll, 3000 layer-0 line scroll (each 0x1000 bytes = 2048 words, of which 1024 tile words = 32x32 tiles x 2 words, and 512 scroll words) |
| 500000-501FFF | PANDORA sprite RAM through `spriteram_lsb_r/w`: 4 KB of bytes, one byte per **word** address (the byte is taken from whichever lane the CPU writes; reads return it in both lanes) |
| 600000-600FFF | palette, 2048 entries, xGRB_555 (`palette_device::write16`) |
| 700000-70FFFF | work RAM, 64 KB |
| 800001 (byte) | IRQ cause read: 0x08 sprite, 0x10 unknown, 0x20 vblank |
| A00001 (byte) | coin counters (bits 0/1) |
| B00000/2/4/6 | P1, P2, SYSTEM, UNK input words, all active low, 16-bit reads with the high byte all ones |
| E00001 (byte) | read = sound latch 1 (Z80 to 68000, clears `latch_full[1]`); write = sound latch 0 (68000 to Z80, sets `latch_full[0]`, raises Z80 **NMI**) |
| E40001 (byte) | latch status: read bit 7 = latch 0 full, bit 6 = latch 1 full; writable (sets the two flags directly) |
| EC0000 | watchdog reset on read |

Everything not listed is unmapped. **MAME's unmapped 68000 read returns
0x0000 for this driver** (no `set_unmap_high`) — the NMK16 `airattcka`
lesson says a core that defaults to 0xFFFF can spin forever on a bad jump.
Match 0.

Interrupts: an `INPUT_MERGER_ANY_HIGH` drives **IPL level 1** from three
sources. `VBLANK_IRQ` is set by `set_vblank_int` (once per frame at the
start of vblank), `SPRITE_IRQ` is set on the vblank rising edge (the same
instant, alongside `pandora->eof()`), `UNKNOWN_IRQ` is never set. The
handler reads the cause at `0x800001` and clears sources with writes to
`0x100001`. So the 68000 sees one level-1 interrupt per frame with both
flags set; both flags stay set until acknowledged.

**Z80 maps** (`sandscrp_soundmem` / `sandscrp_soundport`, I/O masked to
0xFF):

| Range | Function |
|---|---|
| 0000-7FFF | ROM (first 32 KB of the 128 KB `8.ic51`) |
| 8000-BFFF | banked ROM window: bank = port 0 write & 7, 8 x 16 KB of the same file (bank 0/1 are the fixed half again) |
| C000-DFFF | RAM 8 KB |
| I/O 00 | bank select (write) |
| I/O 02/03 | YM2203 address/data (read and write); DSWs come back through the chip's port A/B reads |
| I/O 04 | OKI write (no read mapped) |
| I/O 06 | write sound latch 1 (Z80 to 68000, sets `latch_full[1]`) |
| I/O 07 | read sound latch 0 (clears `latch_full[0]`) |
| I/O 08 | latch status, **bit order swapped vs the 68000 side**: bit 7 = latch 1 full, bit 6 = latch 0 full |

Z80 interrupts: NMI = latch 0 data-pending (generic_latch_8's
`data_pending_callback`, i.e. asserted while the latch holds unread data);
INT = YM2203 IRQ (timer). NMK16's Z80 read mux lesson (NMK-14) applies
verbatim: every memory select must be qualified with `mreq`/`mem_re`, or an
`in a,(n)` (register A on A15..A8) reads ROM instead of the YM status and
the busy-wait loops forever.

### 1.2 Inputs and DIPs

P1/P2: up/down/left/right, button 1 (shot), button 2 (bomb), bits 6-7 and
the high byte unused (read as 1). SYSTEM: start 1, start 2, coin 1, coin 2,
tilt, bit 5 unknown, service 1, bit 7 unknown. `UNK` word all ones.

DSW1 (YM port A): Lives (2 bits), Bombs (2 bits), Difficulty (2 bits),
Bonus Life (2 bits). DSW2 (YM port B): Coinage (4 bits, 16 values incl.
Free Play), Flip Screen, Allow Continue, Demo Sounds, Service Mode
(`PORT_SERVICE_DIPLOC`). Defaults: DSW1 0xEF (Difficulty Normal = 0x20 →
0xEF), DSW2 0xFF. The `.mra` `<switches>` bytes 0/1 are DSW1/DSW2 exactly as
in NMK16 (index 254), but they feed **jt03's IOA/IOB inputs**, not a 68000
port. Byte 2 is free; bit 6 stays the autofire unlock so
`tools/gen_autofire_mra.py` works unchanged.

**The Flip Screen DIP is read by the Z80**, so whatever the game does with
it reaches the video through the 68000 (the sound CPU must report it
through latch 1). MAME then flips only what the game programs into VIEW2's
register bits 8/9 (per layer) — Pandora's `flip_screen_set` is never called
for this driver (the `irq_cause_w` bit-0 lines are commented out). Section
5 has the measurement to do before deciding what the sprite flip really
is; the OSD Flip screen does not depend on it (section 2.5).

### 1.3 Video

**Palette**: 2048 x xGRB_555 (bit 15 unused; G in bits 14-10, R in 9-5,
B in 4-0 — check `xGRB_555` in `emupal.h` when writing the decoder, do not
assume RGB order). Sprites use entries 0x000-0x0FF (16 banks of 16),
tilemaps 0x400-0x7FF (`set_colbase(0x400)`, 64 colours of 16). Pen 0 of a
sprite bank is transparent; tile pen 0 is transparent; the frame is filled
with palette entry 0 first (`bitmap.fill(0)`).

**VIEW2** (`kaneko_tmap.cpp`), one chip, two layers, each 32x32 tiles of
16x16 4bpp = 512x512 pixels, wrapping:

- Tile word 0: bits 10-8 **category** (priority 0-7; bit 8 "vs tiles",
  bits 9-10 "vs sprites"), bits 7-2 colour (64), bit 1 flip X, bit 0 flip Y.
  Word 1: 16-bit code (no bank; 1 MB of tiles = 4096 codes, so bits 15-12
  are ignored by size — MAME wraps `code % total_elements`, the NMK-25
  lesson: use a mask, and keep the modulo exact).
- Tile pixel layout `gfx_8x8x4_row_2x2_group_packed_lsb`: a 16x16 tile is
  four 8x8 blocks in order top-left, top-right, bottom-left, bottom-right,
  each 32 bytes (8 rows x 4 bytes), 4bpp packed, and **the low nibble is the
  left pixel** ("low nibble first, hi nibble second"). That is exactly the
  `tile_lsb` nibble swap NMK16 added for `powerinsc`; the sprite ROMs use
  the `_msb` variant (high nibble first). Two decoders that differ in one
  nibble swap.
- Registers (16 words at 0x300000; MAME only uses 0-5): 0 FG (layer 1)
  scroll X, 1 FG scroll Y, 2 BG (layer 0) scroll X, 3 BG scroll Y — **all
  four in 1/64-pixel units, the pixel value is `>> 6`**; 4 layers control:
  bit 12 BG disable, bit 11 BG line scroll enable, bit 9 BG flip X, bit 8
  BG flip Y, bit 4 FG disable, bit 3 FG line scroll enable, bit 1 FG flip
  X, bit 0 FG flip Y (bits 10 and 2 "always 1", ignored); 5 "always 2".
  Note the register/VRAM naming cross: register 0/1 and VRAM 0x0000 belong
  to `m_tmap[1]` ("FG"), register 2/3 and VRAM 0x1000 to `m_tmap[0]` ("BG").
- Line scroll: 512 words per layer (VRAM 0x2000 for layer 1, 0x3000 for
  layer 0). When the layer's enable bit is set, tilemap row `i` (a
  **tilemap** row, 0-511, i.e. indexed by `(y + scrolly) & 0x1FF` in
  tilemap space, not by screen line) gets `scrollx = (reg + vscroll[i]) >>
  6`. When disabled, `reg >> 6` for every row. Sand Scorpion uses it (MAME
  comment).
- Offsets: `set_offset(0x5b, 0, 256, 224)` → layer 0 `scrolldx = -0x5b`,
  layer 1 `scrolldx = -(0x5b+2)`, both `scrolldy = 0`; the flipped values
  are `xdim + dx - 1` (and `+2`), `ydim + dy - 1`. Source pixel x for
  screen column sx is therefore `sx + scrollx - 0x5B` (layer 0) or
  `sx + scrollx - 0x5D` (layer 1), mod 512; source y is
  `bitmap_y + scrolly` where **bitmap_y = screen_y + 16** because the
  visible area starts at bitmap row 16 (the NMK16 "+28,+16 bitmap
  coordinates" lesson, vertical half only here since the visible x starts
  at 0).
- Priority: `screen_update` draws categories 0,1,2,3 (for each: layer 0
  then layer 1), then copies the sprite framebuffer (`copybitmap_trans`,
  pen 0 transparent), then categories 4-7 (again layer 0 then layer 1).
  Per pixel that resolves to: highest-category opaque tile pixel wins;
  among equal categories layer 1 beats layer 0; sprites sit between 3 and
  4. No priority buffer subtleties here (unlike NMK's `prio_transpen`),
  because every draw is a plain overwrite.

**PANDORA** (`kan_pand.cpp`), 512 sprites x 8 bytes in a 4 KB byte RAM:

| Byte | Bits | Meaning |
|---|---|---|
| 0-2 | — | unused |
| 3 | 7-4 | palette bank (16 x 16 colours, base 0) |
| 3 | 2 | **relative** position: add dx/dy to the running x/y instead of setting them |
| 3 | 1 | Y bit 8 |
| 3 | 0 | X bit 8 |
| 4 | 7-0 | X low byte |
| 5 | 7-0 | Y low byte |
| 6 | 7-0 | code low 8 bits |
| 7 | 7 | flip X |
| 7 | 6 | flip Y |
| 7 | 5-0 | code high 6 bits (14-bit code = 16384 tiles, 2 MB; the ROM here is 1 MB) |

Walked in order 0..511, one 16x16 tile each, `x`/`y` accumulate across
entries when bit 2 is set (that is how multi-tile objects are placed).
Position wraps: `sx = sext(sx & 0x1ff, 9)`, so a sprite straddling the
left/top edge shows its visible part — the NMK-style mod-512 wrap. Flip
screen (not used by this driver in MAME): `sx = 240 - sx`, `sy = 240 - sy`,
flips inverted. `m_xoffset/m_yoffset` are 0 for this driver.

The chip renders into **its own 256x256 8-bit framebuffer, double
buffered**, at `eof()` (vblank rising edge): toggle buffer, clear to the
background pen (unless the game disables clearing — sprite trails, not
used here), draw the whole table. `screen_update` copies the current
buffer with pen 0 transparent. MAME's comment: "4 64x4 DRAMs — 256x256
8 bit, double buffered". This is the same whole-plane, double-buffered
renderer `video_macross2.sv` already implements for NMK, which is the
main reason the NMK code carries over — see 2.3 for the latency question.

**CALC1** (`kaneko_hit_type0`): writes at word offsets 0-9 set x1p, x1s,
y1p, y1s, x2p, x2s, y2p, y2s, mult_a, mult_b. Reads: 0x00 watchdog reset
(returns 0), 0x02 unknown (returns 0), 0x04 collision word (bits 9/10/11 =
x1p >/==/< x2p, bits 13/14/15 the same for y, bit 0 = rectangles overlap,
computed with **signed** differences as in the source), 0x10/0x12 = high /
low word of `mult_a * mult_b` (unsigned 16x16), 0x14 = random 16-bit.
MAME's note says Sand Scorpion "only uses Random Number?"; implement all of
it anyway (it is a page of combinational logic plus one multiplier) and
confirm with a MAME read tap which registers the game touches. The random
source must not be a constant — an LFSR clocked every read is enough.

### 1.4 ROMs and the SDRAM image

| Region | `sandscrp` | `sandscrpb` | Size |
|---|---|---|---|
| maincpu | `11.bin` (even) + `12.bin` (odd), ROM_LOAD16_BYTE | `11.ic4` + `12.ic5` | 0x080000 |
| audiocpu | `8.ic51` | same | 0x020000 |
| sprites | `5.ic16` + `6.ic17`, plain ROM_LOAD | `ss502.ic16` (one file) | 0x100000 |
| view2 | `3.ic33` (even) + `4.ic32` (odd), ROM_LOAD16_BYTE | `ss501.ic30` (one file) | 0x100000 |
| oki | `7.ic55` | same | 0x040000 |

Contiguous layout in `.mra` part order (the NMK16 "no gaps, sizes exactly
equal to the parts" rule): maincpu 0x000000, audiocpu 0x080000, sprites
0x0A0000, view2 0x1A0000, oki 0x2A0000, end 0x2E0000 (2.9 MB). All bases
are 24-bit byte constants (the `23'h8C0000` truncation lesson does not
bite below 8 MB, but keep the width right anyway).

**Byte-order decisions, to be fixed once and audited, not assumed.** NMK16
streams a `ROM_LOAD16_BYTE` pair as `<interleave output="16">` with the
**odd**-offset file on even stream addresses (`map="01"`), because its
SDRAM write path builds words by byte parity and the 68000 cache reads
those words; byte-wise consumers of such regions then read stream byte
`b ^ 1`. For this core:

- maincpu pair: keep the NMK convention (odd file `map="01"`, even file
  `map="10"`) so `rom_cache_n` and the 68000 path are reused unchanged.
- view2 pair: the consumer is byte-wise (the tile decoder reads MAME's
  region memory, where `3.ic33` occupies even bytes). Two options:
  (a) stream it in MAME memory order — even file `map="01"` — and read
  bytes with no `^1`; then `sandscrpb`'s single `ss501.ic30` (a plain
  `ROM_LOAD`, already in memory order) streams as-is and both sets take
  the same RTL path; or (b) NMK order with `^1`, which would make the
  plain-ROM set different from the pair set. **Recommendation: (a)**,
  which is also what makes the two sets' streams byte-identical if the
  mask ROM equals the pair (verify with the CRCs at generation time).
- sprites and oki: plain `ROM_LOAD`, stream as-is, no `^1`.

Whatever is chosen, milestone 3's hardware-path sim must run the
golden-byte audits (68000 ROM words via the CPU bus, Z80 bytes, OKI
bytes, and a tile/sprite byte audit) against the images built from the
zips, and a demo frame with sprites must be pixel-exact through the
SDRAM path before any board build. NMK16 shipped "combed" sprites for a
day because the title screens had none.

`sandscrpb` differs from the parent in packaging only; its `.mra` is the
same core, same bases, different part list. Split clone zips omit files
identical to the parent (`8.ic51`, `7.ic55` are shared): the `.mra` must
name `zip="sandscrpb.zip|sandscrp.zip"` and use the parent's file names
for the shared parts, as `resolve_name()` in `gen_gunnail_mra.py` does.

---

## 2. Architecture and reuse

### 2.1 Repository layout (mirrors NMK16)

```
Arcade-SandScrp_MiSTer/
  SandScrp.sv / .qsf / .qpf / .sdc / .srf   the Quartus project (from Template + NMK16_Macross2.sv)
  files_sandscrp.qip                         file list (from files_nmk16_raphero.qip, trimmed)
  sys/                                       MiSTer framework (committed build subset, as NMK16)
  rtl/third_party/{fx68k,t80,jt12,jt6295,hiscore,crt_adjust}   pinned by deps.lock, fetched by bootstrap.sh
  rtl/{sdram,sdram_req,sdram_arb,rom_cache1,rom_cache_n,rom_cache1_byte,rom_cache_n_byte,oki_rom_cache,tile_prefetch_byte,video_retime,crt_chain,cheats}.sv, pll.v, pll_video96.v
  rtl/savestate/                             engine, ss_m68k_park, ss_z80_park, savestate_ui
  rtl/sandscrp/sandscrp_core.sv              NEW: 68000 map, latches, IRQ merger, watchdog, CALC1 glue, Z80 sound section, SDRAM plumbing, ss image
  rtl/kaneko/view2.sv, pandora.sv, kaneko_hit.sv, video_sandscrp.sv, video_timing_sandscrp.sv   NEW
  sim/models/sdram_model.sv, sim/oracle/*, sim/compare/*, sim/rtl/common/*   copied
  sim/rtl/sandscrp/ (HW_ROMS=0 reference), sim/rtl/sandscrp_hw/ (HW_ROMS=1), sim/rtl/video_state/, unit tests copied (sdram_test, rom_cache1_test, sdram_arb_test, oki_rom_cache_test, video_retime_test, crt_chain)
  tools/                                     mk_ioctl_stream.py, mkrom.py, mkgfxrom.py, gen_hiscore_mra.py, gen_cheats_mra.py, gen_autofire_mra.py, mister_keys.py, sskey.py, mister_sweep*.sh, analyse_sweep*.py, audio_compare.py, compare_frames.py, rom_cache_eval.py, bootstrap.sh, gen_sandscrp_mra.py (NEW, table-driven like gen_raphero_mra.py)
  releases/                                  three .mra + Arcade-SandScrp_<date>.rbf (tracked)
  autofire_releases/                         git-ignored mirror (gen_autofire_mra.py, EXCLUDED list empty)
  docs/{PLAN,hw-bringup,known-issues,sim-harness,mra-workflow}.md, README.md, deps.lock, .gitignore, LICENSE, clean.bat
```

### 2.2 Reuse map

**Copied verbatim** (byte-identical to NMK16 at tag `v2026-09-19`, with
`deps.lock`/headers noting the forks): `sys/`, `Template.*`, `clean.bat`,
`.gitignore`, `tools/bootstrap.sh` + `deps.lock` entries for fx68k, t80,
jt12, jt6295, hiscore (forked: dpram_hs M10K template + the dump-validation
pass), crt_adjust (forked crt_vsize: ring_q2 register, 4x2 sqrt, registered
ring write), the `rtl/sdram.sv` fork (96 MHz CDC, single DQ capture,
`done_port` mask, pair reads, `REFRESH_CYCLES` for 96 MHz), `sdram_req.sv`
(edge-triggered accept), `sdram_arb.sv` (hold-off after service),
`rom_cache1.sv`, `rom_cache_n.sv` (68000 program, 16 pairs + prefetch,
`base_word` port, address gated on `sel_rom`), `rom_cache1_byte.sv`,
`rom_cache_n_byte.sv` (sprite fetch, 8 pairs + prefetch),
`oki_rom_cache.sv` (16 lines NRU + `stall` into the OKI `cen`),
`tile_prefetch_byte.sv` (16-px lookahead, direction-aware `x_look`),
`video_retime.sv`, `crt_chain.sv`, `cheats.sv`, `rtl/savestate/*`,
`rtl/pll.v` (40 + 96 MHz), `rtl/pll_video96.v`, `sim/models/sdram_model.sv`,
`sim/oracle/{trace.lua,capture_cyc_trace.py,capture_reg_trace.py,debug_capture.py}`,
`sim/compare/oracle_diff.py`, `sim/rtl/common/{crc32.h,nmktrace.h}`, the
unit-test directories named above, every tool listed above except the
NMK-specific generators.

**Adapted** (copy, then edit): the top-level from `NMK16_Macross2.sv` (its
Z80/YM2203/OKI family is the closest; take the CONF_STR with today's
menu-mask scheme — HB Aspect ratio/Scandoubler, H0 Orientation, O[17] Flip
screen in-core, P3 CRT Adjust on every path, h1 Autofire, DIP, Pause, P1
Scores with dA greying, P4 Savestates, P2 Cheats with h3-h9 — the keyboard
block, the autofire block, the index-254 DIP capture, the hiscore glue
(`hs_active`, RAM port mux under `pause_cpu`, `START_WAIT` from the `.mra`),
the cheats glue, the savestate instance and DDRAM mux shared with
`screen_rotate`, the `video_retime` → `crt_chain` → `video_mixer` →
`screen_rotate` chain, `fb_rotating`/`scandoubler_en`/`crt_on` gating,
`VIDEO_ARX/ARY` following rotation); the Z80 sound section of
`tdragon2_core.sv` (T80 wrapper, `z80_mem_re`-qualified read mux, jt03
instance with `cen`, jt6295 instance behind `oki_rom_cache` with the cen
stall, the mix chain with every term its own signed wire, the FM register
shadow for savestates, the `ss_*` word bus); the 68000 section of
`tdragon2_core.sv`/`raphero_core.sv` (fx68k instance with the 12 MHz
accumulator, `pause_68k` sampled on the ungated `enPhi2`, `rom_cache_n`,
DTACK chain with registered RAM reads and combinational `*_ready`
compares, the sprite-DMA-style bus hold if the Pandora snapshot needs one,
the `ss_m68k_park` overlay at an unmapped address); `sim/rtl/tdragon2_hw/`
as the hardware-sim template (`tdragon2_hw_top.sv` + `tb_tdragon2_hw.cpp`:
ioctl stream, live-raster `rd_x/rd_y`, PPM dumps, `TB_SS_*`, `TB_AUTOPLAY`,
`TB_DUMP_AUDIO`, `TB_ROM_TRACE`, the OKI audits, `CPUFRAME`/`SPRFRAME`
lines); `sim/rtl/gunnail_hs`'s `SWL=1` loader-order mode;
`tools/gen_raphero_mra.py` as the generator template (three sets, one
table); `docs/known-issues.md`'s entry format; `docs/hw-bringup.md`'s
section conventions; README structure (usage bullets 1-6, resource table,
attribution table with the modified-forks paragraph).

**New**: `view2.sv`, `pandora.sv`, `kaneko_hit.sv`, `video_sandscrp.sv`
(palette, per-pixel priority composition, readback interface with
`rd_x/rd_y` in the NMK shape so the flip mirror, `video_retime` and the hw
testbench pattern apply), `video_timing_sandscrp.sv` (the 384x264-class
raster with parameters, vblank/IRQ instants), `sandscrp_core.sv`,
`gen_sandscrp_mra.py`.

### 2.3 Video pipeline design

- **Raster**: `hcount` 0..HTOTAL-1, `vcount` 0..VTOTAL-1 at a 6 MHz pixel
  enable (40 MHz / 6.667 — a per-mille accumulator, as NMK16 did for the
  OKI cens, or run `clk_sys` at 48 MHz where 48/8 = 6 exactly; **decide in
  milestone 0** — 48 MHz changes every accumulator (68000 12 MHz = /4, Z80
  4 MHz = /12, YM 4 MHz = /12, OKI 2 MHz = /24) and simplifies the video
  retimer (48/8), and the SDRAM stays on its own 96 MHz PLL output either
  way). Visible window x 0..255 at `hcount = HBSTART..`, y 16..239 in
  bitmap rows. VBlank IRQ + sprite IRQ + Pandora `eof` at the first vblank
  line; the 68000 IPL1 line is the OR of the three latched flags.
- **Tilemaps**: two instances of one layer module, each with its VRAM
  (1024 words) and line-scroll RAM (512 words) as **two 8-bit lane arrays
  with one registered read port for the CPU and one registered read for
  the video** (the NMK-10 shape that Quartus infers as one M10K set), tile
  fetch through `tile_prefetch_byte` with a 16-pixel lookahead per layer
  on its own SDRAM port (two layers = two ports, exactly NMK16's port 2/3
  split; the sprite pass gets port 1, the 68000 program port 0 with the
  ioctl writes, the Z80 program + OKI share the remaining arbiter slot on
  port 3 behind the second tilemap at top priority — the "TX_EXTERNAL"
  arrangement). Line scroll is read per line from the scroll RAM at line
  start (registered), scroll registers latched at frame start or live
  (measure what MAME does: `prepare()` runs once per frame at
  `screen_update`, so registers changed mid-frame take effect next frame
  in MAME; the PCB probably reads them live — a known-divergence entry
  either way, decide with a MAME write tap on 0x300000 to see whether the
  game writes mid-frame at all).
- **Sprites**: the Pandora plane as a 256x224 (visible rows only) 8-bit
  double buffer in M10K: 2 x 57,344 bytes = 90 M10K of 553. The draw pass
  is `video_macross2.sv`'s sprite FSM simplified (fixed 16x16, 512
  entries, the relative-position accumulator, per-pixel mod-512 wrap,
  clip to the visible rows, byte fetch through `rom_cache_n_byte`), with
  the snapshot-at-trigger engine, the `pass_done`/swap-at-vblank rule and
  the settle cycle on the registered header read — all three were
  hardware-only bugs in NMK16. Sprite RAM is written only by the 68000
  (byte per word address) and read by the pass; a 4 KB byte array with
  the CPU port registered, the draw port registered.
  **Latency**: MAME draws at the vblank edge and shows the result in the
  next frame; a whole-plane pass that takes most of a frame shows it one
  frame later. Measure it with the `SPRLAT` method (tag each eof, carry it
  through snapshot/pass/swap, compare exact-frame MAME snapshots), document
  it as NMK-1 was documented, and only then decide whether a faster pass
  (two pixels per clock, or a scanline renderer) is worth it. Do not build
  the scanline renderer up front.
- **Composition**: per pixel, both layers' pixel + category (from the
  prefetch cache entry carrying the VRAM word, as `tile_prefetch_byte`
  does), the sprite plane byte, then the priority rule of 1.3 → palette
  index → registered palette read (one M10K pair per tap; **never** an
  asynchronous read of a 2048-entry array) → 15-bit colour → `rd_rgb` two
  clocks behind `rd_x`, inside the pixel period.
- **Flip**: OSD Flip screen = the readback-coordinate mirror
  (`rd_x_flip = 255 - rd_x`, `rd_y_flip = 223 - rd_y`) with the prefetch
  lookahead direction-aware, XORed with whatever the board's own flip
  turns out to be (VIEW2 bits 8/9 flip the layers in MAME; Pandora flip is
  the section-5 question). Same code shape as `gunnail_core.sv`'s
  `flip_x/flip_y`.
- **Orientation**: the game is **ROT90** (NMK16's were ROT270), so the
  "MAME-correct" quarter turn is the other direction: `screen_rotate`'s
  `rotate_ccw = 0` case must be the first "Vert" entry. Derive the labels
  from a MAME screenshot next to the board's, do not copy NMK16's
  `orientation != 2'd2` line.

### 2.4 SDRAM ports and caches

| Port | Consumer |
|---|---|
| 0 | ioctl writes (index 0 only) / 68000 program via `rom_cache_n` (mutually exclusive in time) |
| 1 | sprite tile bytes via `rom_cache_n_byte`, alone |
| 2 | layer 0 tiles via `tile_prefetch_byte`, alone |
| 3 | fixed-priority arbiter: layer 1 tiles (top), Z80 program via `rom_cache1_byte`/`oki_rom_cache`-style line cache, OKI via `oki_rom_cache` |

Same controller, same 96 MHz, same CDC, same pair reads. The `.sdc` gets
its clock groups from the `foreach_in_collection` pattern over
`emu|pll*|...` so the SDRAM and video PLL outputs are exclusive groups
(the Raphero hold-fix congestion trap).

### 2.5 Feature set (identical semantics to NMK16 at v2026-09-19)

| Feature | Source | Notes for this core |
|---|---|---|
| Aspect ratio, Scandoubler Fx, Orientation | `NMK16_Macross2.sv` CONF_STR | HB/H0 hides under direct video (menumask bit 11 = `direct_video`, bit 0 = `direct_video`); `fx` forced 0 under direct video; scandoubler off while `fb_rotating` |
| Flip screen | in-core mirror on every output, `screen_rotate.flip` tied off | composes with Vert as the other Vert |
| CRT Adjust | `crt_chain` P3 page, every path | `VTOTAL`/`LINE_PX`/`VSIZE_MAX`/`HTOTAL`/`DIV` parameters for the 256-wide 6 MHz raster; the 96 MHz video PLL gives 16 clocks per pixel |
| Autofire | h1 on `<switches>` byte 2 bit 6; button 3 = plain fire while on | CONF_STR `J1,Shot,Bomb,Button 3,Start,Coin` with a five-entry `<buttons>` in every `.mra` (count is load-bearing) |
| DIP submenu | `DIP;` + index 254 capture | bytes 0/1 → jt03 IOA/IOB; F2 service toggle XOR on DSW2 bit 7 |
| Pause | `O[29]`, phase-pair gated 68000 enable, `cen`-gated Z80/YM/OKI, audio muted, **watchdog paused too** | |
| High scores | hiscore fork, `<rom index="3">` + `<nvram index="4">`, RAM port mux under `pause_cpu`, `hs_active` gating, dA greying, dump validation | entries at main RAM 0x2014 (0x50) and 0x0048 (4); Off by default as in NMK16 (decision point: it could default On now that NMK-24 is understood, but keep parity unless the user says otherwise) |
| Cheats | `cheats.sv`, `<rom index="5">` from Pugsy's `sandscrp.xml` | slot names fixed in CONF_STR: Infinite Credits, P1/P2 Invincibility, P1/P2 Infinite Lives, P1/P2 Infinite Bombs — Pugsy has all but P1 Invincibility (only P2 is listed; verify the file, hide the missing slot with `status_menumask`) |
| Savestates | engine + `ss_m68k_park` (overlay at an unmapped address, e.g. 0x1E8000 — unmapped here) + `ss_z80_park` (NMI overlay at 0x0066; the game's own NMI handler lives there, which the overlay design already handles) | image: mainram 64 KB, 2 x VRAM 2 KB, 2 x scroll 1 KB, sprite RAM 4 KB, palette 4 KB, Z80 RAM 8 KB, VIEW2 regs, IRQ flags, latches + full flags, Z80 bank, CALC1 regs, Pandora buffer index, FM shadow (YM2203: replay key-on as key-off, skip 0x2C-0x2F); load waits 2 extra vblanks for the sprite double buffer; OKI not restored |
| Keyboard | MAME defaults: 5/6 coins, 1/2 starts, 9 service, F2 service DIP, arrows + Left Ctrl/Alt (shot/bomb), Space as button 3 | from the NMK16 block |
| Direct video | native `screenshot` works, capture box does not lock at 15 kHz | board tooling from NMK16 |
| `.mra` per set, `autofire_releases/` | `gen_sandscrp_mra.py`, `gen_autofire_mra.py` | releases layout: three parents at the top (sandscrpa/sandscrpb are clones → `_alternatives/_Sand Scorpion/`) |

---

## 3. Milestones and gates

Each milestone ends with a stated, measured gate. "Sim passed" is never
the last word for anything touching the memory path, the park/resume path
or byte order — those need the board.

> **Status lives elsewhere.** The gates below are the plan's, unedited. Which
> of them have been met, with the numbers, is the milestone status table in
> `docs/hw-bringup.md`. That prediction about M4's worst timing path being the
> framework's `pll_hdmi` turned out to be right, for what it is worth.

**M0 — Foundation (no RTL of our own yet).**
- Create the repo from the layout in 2.1; `bootstrap.sh` + `deps.lock`
  pinned at NMK16's commits; copy the verbatim set; commit the build
  subset of `sys/` and third-party as NMK16 does (a clone must build).
- Obtain `sandscrp.zip`, `sandscrpa.zip`, `sandscrpb.zip` (user-supplied;
  not on this machine). Build the sim ROM images with `mkrom.py`/
  `mkgfxrom.py` and the ioctl stream with `mk_ioctl_stream.py` from the
  same table the `.mra` generator uses (one table, two outputs — NMK16's
  `--ioctl`/`--simroms` pattern).
- MAME oracle captures with the local `mame/mame`: exact-frame snapshots
  via a Lua `frame_done` hook using `scr:pixels()` (not `snapshot()` under
  `-video none`; file N = frame N+1; `-str` is seconds), for the attract
  through the first demo with sprites (~2 minutes, all frames); VRAM/
  scroll/palette/sprite-RAM/register dumps at chosen frames for the
  `video_state` harness; a 68000 bus trace (`trace.lua`) for the boot and a
  write tap on 0x100001/0x300000-1F/0x200000-1F to answer section 5's
  questions; a `-wavwrite` render and per-source isolated renders (mixer
  cfg with `device_volume` 0) for the audio gain work; keep tap tokens in
  globals (the GC trap).
- Decide the raster and clock plan (section 5) and write them as
  parameters.
- Write `gen_sandscrp_mra.py` and generate the three `.mra` (parts in the
  SDRAM order, interleave per 1.4, DIP tables from 1.2, five-entry buttons,
  `<switches default="EF,FF,00">`, hiscore + cheats + `START_WAIT`); then
  `gen_autofire_mra.py` for the mirror. Model the load path off-board
  (Python: zips → parts → stream offsets vs the core's bases) as NMK-22
  did before any build.
- Gate: repo builds the copied unit tests and the `example` harness;
  `.mra` part CRCs match the zips; oracle frame set and dumps exist.

**M1 — Video core against MAME state (HW_ROMS=0).**
- `view2.sv`, `pandora.sv`, `video_sandscrp.sv`, `video_timing_sandscrp.sv`
  with `$readmemh` ROMs and a `video_state`-style harness that loads a
  MAME RAM dump and renders one frame.
- Gate: pixel-exact (0 differing pixels) against the MAME snapshot of the
  same frame for at least: the title, a frame with all eight priority
  classes in use, a frame with line scroll active, a demo frame full of
  sprites including relative-positioned multi-tile objects and edge
  wrapping, and a flipped-layer frame if the game ever sets the bits.
  Report non-blank pixel counts alongside every match.

**M2 — Full reference sim (HW_ROMS=0).**
- `sandscrp_core.sv` with fx68k, T80, jt03, jt6295, CALC1, latches, IRQs,
  watchdog (parameterised, disable-able in the sim), `SIM_DSW` for the
  DIPs, the NMK trace/debug ports (`dbg_*` PC/bus, YM/OKI write counters,
  per-source audio taps, `TB_DUMP_PPM`, `TB_DUMP_AUDIO`, `TB_XDUMP`).
- Gates: (1) 68000 bus trace vs MAME through boot (`oracle_diff.py`,
  cycle tolerance allowed); (2) frames pixel-exact vs the MAME exact-frame
  set over the attract at a fixed frame offset (transition frames
  excepted, listed), sprites included; (3) YM/OKI write counts within a
  few percent of MAME's over the same span; (4) audio band correlation
  ≥ 0.95 over 60 s with FM and OKI isolated separately (`audio_compare.py
  --offset-search`); (5) the DIP Flip Screen and every other DIP change
  something MAME also changes (compare against MAME with the DIP forced
  through a cfg file and read back over the bus).

**M3 — Hardware-path sim (HW_ROMS=1).**
- `sim/rtl/sandscrp_hw`: real `sdram.sv` + model, the ioctl stream in
  **loader order** (index 0, then index 3/4/5 if present, then 254 last —
  the `SWL=1` mode from day one, not as an afterthought), `TB_RAM_PER2=5`.
- Gates: (1) golden-byte audits 0 wrong: 68000 ROM (CPU-bus checksum
  equals the reference sim's), Z80 program bytes, OKI sample bytes
  (`unserved = 0`, stall < 1 %), sprite and tile bytes; (2) frames
  identical to the reference sim's at the same index for the attract and
  a demo scene (allowing the documented sprite latency), `DBG_MISS_PAINT`
  miss pixels = 0 after subtracting the game's own magenta/cyan; (3)
  `TB_AUTOPLAY` gameplay: `CPUFRAME romwait` < 1 % per frame, `SPRFRAME`
  pass time well under a frame at the table's worst case (512 x 16x16 =
  the bound here, no sprite clock budget to lean on), 0 late swaps; (4)
  the savestate round trip (`TB_SS_SAVE/LOAD/CMP`) pixel-exact after
  frame 0.

**M4 — Quartus and board bring-up.**
- Build in an rsync'd copy (never edit the `.qip` mid-compile; PATH to
  Quartus set in the same command block; `/tmp` under 50 %); `quartus_map`
  first as an 8-minute probe (RAM inference: every RAM row in the map
  report a real M10K, no `__N` duplicate copies, no `hq2x_buf:buf1` flops).
- Deploy: `.rbf` to `/media/fat/_Arcade/cores/`, `.mra` to `_Arcade/`,
  md5 both ends, `load_core` via `/dev/MiSTer_cmd`, native `screenshot`
  (wrapped in `timeout`), `arecord` off the capture box, `mister_keys.py`
  coin/start.
- Gates: boots to attract on the first `.mra` (if black: work the
  checklist in 4.A/4.B before anything else); native screenshots of static
  scenes byte-identical to the reference sim; a demo frame with sprites
  pixel-identical to the reference sim (the sprite byte-order check);
  audio correlation vs MAME ≥ 0.95 over 60 s within ±2 dB; coin/start/
  play on keyboard and gamepad; all three `.mra` swept (load, settle 45 s,
  shot, coin-coin-start, shot, judge by the second shot and by looking at
  the frames, not by colour counts); timing met on every clock with the
  worst path identified (expect the framework's `pll_hdmi`).

**M5 — Feature parity and release.**
- OSD options, Flip screen (paused native screenshots on/off must be exact
  rot180 on HDMI and direct video), Orientation both directions vs a MAME
  screenshot, CRT Adjust (the Verilator chain harness 20/20 plus board
  frame sizes), direct-video menu split (OSD captures on both paths),
  Autofire (`autofire_releases/` copy shows the options; the `.dip`
  override caveat documented), Pause (0 differing pixels while paused,
  audio RMS drop), High scores (patch-the-`.nvm` proof: a distinctive score
  shows after reload; a garbage `.nvm` is rejected and healed; Off-state
  never uploads), Cheats (each slot changes MAME-comparable behaviour),
  Savestates (board: save, +12 s, load → same scene; reload core → load →
  same scene; no freeze after any op — the RTE/RETN overlay lifetime bug
  was board-only), keyboard map.
- README (usage, resource table, attribution with modified forks),
  `docs/known-issues.md` (start numbering `SS-1`), `docs/hw-bringup.md`
  (dated sections), `releases/Arcade-SandScrp_<date>.rbf` tracked, tag.

---

## 4. Lessons from NMK16, mapped onto this core

Everything below was paid for once. The NMK reference (NMK-n from
`docs/known-issues.md`, or the bring-up section) is given so the full
evidence can be re-read. Items marked **[gate]** become explicit checks in
section 3.

### 4.A ROM loading, `.mra`, ioctl

1. **Gate every ioctl SDRAM write on `ioctl_index == 0`.** The `.mra`
   loader sends the `<switches>` block as a second session on index 254
   with `ioctl_addr` restarting at 0; ungated, it lands on the 68000's
   reset vector. NMK16's first black screen (a week of SDRAM theories) was
   this. **[gate: M4 checklist item 1]**
2. **Index 254 arrives LAST.** Nothing decided during a ROM stream may
   depend on the switches bytes (NMK-29). This core has no `game_sel`, but
   the rule still covers the autofire bit and any future clone mode: read
   them at run time only. The hardware sim must stream in loader order
   (`SWL=1` from the start).
3. **SDRAM regions are contiguous in `.mra` part order, sizes exactly the
   part sizes**; the sim stream tool pads to offsets and hides gaps
   (scrambled graphics on the board only). Write the part list and the
   base table from one source. **[gate: M0 off-board load model]**
4. Region base constants are 24-bit byte offsets (`23'h8C0000` silently
   lost bit 23 and the second OKI played tile graphics for a week).
5. Byte order is a per-consumer decision (1.4): 68000 words via parity
   rebuild; byte consumers of `ROM_LOAD16_BYTE`/`WORD_SWAP` regions need
   `^1` unless the stream is put in MAME memory order. **A title screen is
   not a sprite test** — combed sprites shipped once. **[gate: M3 byte
   audits + M4 demo-frame screenshot]**
6. The `.mra` `<buttons>` count/order is the gamepad's positional map and
   must equal the CONF_STR `J1` list; names are free, count is not
   (macross2's gamepad Coin). Five entries here.
7. `<dip bits="a,b">` is a start,end **range**. `?` cannot appear in `.mra`
   file names (exFAT silently drops the copy). Clone zips omit
   parent-identical files: name `zip="clone|parent"` and use the parent's
   file names.
8. `START_WAIT` for hiscore must outlast the game's destructive RAM test
   (tdragon2 halted with "WORK RAM CHECK ERROR"); it lives in `.mra` data,
   so no rebuild to tune it. Check whether Sand Scorpion tests its RAM at
   boot (bus trace).
9. No ROM/PROM data may be baked into the bitstream (NMK-22); this core
   has none, but keep `$readmemh` out of every HW path. If a table ever
   needs a write port, its read must be registered in the same commit
   (4096 flops otherwise).
10. A saved `config/dips/<mra name>.dip` overrides the whole `<switches>`
    value, third byte included, so an autofire `.mra` shows nothing for a
    game whose DIPs were ever changed until the file is deleted or "Reset
    settings" runs. Document; a `<rom index>`-borne unlock would be immune
    (offered, not done, in NMK16).
11. `.nvm` is keyed by the `.mra` **description**, `.CFG` and `.dip` by
    different keys (`.dip` by mra name, `.CFG` by setname). Status bits are
    saved only by System > Save settings.

### 4.B SDRAM, caches, buses

1. **96 MHz SDRAM with the toggle-handshake CDC**; consumers stay on
   `clk_sys`. `SDRAM_DQ` captured by exactly one register (fine vertical
   noise in every tile otherwise — timing "met", no warning). Each PLL
   output its own exclusive SDC clock group.
2. `sdram_req` accepts on the **rising edge** of `req` (level accept
   re-issued the old address); `sdram_arb` holds a served channel off until
   its `req` has been seen low (duplicate grants silently doubled every
   video fetch, then killed the Z80 when it moved onto an arbiter).
3. **Throughput, not latency**: one word per ~12 `clk_sys` round trip
   against one word per 20 for two 4bpp layers → separate ports per
   real-time layer, prefetch 16 pixels ahead, pair reads. Judge with
   `DBG_MISS_PAINT` (subtract the game's own pure magenta/cyan) and the
   sound-CPU write counters, not with frame diffs.
4. **Speculative-fetch race**: `rom_cache1`/`rom_cache_n` refetch on any
   address change, so feed them the bus address only while `sel_rom`
   (fx68k samples DTACK and data on successive `enPhi2`s; a fill landing
   between them corrupts the word — raphero's F-line exception). Registered
   `*_ready` flags are stale-high for one clock after an address change:
   use combinational compares on the registered address. 12 MHz here, the
   same speed that exposed it.
5. The 68000 needs the 16-pair prefetching cache (`rom_cache_n`): the
   1-pair cache stalled 13-20 % of every frame and the game visibly slowed.
   Re-run the `CPUFRAME romwait` audit after any SDRAM/port change.
6. **OKI**: jt6295's ADPCM fetch ignores `rom_ok`; `oki_rom_cache` + the
   `stall` ANDed into `cen` is mandatory behind SDRAM (37.6 % of sample
   bytes were stale — "corrupted sound effects"). No NMK112 here, so the
   bank-write `hold` case does not arise, but any clk-sampled register
   that changes the OKI address must respect the registered-`cen` window.
   Keep the golden-byte audit and the `unserved` counter.
7. OKI clock and pin 7 straight from the driver (2 MHz, pin 7 high →
   `ss=1`); NMK16 played samples two octaves low once. YM2203 4 MHz.
8. **Z80 read mux qualified by `mem_re`** (NMK-14); `in a,(n)` puts A on
   the high address byte.
9. **Unmapped reads return MAME's unmap value** (0 here), never 0xFFFF.
10. Clock enables from a 40 MHz base: per-mille accumulators, and never a
    `%`/`/` with a runtime modulus in a pixel path (−54.8 ns, +3k ALMs).
11. A ternary chain with an unsigned concatenation evaluates unsigned and
    turns `>>>` logical (tomagic's clipping thump): every mix term its own
    signed wire.
12. Watchdog + pause: if the watchdog is real, pausing the 68000 (OSD,
    hiscore, cheats, savestate park) must pause it too, or every pause
    longer than 3 s reboots the game.

### 4.C Quartus, fit, timing

1. **Asynchronous reads of any array = flip-flops.** The 1024-entry
   palette cost 14,776 ALMs; a 4 KB scroll RAM turned 65k → 163k cells; a
   4 KB MCU ROM 17,782 ALMs. Every RAM read here is registered, with the
   CPU side taking a one-cycle DTACK wait where needed (NMK-10, four
   times).
2. **A 16-bit array with byte-lane writes and a second read port is
   duplicated per port.** Use two 8-bit lane arrays, port A
   `if (we_hi) begin hi[a] <= d; q[15:8] <= d; end else q[15:8] <= hi[a];`,
   port B `qb <= {hi[b], lo[b]}` → one BIDIR_DUAL_PORT set. Verify in the
   fit report's RAM summary (no `__N` twins) and the entity table (a large
   *own* ALM count on a wrapper is the tell).
3. **The silent M10K cliff**: at ~539/553 blocks Quartus 17 stops
   inferring the framework's own RAMs with no message (hq2x, ascal,
   shadowmask become 20k flops). Look for `hq2x_buf:buf1` with registers
   in the map report; keep headroom (this core should sit well under —
   the sprite plane is the big consumer at ~90 M10K).
4. Quartus 17 syntax: no bare `for (...) assign` in generate loops
   (named begin/end), no bit-select on a function call result, a
   concatenation assigned to a narrower wire truncates silently (the
   17-bit `th_in1` cost player 2's start), regex edits can swallow the
   next port on the line (grep the replacement *and what follows*).
5. **Two-phase clock enables are gated in pairs**: sample `pause` on the
   ungated `enPhi2` (NMK-24, nine wrong fixes; a parity accident that wedges
   the sequencer mid-bus-cycle). Same for any multi-phase enable.
6. Timing: the worst path is usually the framework's `pll_hdmi`; check
   *which* path fails before blaming the change; seeds are a lottery near
   the top (sweep 4 seeds in parallel copies); 112 MHz is HQ2X's ceiling,
   96 MHz is comfortable — this core's 6 MHz pixel needs only 96.
7. Process: builds in rsync'd copies (exclude `db/`, `output_files*`,
   `sim/`, `mame*`, `.git`, include everything synthesis reads); never
   touch `.qip`/`.qsf` during a compile; `export PATH` to Quartus in the
   same command block; ≤ 4-5 parallel fits; `/tmp` tmpfs under 50 % or the
   Bash tool and g++ fail silently; `quartus_map` probes (8 min) before
   45-minute fits; save every shipped `.rbf` under `releases/` and track it.

### 4.D Video correctness (the class this core will spend most time on)

1. **Bitmap coordinates.** MAME positions tilemaps and sprites in bitmap
   space; the visible area here starts at bitmap row 16, so tilemap source
   y = screen y + 16 + scrolly. NMK16 was displaced by exactly its blanking
   widths for a week and nobody compared frames.
2. Use the full-width x in every wide-tilemap index (`rd_x[7:0]` repeated a
   third of the text layer). The 512-wide VIEW2 layers on a 256-wide screen
   need the 9-bit sum.
3. Sprite plane indexing with a real offset (`plane * PLANE_PX + addr`),
   never `{plane, addr}` — Quartus aliased out-of-range rows onto the
   displayed plane (lines through moving sprites, "flicker").
4. Registered header reads need a settle cycle per word (every sprite
   attribute came from the previous word; invisible because the compared
   frames had no sprites).
5. Swap the sprite plane only at the vblank trigger; hold a finished pass;
   a pass that outlasts a frame delays a frame rather than tearing. Skip
   wholly off-screen tiles on their first pixel; plot cached bytes in one
   cycle. Measure the pass with `SPRFRAME` in the hardware sim under
   autoplay, judge headroom at the hardware's own worst case.
6. If the CPU can rewrite the table while it is being snapshotted (the
   68000 keeps running during our copy; MAME's is instantaneous), hold
   the CPU off that RAM for the copy (DTACK + gated writes). Pandora's
   sprite RAM is the 68000's to write at any time; snapshot it at `eof`
   in one burst (4 KB = ~2k words, ~50 µs at 40 MHz) with the write port
   held, or double-buffer at the byte level.
7. Tile codes wrap `% total_elements` exactly (NMK-25: a mask for powers
   of two; the sprite ROM here is 1 MB = 8192 tiles, view2 1 MB = 4096
   16x16 tiles, both powers of two). Keep the wrap out of the per-pixel
   path.
8. Stacking: read the priority-buffer semantics, not just the loop order
   (NMK's "entry 0 on top" reversal broke ships under clouds). Pandora is
   a plain overwrite walk 0..511, so the **higher** index is on top;
   VIEW2's per-category draw order is 1.3's rule.
9. Nibble order: VIEW2 tiles are `_lsb` (low nibble = left pixel),
   Pandora `_msb`. Decode both against MAME's `gfx_element` in Python
   before writing RTL.
10. Flip = rot180 of the readback coordinates over the whole visible
    window, prefetch lookahead direction-aware (`x_look = flip ? x-16 :
    x+16`; the board striped, the zero-latency sim could not show it).
    "RTL flip == rot180(RTL no-flip)" is tautological — compare RTL vs MAME
    and hardware path vs reference path. Report non-blank frame counts.
11. **Compare demo frames with sprites, at exact frame numbers** (Lua
    `frame_done` + `scr:pixels()`; `-str` is seconds; file N is frame N+1;
    `snapshot()` under `-video none` returns a stale bitmap). Prove two
    frames are the same scene (near-zero diff) before diffing anything
    else; attract demos drift from MAME after ~1 minute (RNG), so later
    scenes go through the `video_state` harness (MAME RAM dump rendered
    through the video module).
12. Boot-phase software timers land a few frames apart between RTL and
    MAME (NMK-3/NMK-16): align by a diff matrix's diagonal, not by index;
    a HUD element can sit on its own diagonal. Not a bug.
13. Native MiSTer screenshots are exact for plain modes (and the right
    tool for pixel proofs); the capture box downscales and hides pixel
    differences; the screenshot under-reports width for scandoubled/HQ2X
    rasters (measure HDMI or simulate the mixer); MiSTer's screenshot rows
    can start mid-frame and repeat — decode overlay rows by marker colour.
14. **When pixels resist, read the driver line by line against the RTL**
    (ssmissin's missing `init_*` decode and the `.mirror()` treated as
    address bits were found in twenty minutes after days of frame
    statistics). For this core the candidates are the register/VRAM
    naming cross, the `>> 6` scroll units, the line-scroll row indexing,
    the 0x5B/0x5D offsets, the relative-position sprite accumulator, the
    byte-per-word sprite RAM, and the swapped latch-status bits.

### 4.E Audio

1. Isolate per source on both sides before trusting a mix number (FM was
   right, OKI 8-13 dB low, the aggregate looked like a uniform offset).
   Debug taps before the mix, MAME with `device_volume` 0 on the others.
2. `TB_DUMP_AUDIO` in every testbench from the start (a 37 % corruption
   rate went unnoticed for want of any audio output).
3. `audio_compare.py --offset-search`; trim silent intros; never judge
   from an 8-10 s `arecord` window (attract loops have silent stretches);
   record a full attract cycle or in-game.
4. A sound CPU that "plays but sounds subtly wrong" is a CPU flag bug
   until proven otherwise (two TLCS-90 flag bugs); the Z80 here is T80,
   already proven, but the same register-trace method exists if needed.

### 4.F Simulation harness

1. `HW_ROMS` as an additive parameter: the reference path stays
   byte-identical (hash the reference frames after every hardware-path
   change).
2. A hardware-mode testbench drives `rd_x/rd_y` from the core's **live**
   counters and samples `rd_rgb` continuously; a post-frame sweep starves
   the prefetch and paints false dashes. Dual-clock testbenches evaluate
   every clock transition (skipping falling edges hides rising edges).
3. Open dump files before the multi-minute ioctl loop, check a dump's
   **format** not its existence; avoid `--public-flat-rw` (10x slower) —
   add explicit debug ports; PPM filename buffers wide enough for absolute
   prefixes; `final` blocks do not print under `tb_gc`; every clock enable
   input of a standalone module tb must be driven (the TLCS-90 self-tests
   ran nothing for days).
4. Run lengths: games boot black for 20-70 frames; content at 140-600; use
   ≥ 320M cycles for late scenes; `TB_RAM_PER2=5` for a 100 MHz-equivalent
   SDRAM; parallel runs write PPMs to separate directories.
5. Never accept a rare-event counter reaching 0 without a per-event
   diagnostic and a rerun of the fix alone on the original timeline (the
   OKI "fix" that merely displaced the byte).
6. MAME Lua traps: keep tap/notifier tokens in globals or they are
   garbage-collected and the log silently stops; `-console` is not
   installed; `f.user_value = 0` works for DIPs (verify by reading the port
   over the bus); taps on I/O-port ranges may never fire — prove an
   experiment applied before reading its result; `screen:vpos()` is not
   exposed (use `time_until_vblank_*`); `frame_done` fires at VBOUT so a
   VRAM read there predates that frame's vblank writes; register names
   with `~` need the combined symbol; anchor trace comparisons at a
   landmarked instant, not "the same second".
7. A control that fails (coin+start changes nothing in MAME either) means
   the harness is broken, not the game. A "flat" frame is judged by what
   the game draws next. Any "pre-existing partial match" is an open defect
   until someone looks at the first non-matching frame (redfoxwp2 was
   noise for a week).

### 4.G Board tooling and process

1. Access: `SSH_ASKPASS` + `DISPLAY` + `< /dev/null`; rsync exit 23 is
   harmless (verify md5); `load_core` via `/dev/MiSTer_cmd`; core switch
   takes ~15 s; `screenshot` blocks during ROM upload (wrap in `timeout`,
   kill stale writers by PID); native shots ≥ 4 s apart after ~30 s of
   run time; the capture box hangs on back-to-back captures (≥ 1 s apart,
   `timeout 15`), records audio as `hw:2,0`, cannot lock 15 kHz direct
   video and shears at 31 kHz.
2. OSD scripting: F12 toggles; the cursor returns to the top item on every
   reopen; Right/Left switch pages; "Save settings" is 8 Downs on the
   System page (7 is Reset settings). Status bits are `config/<set>.CFG`
   byte n/8 bit n%8 — writing the file equals toggling in the OSD.
3. Debug bitstreams with on-screen overlays (8-px cells or 16-px/bit
   barcodes at the top of the active area, read from native screenshots)
   found the black screen, the OKI busy-wait, the hiscore wedge and the
   savestate freeze. Latch brief events in hardware (sticky bits); a "last
   value" cell is meaningless seconds after the event. **Build the probe;
   do not reason about the symptom.**
4. Smoke-test after every "neutral" rebuild (a swallowed port shipped a
   black, silent Raphero). Sweep all `.mra` before a release (load, settle
   45 s, shot, coin-coin-start, shot); look at the frames.
5. `pgrep -f`/`pkill -f` with a pattern that appears in the launching
   command kills the launcher (three times); match on `^quartus_` or
   `/proc/<pid>/cwd`. Background task output lives under
   `/tmp/claude-1000/.../tasks/`. Poll background builds proactively.
6. Keep a dated backup of the previous `.rbf` set on the card
   (`bak_pre_<change>/`) and of `MiSTer.ini` before touching it; restore
   both at the end of a test.

### 4.H Feature-specific traps

- **Savestates**: the CPU park overlay must outlive the bus cycle that
  fetches the RTE/RETN (fx68k captures the data bus on every phi2 until
  the cycle ends; T80 latches DI late in M1) — a freeze after every
  save/load, board-only, never reproduced in Verilator; park and release
  at VBlank edges; a load waits two extra VBlanks for the sprite double
  buffer; `pause` masked while the engine runs (the CPUs must execute to
  park); the DDRAM port is shared with `screen_rotate` and yields to it;
  `.ss` files load into DDR only at core start; hiscore's RAM grant must be
  gated with `~ss_active`; the round-trip test excludes frame 0. The Z80
  overlay lives at 0x0066 *from the NMI entry fetch on*, which is what lets
  it coexist with a game NMI handler there — Sand Scorpion's sound driver
  uses NMI for every command, so this is exercised constantly: test it.
- **Hiscore**: `hiscore.v` ignores its reset for extraction/upload
  (`hs_active` gating), has no synchronous reset (gate `pause_cpu` at the
  output), needs two reset windows for Reset Scores, a faked OSD edge for
  Save Scores, a `START_WAIT` past the RAM test, the dump-validation pass
  (garbage `.nvm` files hang games on their score screens), and the proof
  is patching the `.nvm`, never a round trip. The sim harness never reaches
  the restore; the board is the proof.
- **Pause**: video keeps running (per-pixel render from VRAM), audio
  muted, phase pairs.
- **CRT Adjust**: VBlank sampled at each HSync rise for the *following*
  window (`vb_hs`), the ring must be wider than the line (400 for 384;
  here 272 for 256), colour concatenation widths, ≥ 11 clocks per pixel,
  the fork's pipeline registers; Off must be bit-identical to native; the
  harness pushes flat colours through every mode and demands byte-exact
  pixels (geometry checks prove nothing about colour).
- **Direct video**: menumask bit 11 = `direct_video` hides Aspect ratio
  and Scandoubler Fx (HB), Orientation via bit 0; `fx` forced to 0 there;
  CRT Adjust and Flip screen on every output (the core cannot tell which
  monitor watches VGA_*); page headers accept the H/h prefix; `'B'` is
  mask index 11.
- **Orientation/scandoubler**: `screen_rotate` has no backpressure — the
  scandoubler must be off while the framebuffer is active (NMK-28);
  scanlines are disabled by the framework in FB mode; "Original" aspect
  follows rotation (3:4 when rotated).
- **Autofire**: pattern clocked by the game's vblank, phase restarts on
  each press, button 3 = plain fire while on; hidden unless the `.mra`
  opts in.
- **Keyboard**: MAME defaults; F2 = service-mode DIP toggle sampled at
  boot; gamepad and keyboard paths are independent (a gamepad-only bug is
  a `<buttons>` bug).

### 4.I Working method (the expensive ones)

- Dump the **value**, not just the address: a cache hitting on the wrong
  entry is invisible to address traces and hit flags (NMK-21b).
- Isolate before trusting an aggregate (audio gains, sprite headroom from
  a table count vs the hardware bound).
- Do the ratio check first: a CPU paused 1 % of the time that executes
  0 instructions is stalled, not starved (NMK-24's IACK at `$FFFFF4`).
- When a byte-pattern scan of a ROM finds nothing, enumerate the
  addressing modes from the decoder before concluding the write does not
  exist (the `LDW` watchdog reload).
- When a trace-driven fix targets one operand form, test the other legal
  operands of the same opcode group (`set/res b,g` with g ≠ A).
- Every retracted conclusion in NMK16 traced to comparing frames that were
  not the same scene, or to a probe that had not been proven to apply.
- Ship only what was measured; write the number and the method next to
  the claim; keep retractions in the record.

---

## 5. Open questions to settle in M0 (each is a measurement, not a guess)

1. **Raster timing.** Pixel clock, HTOTAL, VTOTAL, sync positions: no
   source. Pick 6 MHz / 384 / 264 as the parameter defaults (59.19 Hz,
   15.625 kHz), record it as a known unknown in `known-issues.md`, and
   invite a PCB measurement. Everything timing-related (interrupt instant,
   `set_vblank_time` 2500 µs ≈ 39 lines at this line rate — MAME's vblank
   IRQ fires at the start of that period, i.e. at bitmap line ~225-240
   depending on how MAME rounds; measure `vpos` at the interrupt with a
   Lua tap) hangs off these parameters.
2. **Clock plan**: 40 MHz `clk_sys` with per-mille enables (NMK16's
   proven arithmetic and testbenches) vs 48 MHz (integer dividers for 12,
   6, 4, 2 MHz). Recommendation: 48 MHz — the ratios are exact and the
   video retimer becomes 96/16 — unless the copied cores' cen assumptions
   (jt6295's `cen` semantics at 2 MHz, jt03 at 4 MHz) or the 12 MHz fx68k
   phase spacing argue otherwise. Decide with a one-hour review of the
   copied wrappers, not by habit.
3. **Sprite flip on the real board**: with the Flip Screen DIP on, does
   the game write bit 0 of `0x100001` (MAME's commented-out
   `m_sprite_flipx/y`), and does it set VIEW2 bits 8/9? Write tap in MAME
   with the DIP forced through a cfg file and read back. If the game does
   write bit 0, implement Pandora's flip from it (the chip has the
   mechanism) and document the divergence from MAME the way NMK-21c did
   for Afega's sprites.
4. **Do the scroll registers change mid-frame?** (write tap on
   0x300000-1F with `vpos`); decides whether registers are latched at
   frame start (MAME) or live.
5. **Which CALC1 registers does the game read?** (read tap on 0x200000-1F);
   the random-number read frequency decides how the LFSR is clocked.
6. **Unmapped reads**: confirm 0x0000 for the 68000 and the Z80 I/O read
   at port 4 (no read handler; MAME returns the unmap value) with a MAME
   read tap on an unmapped address the game touches, if any.
7. **Does the game test its work RAM at boot** (for `START_WAIT`), and
   does it ever use Pandora's "no clear" mode or the "unknown" IRQ?
8. **The `sandscrpb` mask ROMs**: are `ss501`/`ss502` byte-identical to
   the interleaved pairs? If not, the two sets need separate sim images
   and the audit covers both.
9. **Sprite pass budget**: 512 x 256 pixels = 131,072 plots per frame at
   one clock each is ~3.3 ms of a 16.9 ms frame at 40 MHz; comfortable,
   but the SDRAM byte fetches add ~80 clocks per 16x16 unit (NMK
   measurement) → +41k clocks; still under half a frame. Confirm in M3.

---

## 6. What I would do first

M0 in this order: scaffold and copy (a day of mechanical work, all
verifiable by building the copied unit tests); obtain the ROMs; the MAME
oracle captures and the five taps of section 5; the Python decode of both
tile layouts against `gfx_element`; the `.mra` generator with the
off-board load model. Then M1's video core against MAME state, because
VIEW2 and Pandora are the only genuinely new RTL and pixel-exactness there
de-risks everything downstream.
