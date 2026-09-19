# Known issues and open questions — Arcade-SandScrp_MiSTer

Numbered `SS-n`, in the style of the NMK16 project's own list: each entry
records what was measured, how, and what is still unknown. An entry is only
closed by a measurement, never by reasoning.

---

## SS-1 — The board's raster timing is not documented anywhere (OPEN)

`kaneko/sandscrp.cpp` configures the screen with `set_refresh_hz(60)`,
`set_vblank_time(2500 us)` marked *"not accurate"*, `set_size(256,256)` and
`set_visarea(0,255,16,239)`. None of that is a measurement: MAME's own screen
is a 256-line frame at exactly 60 Hz with a 38-line vblank, which no 15 kHz
arcade monitor produces.

`rtl/kaneko/video_timing_sandscrp.sv` therefore takes the raster as
**parameters**, defaulting to the confirmed values of the closest sibling
board — `kaneko/snowbros.cpp`, same PANDORA chip, `set_size(32*8, 262)` and
`"~57.5 - confirmed"`:

| parameter | default | gives |
|---|---|---|
| pixel clock | 12 MHz / 2 = 6 MHz | |
| `HTOTAL` | 384 | 15.625 kHz line rate |
| `VTOTAL` | 262 | 59.66 Hz |
| visible | x 0..255, bitmap rows 16..239 | 256x224 |

`VTOTAL` 264 would give 59.19 Hz. **A PCB measurement is the only way to
settle this**; nothing else in the core depends on it, because every
timing-derived quantity (the interrupt instant, CRT Adjust's ring size, the
video retimer) reads these parameters.

## SS-2 — Frame alignment of a MAME state capture (CLOSED, measured)

A capture's state dump and MAME's own frame are not the same instant, and
getting this wrong looks exactly like a rendering bug.

Measured on the 9,000-frame attract capture: MAME renders the whole frame at
`vblank_begin`, then raises the interrupt in the same instant; the game's
handler rewrites the VIEW2 scroll registers at vpos 218 of **every** frame
(43,725 of 43,800 register writes in the capture). A dump taken at Lua's
`frame_done` is therefore a whole frame stale.

`sim/oracle/sandscrp_capture.lua` dumps state at the 68000's **first read of
the IRQ cause register** (0x800001) after each vblank — the first thing the
handler does, before it writes anything, i.e. MAME's own render instant.
`tools/ss_video_check.py` then uses:

    MAME frame F  <-  VIEW2 state from dump F, Pandora table from dump F-1

The Pandora offset is the chip's own double buffer: `eof(F-1)` drew the table
as it stood then, and `screen_update` shows that buffer from frame F on.
Verified by sweeping both offsets independently against a moving demo frame
(the neighbouring choices give 6,263 and 38,274 differing pixels).

Frames in which the 68000 never reads the IRQ cause (its handler did not run)
have no dump; `tools/ss_state.py` walks back to the previous one, which is
correct precisely because nothing the handler would have written was written.

## SS-3 — A few sprite pixels per frame cannot be reproduced from any capture (CLOSED, measured)

Comparing rendered frames against MAME leaves a residue of 2-302 pixels on
frames with heavy sprite motion. It is not a rendering difference:

- **100 % of the residual pixels are sprite pixels.** No tile pixel has ever
  differed on any frame tested. (Measured over 13 gameplay frames: 790
  differing pixels, 790 of them sprite-sourced.)
- Two independent renderers — the RTL and `tools/ss_refrender.py`, a Python
  transcription of MAME's own algorithms sharing no code with it — produce
  **the same pixels** from the same dump, including the residual.
- The game writes the sprite table **continuously**: 1,572,469 writes over 900
  frames (1,747 per frame), of which **57.8 % land during the visible area**,
  not in vblank. MAME's Pandora snapshots that table at `eof`; a dump taken
  microseconds later already differs by a few entries, and one entry is a
  whole 16x16 object.

So the capture cannot reproduce MAME's input for these frames, and a
"pixel-exact" claim about them would be a claim about the capture, not the
core. The gate therefore measures **RTL vs the reference model** as the pass
criterion and reports RTL-vs-MAME alongside it.

This also has a hardware consequence, already designed for: the real PANDORA
reads the table while the CPU is writing it, so `rtl/kaneko/pandora.sv`
snapshots all 4 KB at the vblank edge with `cpu_hold` asserted, rather than
walking a table the 68000 is editing underneath it.

## SS-4 — Line scroll is never used in attract mode (CLOSED, measured)

`kaneko_tmap.cpp` names `sandscrp` as a line-scroll user, but **0 of 9,000
attract frames** enable it (control register bits 11/3 clear throughout).
It appears only in gameplay: a scripted play capture (`SS_PLAY=1`, coin at
frame 240, start at 300) enables it on layer 1 from frame 414 onward, for
2,436 of 5,400 frames.

This mattered: the first line-scroll frame rendered showed **22,921 wrong
pixels** from a one-cycle bug (below) that the entire attract mode could not
have revealed. Any future change to the tile renderer must be re-gated
against the play capture, not just the attract one.

## SS-5 — MAME flips both VIEW2 layers from control bits 9/8 (CLOSED, measured)

`kaneko_tmap.cpp`'s register documentation describes two flip pairs: bits 9/8
("BG Flip X/Y") and bits 1/0 ("FG Flip X/Y"). `prepare_common()` **never reads
bits 1/0** — it gives `m_tmap[0]` *and* `m_tmap[1]` the flip taken from bits
9/8. The core matches the code.

This cannot be distinguished by observation on this board: with the Flip
Screen DIP on, Sand Scorpion writes 0x0303 — both pairs at once. A board with
a logic analyser, or a game that sets only one pair, would settle it.

## SS-6 — Sprite flip is a divergence from MAME, on purpose (OPEN, evidence recorded)

`sandscrp.cpp` has the two lines that would flip the sprites commented out:

    //  m_sprite_flipx = BIT(data, 0);
    //  m_sprite_flipy = BIT(data, 0);

so MAME's flipped-screen output has the **layers** mirrored and the sprites
not — which cannot be what the board does.

Measured: with the Flip Screen DIP off the game writes 0x1a/0x32/0x3a to the
IRQ-acknowledge register at 0x100001; with it on, it writes **0x1b/0x33/0x3b**
— the same values with bit 0 set, exactly the bit MAME's commented-out code
reads. The game only sets that bit when the DIP is on, and PANDORA has the
flip mechanism (`kan_pand.cpp` `m_flip_screen`).

`rtl/kaneko/pandora.sv` implements the flip from that bit. The consequence is
that a flipped-screen frame will differ from MAME on every sprite **by
design**; the gate compares the flipped capture with the sprite flip off, so
that the layer-flip arithmetic is still checked against MAME exactly.
Confirm on hardware before release.

## SS-7 — The game reboots itself once during every cold boot (CLOSED, measured)

The driver's watchdog (`WATCHDOG_TIMER ... from_seconds(3)`, MAME's own
comment: *"a guess, and certainly wrong"*) fires at t = 3.000 s of every cold
start: the 68000 sits at PC 0x9b4 in a tight loop (`bra` to itself) waiting on
a work-RAM signature at 0x700070, executing 7.2 million ROM reads and exactly
one RAM write, until the watchdog resets the machine; it then boots normally
from PC 0xe96.

Two consequences, both already handled:

- MAME **re-runs an `-autoboot_script` after every machine reset**. Both Lua
  scripts here guard with a `_G` flag; without it a second tracer instance
  truncates every output file and doubles every tap.
- The core's own watchdog must reproduce the reboot, and must be **paused**
  whenever the 68000 is (OSD, hiscore, cheats, savestates) or every pause
  longer than 3 s will reboot the game.

Whether the real board does this, or whether MAME's 3-second guess simply
fires before the game's own initialisation completes, is **unknown**.

## SS-8 — `sandscrpb`'s mask ROMs are the parent's pair, interleaved (CLOSED, verified)

Checked byte for byte at `.mra` generation time:

    ss501.ic30 == interleave(3.ic33 even, 4.ic32 odd)     True
    ss502.ic16 == 5.ic16 + 6.ic17                          True

So all three sets stream **byte-identical** graphics and sound regions and
take the same RTL path; only the 68000 program differs (194,098 bytes between
the parent and `sandscrpa`, 169,051 between the parent and `sandscrpb`).
`tools/gen_sandscrp_mra.py --check` asserts this on every run.

## SS-9 — Priority categories 3, 4 and 6 have never been observed (OPEN)

Across 16,800 captured frames the game uses tile categories 0, 1, 2, 5 and 7
only. The renderer implements all eight and the reference model agrees with
it, but categories 3, 4 and 6 — including the 4-vs-sprite boundary that
decides whether a tile covers a sprite — are exercised only by construction,
never by the game. A synthetic state dump would close this.
