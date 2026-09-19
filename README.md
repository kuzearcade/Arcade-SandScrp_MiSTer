# Arcade-SandScrp_MiSTer

Sand Scorpion (FACE, 1992) for the MiSTer FPGA platform — a from-scratch
implementation of the Kaneko VIEW2 tilemap chip and PANDORA sprite generator,
built against MAME `kaneko/sandscrp.cpp` as the behavioural reference.

One `.rbf` serves all three sets: `sandscrp`, `sandscrpa` (earlier program)
and `sandscrpb` (*Kuai Da Shizi Huangdi*, revised hardware). They share one
machine configuration and, as the ROM audit confirms, byte-identical graphics
and sound data; only the 68000 program differs.

**Status: in development.** The video path is verified pixel-exact against
MAME; the full board runs in simulation; nothing has been built for or run on
real hardware yet. See `docs/PLAN.md` for the plan and `docs/known-issues.md`
for what is measured, what is assumed and what is still open.

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

- **Video: 61 of 61 frames identical to an independent model of MAME.** Each
  frame is rendered from a MAME state capture and compared three ways — the
  RTL, a Python transcription of MAME's own algorithms sharing no code with
  it, and MAME's own pixels. 31 of the 61 are additionally pixel-exact against
  MAME; the rest deviate identically in both renderers, because the game
  rewrites its sprite table 1,747 times per frame and no capture taken after
  MAME's own snapshot can reproduce it (`docs/known-issues.md` SS-3).
- Frames cover the title, the attract demo, the score table, gameplay with
  line scroll active, both layers disabled, and the Flip Screen DIP.
- The seven unit tests inherited from the NMK16 project (SDRAM controller and
  arbiter, ROM caches, OKI cache, video retimer, CRT Adjust chain) all pass.

## Repository

    rtl/kaneko/        view2.sv, pandora.sv, kaneko_hit.sv, video_sandscrp.sv,
                       video_timing_sandscrp.sv          -- new RTL
    rtl/sandscrp/      sandscrp_core.sv                   -- the board
    rtl/               SDRAM controller, ROM caches, prefetch, video retimer,
                       CRT Adjust chain, cheats, savestates  -- from Arcade-NMK16_MiSTer
    sim/oracle/        the MAME capture script and bus tracer
    sim/rtl/           video_state (one frame of video), sandscrp (whole board),
                       and the inherited unit tests
    tools/             .mra generator + load model, tile decoders, the reference
                       renderer, the frame gate, board scripts
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
