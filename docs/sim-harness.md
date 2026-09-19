# Simulation and MAME-oracle harness

Three harnesses, each answering a different question, plus the MAME-side
capture they all compare against.

```
MAME 0.289  --sim/oracle/sandscrp_capture.lua-->  frames/f<F>.raw   (pixels)
                                                  state/i<F>.bin    (VIEW2 + palette + PANDORA at the render instant)
                                                  taps.log          (68000 accesses with vpos)
                                                          |
                    +-------------------------------------+------------------------------------+
                    |                                     |                                    |
        tools/ss_refrender.py                 sim/rtl/video_state                     sim/rtl/sandscrp
        (Python model of MAME)                (RTL video only, HW_ROMS=0)             (whole board, HW_ROMS=0)
                    |                                     |                                    |
                    +--------- tools/ss_video_check.py ---+                     frames vs the MAME capture
```

## The MAME capture — `sim/oracle/sandscrp_capture.lua`

    SS_OUT=<dir> SS_FRAMES=9000 [SS_PLAY=1] [SS_FLIP=1] \
      mame sandscrp -rompath mame_roms -video none -sound none -nothrottle \
           -skip_gameinfo -seconds_to_run 200 -autoboot_script sim/oracle/sandscrp_capture.lua

Writes, per frame: the visible 256x224 pixels exactly as MAME rendered them
(`screen:pixels()`, **not** `machine.video:snapshot()`, which hands back a
stale bitmap under `-video none`), the VIEW2 VRAM/registers, the palette and
the PANDORA table, and a tap log of every 68000 access to the I/O ranges with
the raster line it happened on.

Three traps, each of which cost real time here or in the NMK16 project:

- **State is dumped at the interrupt instant, not at `frame_done`.** MAME
  renders the whole frame at `vblank_begin` and raises the interrupt in the
  same instant; the game's handler rewrites the scroll registers at vpos 218
  of every frame. A `frame_done` dump is therefore a whole frame stale. The
  script dumps at the 68000's first read of 0x800001 (`state/i<F>.bin`), which
  is the render instant. See docs/known-issues.md SS-2.
- **MAME re-runs an `-autoboot_script` after every machine reset**, and this
  game reboots itself once during every cold boot (SS-7). Both Lua scripts
  guard with a `_G` flag; without it the second instance truncates every
  output file and doubles every tap.
- **Tap handles live in globals.** A handle assigned to a local is garbage
  collected and the tap silently stops logging.

`SS_PLAY=1` coins up, presses start and autofires, because the attract mode
never enables VIEW2's line scroll — the feature is only reachable in a stage
(SS-4), and the first frame that used it exposed a real bug.

## `tools/ss_refrender.py` — an independent model of MAME

A direct Python transcription of `kaneko_tmap.cpp`'s `prepare_common` plus
`tilemap.cpp`'s scroll/flip arithmetic, `kan_pand.cpp`'s `draw`,
`sandscrp.cpp`'s `screen_update` and `emupal`'s xGRB_555. It shares no code
with the RTL and reads the same dumps.

It exists to make a disagreement **attributable**:

| RTL vs model | model vs MAME | meaning |
|---|---|---|
| differs | — | an RTL bug |
| identical | identical | correct |
| identical | differs | the dump does not describe what MAME drew, i.e. the capture, not the core |

The third row is not hypothetical: it is every remaining deviation on this
project (SS-3).

## `sim/rtl/video_state` — one frame of RTL video from one MAME state

    make                                   # build
    ./obj_dir/Vvideo_state_top dump/f560_ out.ppm [sprite_flip]

Loads a state dump through the core's real CPU write ports (not by
`$readmemh` into the arrays, so the write paths are exercised too), runs two
PANDORA `eof`s — one to draw, one to swap — then samples a whole frame off
the module's own live raster at `ce_pix`, which is how the real readback is
sampled. `tools/ss_state.py` splits a capture dump into the files it loads.

    tools/ss_video_check.py <capture> --frames 560,1400,...

runs the three-way comparison above over a list of frames and prints a table.
This is the M1 gate. Current standing: **RTL == the reference model on 61 of
61 frames** across three captures (attract, Flip Screen DIP on, gameplay),
of which 31 are additionally pixel-exact against MAME's own frame.

## `sim/rtl/sandscrp` — the whole board

    make roms      # $readmemh images from mame_roms/, via the .mra table
    make run       # boot

`rtl/sandscrp/sandscrp_core.sv` with fx68k, T80, jt03, jt6295, CALC1, the
latches, the interrupt merger and the watchdog, sampled off its own raster.
Environment: `TB_CYCLES`, `TB_DUMP_FROM/TO/EVERY/DIR`, `TB_DSW1/2`, `TB_FLIP`,
`TB_AUDIO` (raw signed 16-bit mono at 48 kHz, opened **before** the long loop),
`TB_COIN`/`TB_START`/`TB_FIRE`, `TB_REPORT`.

Throughput is about 440,000 clk_sys cycles per second, so one second of board
time is roughly 110 seconds of wall clock; reaching the title screen is a
20-minute run. Two consequences worth knowing before starting one:

- **The watchdog timeout is a build parameter** (`WDOG`, default the real 3 s =
  144,000,000 cycles at 48 MHz). The game hangs on a cold boot until the
  watchdog reboots it (SS-7), so it cannot boot without one — but a timeout
  short enough to save simulation time (0.1 s was tried) also fires during the
  game's own initialisation and reboots it forever.
- Progress lines report the non-blank pixel count alongside the counters, so a
  run that has gone black is visible without waiting for frame dumps.

## Reading the numbers honestly

- Report the non-blank pixel count next to every frame match. "0 differing
  pixels" between two black frames means nothing.
- Prove two frames are the same scene before diffing anything else. The
  attract demo drifts from MAME within a minute (CALC1's random source alone
  guarantees it), so later scenes go through `video_state`, not the timeline.
- A rare-event counter reaching zero is not a fix until there is a
  per-event diagnostic saying which events stopped happening.
