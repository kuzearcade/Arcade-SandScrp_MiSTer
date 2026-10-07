# Known issues and open questions — Arcade-SandScrp_MiSTer

Numbered `SS-n`, in the style of the NMK16 project's own list: each entry
records what was measured, how, and what is still unknown. An entry is only
closed by a measurement, never by reasoning.

**Four are open.** Two of them (SS-1 and SS-6) cannot be answered anywhere but
on the board; the other two are answerable in simulation and have simply not
been chased yet.

| | | |
|---|---|---|
| SS-1 | The board's raster timing is not documented anywhere | **OPEN** — needs a PCB measurement |
| SS-2 | Frame alignment of a MAME state capture | closed |
| SS-3 | A few sprite pixels per frame cannot be reproduced from any capture | closed |
| SS-4 | Line scroll is never used in attract mode | closed |
| SS-5 | MAME flips both VIEW2 layers from control bits 9/8 | closed |
| SS-6 | Sprite flip is a divergence from MAME, on purpose | **OPEN** — evidence recorded, board is the tie-breaker |
| SS-7 | The game reboots itself once during every cold boot | closed |
| SS-8 | `sandscrpb`'s mask ROMs are the parent's pair, interleaved | closed |
| SS-9 | Priority categories 3, 4 and 6 have never been observed | **OPEN** — needs scenes that use them, if any exist |
| SS-10 | The FM chip makes a sound during boot that MAME does not | **OPEN** — isolated to the FM; levels measured and closed (0.979 band corr) |
| SS-11 | Whole-board simulation matches MAME pixel for pixel | closed |
| SS-12 | The hardware ROM path starves both CPUs | closed |
| SS-13 | Savestates: the image is complete, and one bit of it was missing | closed |
| SS-14 | The sprite RAM was being built out of flip-flops | closed |
| SS-15 | First bitstream on hardware: a perfectly timed black screen | closed |

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
| `VTOTAL` | 262 | 59.64 Hz |
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

## SS-10 — The FM chip makes a sound during boot that MAME does not (OPEN)

Measured on the first whole-board run: the core's mix has an audible burst in
its first second (RMS 212, peak 8,168 of full scale), while MAME renders
**silence for the first 15 seconds** and only starts the attract music at
t = 16 s (RMS ~4,600 from there).

It is not a case of the Z80 doing something different: both sides write the
YM2203 at the same rate through the boot phase (MAME 4.1 writes per frame;
the core 274 writes by frame 60, i.e. 4.6 per frame), so the sound CPU is
executing the same code. Something in the FM state — an envelope, a key-on,
or jt03's own reset behaviour — is producing output the real chip would not.

Do not chase this from the mix. Isolate first, as NMK16's audio work had to:
a per-source tap on the core's side, and MAME with `device_volume` zeroed on
the other chip, then compare the two sources separately. A mix number that
looks like a uniform offset has already once been an 8-13 dB error in one
source hiding inside a correct one.

Also note for anyone re-rendering MAME's reference audio: `-wavwrite` with
`-sound none` writes a perfectly silent WAV and no warning.

### 2026-09-20: measured over the attract music

A 30 s capture of the core against the same MAME render, compared over the 13 s
window where both are playing (MAME is silent until 15.58 s):

| | |
|---|---|
| Alignment | core lags MAME by 50 ms |
| Mean band correlation, 24 bands | **0.62** (the M2 gate is 0.95) |
| Envelope correlation | 0.56-0.70 |
| Level | core **4.97 dB** quieter, RMS 3,872 against 6,859 |

So the sound CPU reaches the same tune at the same moment and every band
correlates positively — the failure is in level and envelope, not in timing or
in which notes play. The boot burst above is reproduced unchanged (core RMS 212
at reset, MAME silent).

Two candidate explanations were tested and **eliminated**:

- **Not aliasing in the testbench.** Its 48 kHz dump is a naive decimation with
  no anti-alias filter. Low-passing both sides at 24, 12, 8, 4 and 2 kHz leaves
  the envelope correlation at 0.56 at every cutoff.
- **Not MAME's output effects.** MAME 0.289 puts Filters, Compressor, Reverb
  and Equalizer in the speaker's default chain. Re-rendering with the chain
  removed from `cfg/sandscrp.cfg` gives a **bit-identical** file.

The isolation this entry has always called for is still the next step, and it
is now clear what blocks it: MAME exposes no per-device gain. Lua does not bind
`set_output_gain`, and the `<mixer>` block in the config carries the speaker's
node map rather than device volumes. Isolating will mean a per-source tap on
the core's side (`dbg_ym_snd` / `dbg_oki_snd` are already on the core, just not
wired through `sandscrp_ref_top` to the testbench) and, on MAME's side, a
method yet to be found.

## SS-11 — Whole-board simulation matches MAME pixel for pixel (CLOSED, measured)

The complete core — fx68k executing the real program out of ROM, the Z80 and
its sound chips, CALC1, VIEW2, PANDORA, the palette, the interrupt merger and
the watchdog, with nothing loaded from a MAME state dump — was run from reset
and its frames compared against the MAME capture.

- The watchdog reboot that the game needs in order to boot at all (SS-7) fires
  at the core's frame 180. MAME's fires at its frame 179.
- Five consecutive dumped frames of the boot animation (frames 250 to 290, with
  116, 312, 1,582, 1,532 and 3,063 non-blank pixels) are **pixel-exact** against
  MAME's own frames, all at a constant offset of +3 frames.

The +3 is the expected boot-timer drift between two independent timelines and
shows up as a diagonal — the same offset across a run of frames — which is how
NMK16's lesson says to read it, rather than as a single alignment number.

Frames during the boot flash do NOT match, and cannot: the core renders in real
time, one line ahead of the raster like the board, so a palette write during
the visible area tears the frame, while MAME renders the whole frame at vblank.
One such frame was captured half black and half white against MAME's uniform
white. This is a property of drawing the way the hardware draws.

## SS-12 — The hardware ROM path starves both CPUs (CLOSED, measured)

The reference simulation (SS-11) is pixel-exact, but the same core with its
ROM bytes coming out of the real SDRAM controller does not boot. Three real
bugs were found and fixed along the way, each invisible to the reference
simulation because it indexes plain arrays:

1. **The 68000's program address was 15 bits, not 19.** Every read wrapped
   every 64 KB of a 512 KB ROM; both CPUs executed garbage, the 68000 never
   reached its own boot-signature write, and the Z80 spun on the YM2203 at 487
   writes per frame against MAME's 4.1.
2. **The program cache saw the raw bus address.** `rom_cache_n` refetches on
   any address change, so every RAM, VRAM or I/O access started a speculative
   read whose fill can land between the 68000's DTACK sample and its data
   latch. The address is now held while the bus is not selecting ROM, which is
   what the NMK16 cores do for the same reason.
3. **Ports 0 and 1 were wired straight to the controller.** The caches speak
   `sdram_req.sv`'s handshake, not `rtl/sdram.sv`'s req/ack. The names line up,
   so it looks right and delivers garbage. Ports 2 and 3 worked from the start
   because `sdram_arb` contains an `sdram_req` — and, further, the caches HOLD
   their request high until data arrives while a bare `sdram_req` wants a
   one-cycle pulse, so even a correct adapter is not enough: every port needs
   an arbiter, including the ones with a single consumer.

The instrumentation was built rather than guessing further, and named the
cause on its first run. Two more bugs, both in the download:

4. **`ioctl_wait` was tied low.** A write takes the controller about eight
   clk_sys cycles and nothing queues, so the loader outran it: the counters
   showed **376,965 of 3,014,656 bytes** reaching the SDRAM, one in eight.
   Every consumer then read zeros -- which is exactly why the 68000 executed
   rubbish and the Z80, reading a ROM full of 0x00 NOPs, never wrote its sound
   chip. Backpressure now comes from the port's own busy.
5. **The download's request was a one-cycle pulse.** An arbiter samples
   requests in its own clocked block and can miss one, and it missed exactly
   one: `requests raised 3014656, writes completed 3014655`. The one it missed
   was the FIRST write of the download, so the 68000's reset vector read 0000
   while every other byte was provably correct -- a single wrong word out of
   three million, and enough to stop the machine. The request is now held
   until the write completes, the way every cache on the other ports already
   holds its own.

And one more, found the same way: **every cache must be held in reset for the
whole download**. The program cache otherwise fills from SDRAM that has not
been written yet and serves those zeros as a HIT forever.

### The gate

Every byte of every region walked through the real cache and the real
controller and compared against the image the `.mra` generator produced:

| region | checked | wrong | timeouts |
|---|---|---|---|
| maincpu (68000 words) | 262,144 | 0 | 0 |
| audiocpu (Z80 bytes) | 131,072 | 0 | 0 |
| sprites | 1,048,576 | 0 | 0 |
| view2 layer 0 | 1,048,576 | 0 | 0 |
| view2 layer 1 | 1,048,576 | 0 | 0 |
| oki | 262,144 | 0 | 0 |
| **total** | **3,801,088** | **0** | **0** |

Every channel's fetches started equals its fetches finished, and every SDRAM
port's requests equal its acknowledgements. The core then boots through the
SDRAM path with the same behaviour as the reference simulation: at frame 60
the 68000 has written its boot signature (0x123 at 0x700070) and the Z80 has
made 278 YM2203 writes against the reference's 274, with ROM reads within
1.7 % (2,454,833 against 2,414,590 -- the difference is the SDRAM latency the
reference simulation does not have).

And the picture that comes out of it, compared against MAME's own frames:

| hardware-path frame | MAME frame | differing pixels | non-blank |
|---|---|---|---|
| 260 | 264 | **0** | 314 |
| 280 | 284 | **0** | 1,687 |
| 300 | 304 | **0** | 3,940 |

Pixel-exact, at a constant +4 offset -- one frame later than the reference
simulation's +3 (SS-11), which is the SDRAM latency the reference path does
not have. The sprite pass takes 106,797 clocks of a frame's 804,864, with 0
late swaps.

The lesson stands as written: a frame-level symptom cannot distinguish a cache
that never fills from one that fills with the wrong bytes. Five bugs, and the
counters named every one of them; the three theories tried before building
them were all wrong.

## SS-13 — Savestates: the image is complete, and one bit of it was missing (CLOSED, measured)

The engine is wired in and works end to end on the reference simulation
(`sim/rtl/sandscrp`, `TB_SS_SAVE`/`TB_SS_LOAD`/`TB_SS_CMP`):

- both CPUs park on request — the 68000 through a level-7 interrupt into a
  monitor served from an overlay at 0x0F0000, the Z80 through NMI into the
  monitor at 0x0066, which on this board shares that address with the game's
  own NMI handler and still coexists with it;
- the image streams out to DDR and back, both operations report success
  (`SAVE ok at frame 307`, `LOAD ok at frame 339`);
- after the load the machine resumes the correct scene and plays on.

### The gate: a word-for-word diff, not a look at the picture

Three saves and one load make the comparison fair. Slot 0 is the state at T;
slot 1 is the state K frames after that save resumes (T+K, reached directly);
slot 0 is then loaded and slot 2 taken K frames after **that** resumes (T+K,
through a round trip). Slot 1 and slot 2 are the same state reached two ways,
so every differing word is restore error — named, not inferred from where
sprites landed.

| region | words | differ |
|---|---|---|
| work RAM | 32,768 | 2 |
| VIEW2 VRAM (tiles + line scroll) | 8,192 | **0** |
| palette | 2,048 | **0** |
| PANDORA sprite RAM | 4,096 | **0** |
| Z80 RAM | 8,192 | 2 |
| YM2203 register shadow | 256 | **0** |
| registers | 128 | **0** |

The two remaining work-RAM words and the two Z80-RAM words are the CPUs' own
park artifacts: the 68000's pushed SR and PC at 0x70fff4 (0x2004 against
0x2000, 0x0b90 against 0x0b8a — a couple of instructions apart) and the Z80's
equivalent on its own stack. They differ because the two saves parked at
slightly different instructions: the interrupt that parks a CPU lands relative
to the raster, and a load shifts that phase. Each machine resumes from its own
parked PC, consistent with its own stack, so this is the floor of the test.

### Three bugs it found, each invisible without it

1. **The register-word decode used prefix matches.** `ss_mi[6:4]==1` covers
   words 16-31, so CALC1's range swallowed the 68000's SSP/USP at words 28-31.
   They read back as CALC1 registers and were never restored. The ranges are
   explicit now.
2. **CALC1's random generator free-ran on clk_sys**, so it could never survive
   a round trip — two runs are never the same number of clocks apart, and the
   game reads that generator. It now advances once per **read** of the random
   register, which is also what MAME's `machine().rand()` does (it advances per
   call, not per cycle). The CALC1 unit test needed an idle clock between reads
   to match: a real bus cycle has one, and two back-to-back reads without it
   look like a single held cycle.
3. **PANDORA's displayed-plane index was not in the image.** It decides which
   of the two sprite planes is on screen, so restoring it wrong leaves the
   sprites permanently one `eof` out of step with the tilemaps. It is saved
   now, and the sprite engine is frozen while the machine is parked.

### A hypothesis that was wrong, and the measurement that said so

A round trip left 1,539 pixels of 3,044 non-blank different from the picture
the same machine drew without one. The explanation offered was a **sub-frame
phase shift**: the park moving where in the frame the game's per-frame update
lands, tearing at a different scanline, since this core renders one line ahead
of the raster like the board rather than whole frames at vblank.

It was wrong. Dumping the restored frame alongside every reference frame and
asking, per row, which one it matches:

- the differing rows span 58-162, which is simply where the objects are (rows
  0-57 and 163-223 hold no content at all) — no band, no boundary;
- the per-row best match scatters across seven reference frames (296-302),
  where a tear would split cleanly into two;
- only 9 of 105 rows match any reference frame exactly, where a tear would
  have nearly every row matching one side or the other exactly.

The word diff, re-run at the distance the picture comparison actually uses,
named the cause instead: everything that decides the picture was bit-identical,
and exactly one register word differed —

    word 0x0e124 (misc 36, the PANDORA displayed-plane index): direct 1, round trip 0

— the two runs were showing different sprite buffers, so every moving object
sat one animation step out while the static tiles were untouched. That is the
scattered, object-shaped signature the rows found, and nothing like a tear.

### What remains

The parity can still re-diverge **between two differently-timed runs**: the
plane swaps only when a draw pass completes, so runs parked for different
numbers of frames (7 for a save, 9 for a load) end up an odd number of passes
apart, and the displayed buffer is a function of elapsed frames while the two
frames being compared sit at different absolute frame numbers by construction.

That is a property of the comparison, not lost state. On hardware there is no
reference run to be out of step with; what matters is that a load lands on the
same scene with the game playing on, which it does. The board is the remaining
check, together with the things savestates always need proving on real
hardware: no freeze after a save or load, the DDR port shared with
`screen_rotate`, and `.ss` files only loading into DDR at core start.

---

## SS-14 — The sprite RAM was being built out of flip-flops (CLOSED, measured)

The first synthesis of the whole design — the new `SandScrp.sv` top level with
the MiSTer framework around it — came out at **41,709 ALMs of 41,910**, which
is the entire chip. Analysis & Synthesis put 32,914 of the 43,847 combinational
ALUTs and 47,022 of the 58,385 registers inside `emu`, and the per-entity table
pointed at one module:

| entity | ALUTs | registers | block memory bits |
|---|---|---|---|
| `pandora` | 15,438 | 32,942 | 983,040 |

32,768 registers is exactly one 4 KB sprite RAM, and the block-memory figure
held exactly one copy of that RAM. Quartus said so itself, four times:

    Info (276007): RAM logic "...|pandora:pandora_i|ram0" is uninferred
    due to asynchronous read logic  (pandora.sv:108)

The cause was the shape of the CPU read, not its meaning. The four byte lanes
were read *inside* the lane `case`:

```systemverilog
case (cpu_addr[1:0])
    2'd0: cpu_rdata <= ram0[cpu_dw];
    ...
```

which is a conditional array read. Quartus will not infer a registered RAM
output from one, so it built the whole array as logic instead. Reading all four
lanes every clock and applying the lane select *after* the register is the same
circuit to the rest of the design — `cpu_rdata` is still the byte at the
address presented one clock earlier — and infers.

The second reader made it worse. An M10K has two ports and one of them is the
write, so the snapshot's four-lane read and the CPU's read cannot share one
array. The mirror bank is now explicit: both banks take the same write on the
same clock, and each carries one read port. It costs four more M10K blocks,
32,768 bits of 5,662,720.

| | before | after |
|---|---|---|
| Logic utilisation (ALMs, A&S estimate) | 41,709 | **19,901** |
| Dedicated logic registers | 58,385 | **25,611** |
| Block memory bits | 2,485,207 | 2,517,975 |
| `pandora` ALUTs | 15,438 | **386** |
| `pandora` registers | 32,942 | **168** |

The 2026-09-19 probe of `sandscrp_core` alone did not show this: it reported
the four lanes as simple dual port and the whole core at 4,919 registers. The
probe and the real build differ in the framework around the core and in what
else reaches the sprite RAM, and no recording exists of which of those changed
the inference. The lesson is the one the measurement supports: **a core-only
`quartus_map` probe is not a substitute for synthesising the real top level**,
and the inference messages are worth reading on every build, not just the
resource totals.

---

## SS-15 — First bitstream on hardware: a perfectly timed black screen (CLOSED, measured)

The first `.rbf` ever put on a DE10-Nano loaded, ran, and drew nothing. The
native `screenshot` produced a **256x224 PNG of 57,344 pixels, every one of
them `(0,0,0)`**.

That the screenshot exists at all, and at exactly the right size, is the
useful half of the measurement. `video_calc` in `hps_io` derives those numbers
from the core's own DE and sync, so the 48 MHz clock, the PLL lock, the raster,
`video_retime`'s clock crossing, `crt_chain` and the mixer were all running and
producing this board's exact visible window on the first try. Only the pixels
were empty, which puts the fault behind the video path, not in it.

A control ruled out the method: the sibling NMK16 core screenshotted normally
on the same board minutes later.

### The cause

`sandscrp_rom_hw` **is** the ROM download. Its request register is cleared by
its reset:

```systemverilog
always @(posedge clk) begin
    if (reset) dl_req <= 1'b0;
    else if (dl_active & ioctl_wr & ~dl_req) begin ... dl_req <= 1'b1; end
```

so any reset asserted during the transfer leaves `dl_req` permanently clear and
**not one byte reaches the SDRAM**. It fails silently in the worst way:
`ioctl_wait = dl_active & (dl_req | a0_busy[0])` is then permanently low, so
the loader sees no backpressure, streams every byte at full speed and reports
success. Both CPUs run on whatever the previously loaded core left in the
SDRAM.

**It took two attempts to fix, and the first one is the interesting part.**
The obvious culprit was `ioctl_download`, which `SandScrp.sv` had folded into
the same `reset` it gave the core. Removing it was necessary and not
sufficient: the framework's own `RESET` is asserted for the load as well.
`sys/sysmem.sv` drives it from `reset_core_req`, which the HPS raises while it
sends the ROM. The second bitstream was just as black as the first.

The fix is a power-on-only reset for the loader, held until the PLL locks,
which is exactly what NMK16's `tdragon2_core` does and for exactly this reason
-- its comment records the same symptom, "a real hardware-mode test run showed
0 bytes ever landing". This project adapted that core's top level without
carrying across the one distinction that mattered.

### How it was found, and the diagnostic that lied

Video was the only working channel out of the design, so the counters were
painted onto the screen as 8x8 blocks, 32 bits a row, and read back out of the
PNG.

**The first overlay gave a false negative.** It displayed `sandscrp_rom_hw`'s
own `dl_raised` and `dl_granted`, which read zero -- and those counters are
cleared by that block's reset, the very signal under investigation. A perfectly
healthy download would have read zero too. A counter that is reset by the thing
you are trying to measure measures nothing.

The second overlay counted in the top level in registers with **no reset at
all**, which power up at zero and are never cleared. That produced the real
answer:

| | expected | before the fix | after |
|---|---|---|---|
| `ioctl_wr` pulses at index 0 | 0x2E0000 | **0x2E0000** | 0x2E0000 |
| highest `ioctl_addr` | 0x2DFFFF | **0x2DFFFF** | 0x2DFFFF |
| SDRAM writes completed | 0x2E0000 | — | **0x2E0000** |
| 68000 reset SP | 0070FFFE | **001FFFF0** | **0070FFFE** |
| 68000 reset PC | 0000099A | **000069E0** | **0000099A** |

All 3,014,656 bytes were arriving under the right index at the right addresses,
and none were being stored. The garbage reset vector is the previous core's ROM
still sitting in the SDRAM.

With the power-on reset the board boots to the title screen, cycles the attract
mode and the high-score table, and plays: coin, start and fire on the keyboard
all work, tilemaps and sprites and the HUD all correct.

### What this says about the M3 gates

Nothing in M3 is invalidated: the golden-byte audit, the frame gate and the
savestate round trip all exercised `sandscrp_rom_hw` correctly wired, and
`sim/rtl/sandscrp_hw/sandscrp_hw_top.sv` gets this right --

```systemverilog
rom_hw ( .clk(clk_sys), .reset(reset), ...
wire core_reset = reset | ioctl_download | ~sdram_ready | audit_en;
```

-- it keeps the two resets apart. What the episode says is that **"the hardware
path is verified in simulation" and "the hardware path is verified" are
different claims**, and the whole gap between them is the top level, the one
file no simulation here covers. A first board test should start by proving
bytes reached the SDRAM, not by looking at a frame.

### 2026-09-20 (later): the isolation capture, and a rejected fix

The per-source isolation this entry asked for was finally done on both sides.
MAME was patched locally so `SS_YM_ISO=fm|ssg` routes one half of the YM2203
at a time (env-gated, stock by default; `src/mame/kaneko/sandscrp.cpp`), and
the core's `dbg_fm_snd` / `dbg_psg_snd` taps give the same split. 30 s of
attract from each, aligned on the SSG envelope:

| | FM rms | SSG rms | SSG/FM |
|---|---:|---:|---:|
| MAME | 599 | 5505 | **9.18** |
| core | 1079 | 7125 | **6.61** |

So the SSG dominates the mix in *both* models — it was never "the FM is
missing" — and the core carries 28% more FM relative to SSG than MAME does.

**A fix was derived from that, implemented, measured, and reverted.** The
argument was that `jt12_top` mixes `fm_snd + {psg_snd,5'd0}`, FM at unity,
while MAME routes all four streams at 0.5, so the FM was twice as loud
relative to the SSG. That is wrong: `sandscrp_core.sv` already applies its own
`>>> 1` to the combined term, so the FM reaches the output at 32767/2 = 16383,
which is exactly MAME's routed FM. Halving it again was measured against a
30 s MAME capture with `tools/audio_compare.py`:

| | mean band corr | mean level diff |
|---|---:|---:|
| before | 0.979 | +1.2 dB |
| after (FM halved) | 0.979 | +1.5 dB |

Every band got 0.1-0.5 dB worse and the correlation did not move. Reverted,
with the reasoning left in the RTL beside the mix so it is not re-derived.

**What the whole-mix measurement actually says.** Against MAME's stock render
over the full 30 s, the core scores **0.979 mean band correlation** — the
`docs/PLAN.md` gate is 0.95 — with MAME uniformly about 1.8 dB louder across
all 24 bands (+1.9 at 60 Hz, +1.6 at 2.5 kHz, -1.1 at 15 kHz). That is a
near-flat level offset, not the spectral tilt this entry previously recorded.
The earlier 0.62 figure came from a shorter, differently-aligned capture and
should not be trusted over this one.

So the level question is closed at the mix level, and what remains open in
SS-10 is only the original symptom: the FM makes a sound during boot that MAME
does not. That is a state/reset question in jt03, not a gain question, and the
isolation capture confirms it is FM-only — the SSG is exactly zero for the
first 10 s in both models.

## SS-16 — High scores lost: the dump validation removed (CLOSED, measured)

The vendored `hiscore.v` carried NMK16's dump validation (NMK-33 there):
before a restore, each record's first and last byte in the `.nvm` were
compared with `hiscore.dat`'s start/end values, and the dump was discarded
on a mismatch. Neither of Sand Scorpion's end bytes is safe: the second
record is the top-score display (main RAM 0x0048, its last byte the score's
low digits), and in MAME the first record's last three bytes (0x2061-0x2063,
0x1b at boot) turn to 0x00 during play, so a table saved after enough play
was thrown away at the next load whatever the scores. NMK16 removed it
(NMK-37); so does this, from the same file (byte for byte but the note's
issue numbers). Only the RAM's start and end bytes are checked before the
restore, as upstream.

On the board (`Arcade-SandScrp_20261006.rbf`, all three sets, High Scores
On), with a coin, a start and 15 s of play the OSD's save is MAME's RAM at
the same point, byte for byte; a byte inside the largest record, and
separately its last byte, changed in the `.nvm` and the core reloaded: a
savestate holds the changed record and not the saved one, and the next save
keeps it. On the release (20260920) the last-byte change was reverted in
all three. Timing met at seed 1 (setup +0.385 ns, hold +0.234 ns).

## SS-17 — No sync on analog or direct video while the ROM loads (CLOSED, measured)

The core's raster is held at 0 by the game reset, which covers the ROM
download. `video_retime`'s read side, which makes the sync for analog and
direct video, only started at the first frame edge from that raster, so on a
fresh load there was no sync until the game ran: a CRT or a direct-video
converter lost the picture, the menu's loading screen with it. HDMI was
unaffected (the scaler makes its own timing). Arcade-GingaNin_MiSTer's GN-14
found it; the same fix here.

- `video_retime` (marked MODIFIED): the read side runs from configuration
  (its counters initialised, `running` set), so sync is there from the
  moment the FPGA is loaded. The first frame edge from the core's raster
  re-places it once, as it always did at the first frame: that is the one
  timing jump left, at the game's start.
- The picture is black while the raster is stopped: the read side counts
  its own frames since the last write-side frame start, and two without one
  blank it (the two-line buffer then holds stale lines). No reset wiring, so
  the file is the same in every core that has it.
- Not done: running the raster through the reset, which would remove the
  jump; it changes the frame phase the CPUs start in.

On the board, direct video on (the capture card cannot decode the 15 kHz
picture, but shows one only when there is a signal), the largest set loaded
through its `.mra`, seconds from the load to the first signal:

Sand Scorpion (3.0 MB): 6.0 s on the release (20261006), 4.0 s with this
change.

With direct video off, HDMI is as before (the game boots the same way); the
menu's "Sending" screen is now on black, where it showed whatever the
stopped core was putting out.

Timing met at the project's seed (setup +0.473 ns, hold +0.247 ns).

## SS-18 — DDR3 ROM loading (CLOSED, measured)

With `address="0x30000000"` on an `.mra`'s `<rom index="0">`, Main_MiSTer
assembles the ROM image straight into DDR3 and only frames it with a
download (ioctl_addr carrying the length, no writes); streamed, the image
crosses the HPS bridge at about 1 MB/s (one byte per HPS transfer).
`rtl/ddr_rom_load.sv` sits between hps_io and the core:

- a streamed download passes straight through (an `.mra` without `address=`
  still loads, checked on the board);
- a download on index 0 that ends with no write is a DDR3 load: the image
  is read back from DDR3 (one 64-bit read at a time, one word prefetched)
  and replayed to the core's loaders as the download it replaces, one write
  at a time, at least 8 clocks apart and never while the core holds
  ioctl_wait. The core sees one download from the first rise to the last
  replayed byte, so its reset and settling span the replay;
- hps_io's later downloads (the `<switches>`, the hiscore config, the
  `.nvm`) wait on ioctl_wait until the replay is done.

The reads take the savestate engine's place on the DDRAM port (that engine
is idle during a download) and give way to screen_rotate's writes. The
`.mra` generators write `address=`, and every `.mra` in `releases/` has it.
A unit test (both widths, unrelated clocks, a random DDR3 latency, busy and
rotation cycles, a random ioctl_wait) checks every byte and address, the
`<switches>` download started during a replay, and a streamed download after
it.

On the board, the largest set loaded through its `.mra`, how much earlier
the game runs than on the release (the two HDMI recordings aligned on the
game's own frames):

| Set | Image | Earlier |
|---|---|---|
| Sand Scorpion | 3.0 MB | 2.3 s |

The old `.mra` (no `address=`) loads the same as on the release, and the
high scores save and restore after a DDR3 load (the hiscore config and the
`.nvm` arrive after the replay). Timing met at seed 1 (setup +0.372 ns, hold
+0.250 ns).

## SS-19 — No re-lock after a load or a reset (CLOSED, measured)

SS-17 gave analog and direct video a sync from the moment the core is
loaded, but when the core's reset ended its raster started wherever that
moment fell, and `video_retime` re-placed its read side to it: the sync
jumped once, and a CRT or a direct-video converter had to lock again, after
every load and every reset.

- The top ends the reset on `video_retime`'s `rel_tog`, which flips once a
  frame where the read side wants the core's raster to begin (a quarter of a
  line after its frame start, less the lines from the reset to the core's
  frame start: `rel_lead`, 22: the raster leaves reset at line 240 of 262
  (MAME's phase)). The reset is held for at most a frame more (`reset`).
- After the raster has been stopped (two frames without a frame start, or
  the reset) the first frame start that comes within an eighth of a line
  before to three quarters of a line after the read side's own is taken as
  it is: no move of the read side, so no jump. The two-line buffer has room
  for that much (the write side up to a line ahead of the read, and less
  than any core's blanking behind it). Any other frame start places the read
  side as before.
- The phase tests are constant compares on registered counters (the frame
  position, and the position against the expected start), a clock ahead: the
  first version, with a wrap-around subtraction, missed timing at 96 MHz.
- The picture is black from the reset to the core's first frame start after
  it (that is its vertical blank), and from the clock the reset is seen (the
  two-frame stall test alone left a short reset showing stale lines).

A Verilator test (`video_retime` with a raster model held in reset and
released on rel_tog, a download-length reset and a half-frame one, raster
start latencies up to 900 clk_r, the geometries of GingaNin, NMK16,
SandScrp, NS2 and MS1) checks that the hsync interval never changes, the
read side is never re-placed, and every pixel shown is its line's and
column's.

On the board, direct video on, an OSD Reset 25 s into the game (the capture
card shows a signal only while there is one): on the release (v2026-10-06.2)
the card lost the picture after the reset; with this change the signal runs
through it (Sand Scorpion). HDMI is as before.

Timing met at seed 1 (setup +0.693 ns, hold +0.246 ns).
