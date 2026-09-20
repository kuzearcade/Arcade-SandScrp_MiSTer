# Arcade-SandScrp_MiSTer

Sand Scorpion (FACE, 1992) for the MiSTer FPGA platform — a from-scratch
implementation of the Kaneko VIEW2 tilemap chip and PANDORA sprite generator,
built against MAME `kaneko/sandscrp.cpp` as the behavioural reference.

One `.rbf` serves all three sets: `sandscrp`, `sandscrpa` (earlier program)
and `sandscrpb` (*Kuai Da Shizi Huangdi*, revised hardware). They share one
machine configuration and, as the ROM audit confirms, byte-identical graphics
and sound data; only the 68000 program differs.

**Status: in development.** Milestones 0 to 3 of `docs/PLAN.md` are done and
measured: the video path, the whole board, and the whole board with every ROM
byte coming out of a real SDRAM controller are each verified pixel-exact
against MAME, savestates round-trip, and the core synthesises. Milestones 4
and 5 — the MiSTer top level, a bitstream, and hardware — have not been
started, and nothing has run on a board. See `docs/PLAN.md` for the plan,
`docs/hw-bringup.md` for milestone status, and `docs/known-issues.md` for what
is measured, what is assumed and what is still open.

## The board

| Part | Clock | Notes |
|---|---|---|
| TMP68HC000N-12 | 12 MHz | `fx68k` |
| Z8400AB1 (Z80A) | 4 MHz | `T80`; reads **both** DIP banks through the sound chip |
| YM2203C + Y3014B | 4 MHz | `jt03`; DSW1 on port A, DSW2 on port B |
| OKIM6295 | 2 MHz, pin 7 high | `jt6295` |
| VIEW2 | — | two 512x512 tilemaps of 16x16x4 tiles, per-row line scroll, 8 priority categories — **new RTL** |
| PANDORA (PX79C480FP-3) | — | 512 sprites drawn into a double-buffered 256x256 plane — **new RTL** |
| CALC1 | — | rectangle collision, 16x16 multiply, random — **new RTL** |

`clk_sys` is 48 MHz, which divides exactly into every clock on the board:
68000 /4, Z80 and YM2203 /12, OKI /24, pixel clock /8 = 6 MHz.

## Verification

Every claim here is a measurement; the method is in `docs/sim-harness.md`.

- **The whole board, run from reset with nothing preloaded, is pixel-exact
  against MAME**: **43 of 44** dumped frames match with zero differing pixels,
  through the boot sequence, the FACE logo animation and the title screen. The
  watchdog reboot the game needs in order to boot at all fires at the core's
  frame 180 against MAME's 179. The offset between the two timelines drifts, as
  two independently running machines do; held at the single best offset, 27 of
  43 still match exactly. The one frame that matches at no offset is a boot
  flash: the core renders one line ahead of the raster like the board, so a
  palette write during the visible area tears the frame, which MAME (rendering
  whole frames at vblank) never shows.
- **The same core with every ROM byte coming out of the real SDRAM controller
  is also pixel-exact against MAME**, and an exhaustive golden-byte audit walks
  all **3,801,088** bytes of every region through the real caches and the real
  controller with **0 wrong and 0 timeouts**.
- **Video: 61 of 61 frames identical to an independent model of MAME.** Each
  frame is rendered from a MAME state capture and compared three ways — the
  RTL, a Python transcription of MAME's own algorithms sharing no code with
  it, and MAME's own pixels. 31 of the 61 are additionally pixel-exact against
  MAME; the rest deviate identically in both renderers, because the game
  rewrites its sprite table 1,747 times per frame and no capture taken after
  MAME's own snapshot can reproduce it (`docs/known-issues.md` SS-3).
- Frames cover the title, the attract demo, the score table, gameplay with
  line scroll active, both layers disabled, and the Flip Screen DIP.
- **CALC1: 200,000 randomised cases against a transcription of MAME's own
  collision and multiply code, 0 mismatches**, including values straddling
  0x8000, sums that overflow 16 bits and deliberately equal coordinates.
- **Savestates round-trip.** Two images of the same state, one reached directly
  and one through a save and load, are diffed word for word: every region —
  work RAM, VIEW2 VRAM, palette, sprite RAM, Z80 RAM, the sound-chip shadow and
  the registers — comes back bit-identical, bar the two CPUs' own parked
  program counters.
- The seven unit tests inherited from the NMK16 project (SDRAM controller and
  arbiter, ROM caches, OKI cache, video retimer, CRT Adjust chain) all pass,
  alongside the CALC1 test written here.
- **Synthesis** (`quartus_map`, Cyclone V 5CSEBA6): 5,229 ALMs of 41,910 and
  1,829,062 block-memory bits of 5,662,720, with every array -- the sprite
  plane, both line buffers, all eight VRAM lanes, the palette, the work RAM --
  inferred as real M10K rather than flip-flops.

## Repository

    rtl/kaneko/        view2.sv, pandora.sv, kaneko_hit.sv, video_sandscrp.sv,
                       video_timing_sandscrp.sv          -- new RTL
    rtl/sandscrp/      sandscrp_core.sv    the board, including its savestate bus
                       sandscrp_rom_hw.sv  the SDRAM side: caches, arbiters, download
    rtl/               SDRAM controller, ROM caches, prefetch, video retimer,
                       CRT Adjust chain, cheats, savestates  -- from Arcade-NMK16_MiSTer
    sim/oracle/        the MAME capture script and bus tracer
    sim/rtl/           video_state    one frame of video from a MAME state dump
                       sandscrp       the whole board, plus the savestate engine
                       sandscrp_hw    the same core with real SDRAM underneath
                       kaneko_hit_test and the inherited unit tests
    tools/             .mra generator + load model, tile decoders, the reference
                       renderer, the frame gates, board scripts
    releases/          the three .mra files

## Building the ROM images

The `.mra` files, the hardware-mode ioctl stream and the simulation ROM images
all come from **one table** in `tools/gen_sandscrp_mra.py`, so they cannot
disagree about where a region lives:

    python3 tools/gen_sandscrp_mra.py            # releases/*.mra
    python3 tools/gen_sandscrp_mra.py --check    # off-board load model
    python3 tools/gen_sandscrp_mra.py --simroms  # $readmemh images for the sims

## Attribution

Built on the MiSTer framework and on these cores, fetched by
`tools/bootstrap.sh` at the commits pinned in `deps.lock`: fx68k (Jorge Cwik),
T80 (Daniel Wallner lineage, MiSTer-devel), jt12/jt03 and jt6295 (Jose
Tejada), the MiSTer hiscore module (Alan Steremberg, Jim Gregory) and CRT
Adjust (Umberto Parisi). The SDRAM controller, the hiscore module and
`crt_vsize` carry local modifications, described in `deps.lock`.

Sand Scorpion is © 1992 FACE. No ROM data is included in this repository.
