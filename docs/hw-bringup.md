# Hardware bring-up — Arcade-SandScrp_MiSTer

Two kinds of content. **Milestone status** is a standing summary, rewritten in
place whenever something moves, so it is always current. Everything after it is
**dated sections, newest last**, and those are never rewritten. Nothing here is
a plan; each entry is something that was built and measured.

---

## Milestone status (current as of 2026-09-20)

Where `docs/PLAN.md` section 3's milestones stand against their own gates.
Everything here is a measurement; the method is in `docs/sim-harness.md` and
the evidence in `docs/known-issues.md`.

| | |
|---|---|
| **M0 Foundation** | done — repo scaffolded from NMK16 at `ef92781`, all seven inherited unit tests pass, three `.mra` generated from one table with an off-board load model, MAME oracle captures (attract, Flip Screen DIP, scripted gameplay) |
| **M1 Video against MAME state** | done — VIEW2, PANDORA and the compositor are identical to an independent Python model of MAME on **61 of 61** frames, 31 of them additionally pixel-exact against MAME itself |
| **M2 Full reference sim** | done — the whole board run from reset is **pixel-exact against MAME**, 43 of 44 frames matching once the two independent timelines are allowed to drift |
| **M3 Hardware-path sim** | done — golden-byte audit **3,801,088 bytes, 0 wrong, 0 timeouts**; frames pixel-exact against MAME through the SDRAM path; sprite pass 106,797 clocks of a frame's 804,864 with 0 late swaps; savestate round trip verified at the state level |
| **M4 Quartus and board** | **done bar two gates.** Builds clean (18,806 ALMs of 41,910, 342 of 553 M10K, timing closed first try), boots and plays on a DE10-Nano, and all three sets are swept on hardware. Took two black screens to get there — SS-15. Audio against MAME and a frame-level comparison with the reference sim are the two board gates still open |
| **M5 Feature parity and release** | **mostly verified, and published.** On the board: DIP switches, Flip screen (an exact 180-degree turn), CRT Adjust, Pause, High scores including the patch-the-`.nvm` proof, and savestate save all pass; savestate load works but not on every attempt. Orientation cannot be observed with the tools here, cheats are inconclusive, autofire untested. The core ships through the kuzecores downloader database with all three `.mra` correctly tagged |

### What M4 still owes its gates

The plan's M4 gates, and where each stands after a day on the board:

| gate | state |
|---|---|
| Timing met on every clock, worst path identified | **met** — and the worst path is the framework's `pll_hdmi`, exactly where the plan predicted |
| RAM inference: every array a real M10K, no duplicate copies | **met**, after the fix in SS-14 |
| Boots to attract on the first `.mra` | **met** — title, attract cycle and high-score table, after SS-15 |
| Coin, start and play on keyboard | **met** — three coins read CREDITS 3 on the title screen, and the ship moves and shoots |
| Native screenshots of static scenes byte-identical to the reference sim | not run |
| A demo frame with sprites pixel-identical to the reference sim (the byte-order check) | not run |
| Audio correlation vs MAME over 60 s | not run |
| Coin, start and play on a gamepad | not run — keyboard only so far |
| All three `.mra` swept | **met** — all three boot, run the attract and play, and each differs from the others on at least one frame |

M5's gates are now mostly met on the board — see the OSD feature section below
for the evidence and for the three that are not (Orientation, cheats,
autofire). The direct-video menu split is also untested: this board runs with
`direct_video=0`.

### What the board has to settle first

Two open questions cannot be answered anywhere else, and should lead the queue:

- **SS-1, the raster timing.** Nothing in MAME documents this board's raster.
  Every number in `video_timing_sandscrp.sv` is a parameter defaulted from the
  closest sibling Kaneko board, and `video_retime`/`crt_chain` in the top level
  inherit them. A PCB measurement settles it.
- **SS-6, the sprite flip.** This core deliberately diverges from MAME here, on
  measured evidence. The board is the tie-breaker.

## 2026-09-19 — Synthesis probe of the core (Quartus 17.0 Lite, 5CSEBA6U23I7)

Before writing any more RTL, a `quartus_map` probe of `sandscrp_core` alone
(no MiSTer framework, no SDRAM), to answer the one question that has sunk
this class of design repeatedly in the NMK16 project: **does every array
infer as block RAM, or did something become flip-flops?** An asynchronous
read of a large array costs thousands of ALMs and is invisible in simulation.

Run it with `HW_ROMS=1`. At `HW_ROMS=0` the `$readmemh` ROM arrays have no
content at synthesis time, Quartus constant-folds through them, and the
report is meaningless — the first attempt showed the sprite plane as 4 bits
wide and the line buffers missing entirely, both artifacts of that folding.

Result, `set_parameter -name HW_ROMS 1`:

| | |
|---|---|
| Logic utilisation (ALMs) | 5,229 of 41,910 (12.5 %) |
| Dedicated logic registers | 4,919 |
| Block memory bits | 1,829,062 of 5,662,720 (32 %) |
| DSP blocks | 3 |
| Errors | 0 |

Every array inferred as real M10K, none as registers:

| array | shape | mode |
|---|---|---|
| PANDORA sprite plane (2 x 256x224) | 114,688 x 8 | simple dual port |
| PANDORA table snapshot | 1,024 x 32 | simple dual port |
| PANDORA sprite RAM, 4 byte lanes | 1,024 x 8 each | simple dual port |
| VIEW2 VRAM + line scroll, 2 lanes x 2 layers | 2,048 x 8 each | true dual port |
| VIEW2 line buffers, one per layer | 512 x 13 | simple dual port |
| palette, 2 lanes | 2,048 x 8 | true dual port |
| work RAM, 2 lanes | 32,768 x 8 | single port |
| Z80 RAM | 8,192 x 8 | simple dual port |

The only uninferred RAM logic is four small lookup tables inside jt6295 and
jt03, which are too small to be worth an M10K.

The sprite plane alone is 90 M10K blocks, as expected — it is the single
biggest consumer and the reason to keep an eye on the total once the MiSTer
framework (hq2x, ascal, shadowmask) is added: NMK16 found that Quartus 17
silently stops inferring the framework's own RAMs at about 539 of 553 blocks
and builds them as flip-flops instead, with no message.

**Not yet measured:** fit, timing, the framework, and the SDRAM path. This
probe is `quartus_map` only.

## 2026-09-19 — Clock plan: 48 MHz, exact dividers

`clk_sys` is 48 MHz rather than the 40 MHz the NMK16 cores use, because every
clock on this board divides into it exactly:

| | 48 MHz / | gives |
|---|---|---|
| 68000 | 4 | 12 MHz (two phases, enPhi1 at count 3, enPhi2 at count 1) |
| Z80 | 12 | 4 MHz |
| YM2203 | 12 | 4 MHz (offset half a period from the Z80's enable) |
| OKIM6295 | 24 | 2 MHz, pin 7 high |
| pixel | 8 | 6 MHz |

The NMK16 cores need 8 and 14 MHz from 40 MHz and therefore run per-mille
phase accumulators; nothing on this board does, and an exact divider cannot
drift. The SDRAM controller keeps its own 96 MHz PLL output either way, and
96/6 = 16 clocks per pixel leaves CRT Adjust's Cabinet mode (which needs at
least 11) comfortable.

## 2026-09-20 — The MiSTer top level

`SandScrp.sv` now exists: `module emu` with the framework's port include, the
CONF_STR, `hps_io`, the PLLs, the SDRAM controller, the core, the video chain
and the OSD features. With it come `files_sandscrp.qip`, `SandScrp.qsf`,
`SandScrp.qpf`, `SandScrp.sdc` and `SandScrp.srf`. It is adapted from
NMK16_Macross2.sv, the closest sibling (68000 + Z80 + YM2203 + OKIM6295), and
inherits its OSD layout, keyboard map, autofire, pause, high-score, cheat,
savestate and CRT Adjust wiring unchanged.

What is different here, and why:

- **One game, no game select.** The three sets share a machine configuration
  and byte-identical graphics and sound data, so the `.mra` picks the set by
  which program ROM it loads and no status bit is spent on it.
- **The DIP switches never reach the 68000.** On this board the Z80 reads both
  banks through the YM2203's ports, so the `.mra`'s `<switches>` bytes go to
  the core's `dsw1_i`/`dsw2_i` and from there to jt03's IOA/IOB. Service Mode
  is DSW2 bit 7 (MAME's `PORT_SERVICE_DIPLOC "SW2:8"`), not a DSW1 bit, so
  that is what F2 toggles.
- **ROT90, not ROT270.** The image has to be turned clockwise to stand
  upright, which is `screen_rotate`'s `rotate_ccw = 0`. The two Vert entries
  are therefore the other way round from the NMK16 cores: "Vert 90" is the
  MAME-correct one and is offered first.
- **Mono audio.** One channel to both outputs.
- **The raster is 384 x 262 at 6 MHz**, not 512 x 278 at 8. `video_retime`
  gained a `VTOTAL_P` parameter for it (the NMK16 boards' 278 was a
  localparam); the active window, rows 16..239, was already right for both.
  96 MHz / 6 MHz = 16 video clocks per pixel and 6,144 per line. HSync is
  placed nominally inside the blanking (front porch 32 px, sync 28, back porch
  68) and CRT Adjust trims it. All of this rests on SS-1, which is still open.

Analysis & Synthesis is clean: **0 errors**. Getting there found one real bug,
worth a full entry of its own — see `docs/known-issues.md` SS-14. In short, the
PANDORA sprite RAM was being built out of 32,768 flip-flops because the CPU
read sat inside the lane `case`, and the first whole-design synthesis came out
at 41,709 ALMs of 41,910. Reading all four lanes unconditionally and selecting
after the register, plus an explicit mirror bank for the snapshot's read port,
brought it to 19,901.

The only uninferred RAM logic left is in third-party code that the NMK16 cores
carry too (four small jt6295/jt03 lookup tables, the five hiscore config
tables) plus `oki_rom_cache`'s 16-line fully associative cache, which is 864
bits of tag and data and belongs in registers.

### The build

Full flow, Quartus 17.0 Lite, 5CSEBA6U23I7, `SEED 1`: map, fit, assemble and
timing, **0 errors at every stage, and timing closed on the first attempt** —
no seed retries, which the NMK16 project needed on two of its four cores.

| | |
|---|---|
| Logic utilisation (ALMs) | 18,806 of 41,910 (45 %) |
| Dedicated logic registers | 26,338 |
| M10K blocks | 342 of 553 (62 %) |
| Block memory bits | 2,517,975 of 5,662,720 (44 %) |
| DSP blocks | 45 of 112 (40 %) |
| PLLs | 3 of 6 |
| I/O pins | 145 of 314 |
| `.rbf` | 3,580,456 bytes |

Worst-case slack, slow 1100 mV 85 C model:

| clock | setup | hold |
|---|---|---|
| `pll_hdmi` (the framework's) | **+0.392 ns** | +0.247 ns |
| `clk_ram` / `CLK_VIDEO`, 96 MHz | +1.747 ns | +0.246 ns |
| `clk_sys`, 48 MHz | +4.055 ns | +0.259 ns |

The critical path is the framework's HDMI clock, not this core's logic, which
is where a comfortable arcade core's critical path belongs. Recovery, removal
and minimum pulse width are all positive too.

**The video PLL turned out to be redundant.** `rtl/pll_video96.v` was
instantiated as a third clock source, and the fitter merged its output into
`rtl/pll.v`'s second output — same 96 MHz, same 50 MHz reference — so it
bought nothing and never appeared in the timing summary as a clock of its own.
`CLK_VIDEO` is now `clk_ram` directly and the instance is gone. The two builds
either side of that change are the same size (18,789 and 18,806 ALMs, 3 PLLs
both times), which is the measurement that says the merge was already
happening. The NMK16 cores do run a second video PLL, but at 112 MHz, which
cannot merge.

### Regression

The Pandora change alters the shape of a memory read, so the whole-board
simulation was re-run and every dumped frame compared against the same frame
from before the change. **All 45 frames, 180 to 620 in steps of
10, are byte-identical.** The read returns the same byte at the same clock;
only its synthesis changed.

One trap on the way, worth writing down because it produced a wrong status
report before it was caught. `TB_CYCLES` counts `clk_sys` cycles and a frame is
804,864 of them, so the testbench's 400,000,000 default ends at frame 496: the
first run dumped 32 of the 45 and stopped. The shell loop waiting on it never
noticed, because `pgrep -f Vsandscrp_ref_top` matches the waiting loop's OWN
command line and therefore always finds a process. Wait on the PID, not on a
pattern the waiter itself contains.

## 2026-09-20 — First run on a DE10-Nano: it works

Deployed to a board at the end of the same day the top level was written.
`.rbf` to `/media/fat/_Arcade/cores/`, the three `.mra` to `_Arcade/` and its
`_alternatives/`, the ROM zips to `games/mame/`, md5 checked at both ends, and
`load_core` through `/dev/MiSTer_cmd`.

**It took three bitstreams.** The first two drew a perfectly timed black
screen; the cause and the diagnostic that found it are SS-15, and it is worth
reading, because the first diagnostic gave a false negative by measuring a
counter that the signal under investigation resets. The short version is that
the ROM loader must not be held in reset while it loads, and two separate
signals were doing it: `ioctl_download`, and the framework's own `RESET`, which
the HPS raises for the duration of the transfer. The loader now takes a
power-on-only reset, as NMK16's core does for the same reason.

With that, the third bitstream boots.

| measurement | expected | board |
|---|---|---|
| loader writes at ROM index | 0x2E0000 | **0x2E0000** |
| SDRAM writes completed | 0x2E0000 | **0x2E0000** |
| highest `ioctl_addr` | 0x2DFFFF | **0x2DFFFF** |
| 68000 reset stack pointer | 0070FFFE | **0070FFFE** |
| 68000 reset program counter | 0000099A | **0000099A** |

Every one of the 3,014,656 ROM bytes reaches the SDRAM and the 68000 fetches
the real reset vector.

**What has been seen on the board.** The title screen with the scorpion
artwork, the FACE logo and the 1992 copyright; the attract cycle; the "BEST TEN
FIGHTERS" high-score table with its red-to-yellow gradient; and gameplay after
coin, coin, start on the keyboard, with the player ship, enemies, bullets, both
tilemap layers, sprites and the HUD all drawing correctly. Fire and the
direction keys move and shoot. The picture is sideways at the default
Orientation, which is correct for a ROT90 game with the framebuffer rotation
off.

The timing numbers moved very little across the three builds: worst setup slack
+0.392, +0.692 and +0.498 ns, always on the framework's HDMI clock.

### All three sets swept on the board

`tools/mister_sweep_sandscrp.sh` runs on the MiSTer and does the same thing to
each `.mra` in turn: load, settle 45 s, capture the attract, coin-coin-start,
settle, capture, then fire and a direction, capture again. One line per set to
a log, so a dropped ssh cannot lose the run.

    sandscrp  shots=3 mister=1
    sandscrpa shots=3 mister=1
    sandscrpb shots=3 mister=1
    SWEEP COMPLETE

**All three boot, run the attract and play.** Every capture is 256x224 with
38,000-50,000 non-black pixels and 52-92 colours; none is blank, none is
stuck.

The frames also show the three are genuinely running their own programs rather
than falling back to the parent, which matters because two of the `.mra` name
their zip as `<clone>|<parent>`:

| | attract | gameplay | after firing |
|---|---|---|---|
| sandscrp vs sandscrpa | **1,535 px (2.7 %)** | 0 | 0 |
| sandscrp vs sandscrpb | 0 | **31,157 px (54.3 %)** | **5,553 px (9.7 %)** |
| sandscrpa vs sandscrpb | **1,535 px** | **31,157 px** | **5,553 px** |

Each set differs from each other set somewhere. That is the point of the table:
a set that had silently loaded the parent's program would match it on every
frame, and none of them does. It is corroborated by the `.mra` themselves --
`sandscrpa` loads `1.ic4`/`2.ic5` and `sandscrpb` loads `11.ic4`/`12.ic5`, and
those names exist only in their own zips -- and by the ROMs, where the earlier
set's program differs from the parent's in a third to a half of its bytes.

Two caveats worth stating rather than glossing. The identical gameplay frames
between `sandscrp` and `sandscrpa` are expected, not suspicious: the input is
scripted at fixed wall-clock offsets and both revisions take the same code path
there. And the attract difference is spread across the animated area of the
screen, so on its own it shows a different animation phase; it is the
combination with the part names and the ROM contents that settles which program
each set is running.

### What that first run did not cover

Booting and playing is the first gate, not the last. The OSD feature set was
tested later the same day and has its own section below; audio against MAME and
a frame-level comparison against the reference simulation are still not done on
hardware.

## 2026-09-20 — The OSD feature set on the board

### How, and why not through the menus

The MiSTer's native `screenshot` captures the core's video **without the OSD
overlay** — verified by opening the menu and screenshotting it, which returns
the game and no menu. So the OSD cannot be read back, and blind key-navigation
of it would be unverifiable: pressing keys and hoping is not a measurement.

What can be driven exactly is the settings the OSD writes:

| | |
|---|---|
| `/media/fat/config/<setname>.CFG` | the 128-bit OSD status word, 16 bytes little-endian |
| `/media/fat/config/dips/<mra name>.dip` | 8 bytes, the `<switches>` block |

Both are read when the `.mra` is loaded. The format was confirmed before being
trusted, by decoding the sibling core's own saved file: `tdragon2.CFG` has bits
8, 39 and 101 set, which is Orientation = 1, High Scores on and CRT Adjust on —
exactly the state this log already records for that board.

So each option is set in the file, the core is loaded, and the result is judged
by what the picture does. `tools/board_feature_test.py` is that harness.

Two things made the results trustworthy that are worth keeping:

- **A static screen.** The attract animates and never phase-locks between runs,
  so comparing two runs frame to frame is meaningless. Service mode's colour-bar
  screen is pixel-identical 5 s apart, which turns "about the same" into "0
  differing pixels".
- **A long enough key hold.** `mister_keys.py`'s 0.15 s default is too short for
  a savestate. The first attempts looked exactly like "load is broken"; at 0.6 s
  they work. The chord form (`lalt+f1`) had to be added too — Alt+F1 saves and
  F1 alone loads, so pressing them in sequence is a different command.

### What passed

| feature | result |
|---|---|
| **DIP switches** | **Pass.** Service Mode (SW2:8) set through the `.dip` file puts the game in its colour-bar test screen. That exercises the whole path: `.dip` → ioctl index 254 → `dsw2_i` → the YM2203's port B → the Z80 → the 68000. |
| **Flip screen** | **Pass, exactly.** Against the static screen, flipped vs unflipped is **0 differing pixels of 57,344** as a 180-degree rotation, where every other transform (as-is, mirror H, mirror V) differs by 53,760. |
| **CRT Adjust** | **Pass.** V-Size in Cabinet mode changes the real output geometry: +4 gives 236 active lines and -4 gives 221, against 224 with it off. |
| **Pause** | **Pass.** With it on the machine is frozen and consecutive frames are identical; with it off the attract moves by about 55,000 pixels a frame. |
| **High scores** | **Pass, end to end.** Opening the OSD writes `Sand Scorpion.nvm`, 84 bytes, exactly the size the `.mra` declares. Patching every rank in that file to the rank-10 value and reloading makes the in-game BEST TEN FIGHTERS table show that value for all ten ranks — the restore path, proven from the outside. |
| **Savestates** | **Save passes.** `Sand Scorpion_1.ss` is 115,464 bytes, which is this core's declared image of 115,456 plus an 8-byte header. **Load works but not every time**: proven twice (after a core restart, attract → a live game; in-session on slot 2, game over → a live game restored), and once, in-session on slot 1, it did not restore. Not diagnosed. |
| **Coin, start, fire, movement** | **Pass.** Three coins put CREDITS 3 on the title screen. |

### What is still not verified, and why

- **Orientation** cannot be seen this way at all. It is `screen_rotate`'s
  framebuffer, and the native capture is the core's video *before* that, so all
  three settings return 256x224. It needs a capture on the HDMI output. Nothing
  here says it is broken; nothing here says it works.
- **Cheats** are inconclusive. Infinite Credits and Infinite Bombs were both
  attempted, and the comparisons failed on framing rather than on the feature:
  the credit count only shows on the title screen, the bomb count only during
  play, and the scripted runs did not reliably land on the same screen. It needs
  a better observable, not more attempts of the same kind.
- **Autofire** is untested. Its menu is hidden unless the `.mra`'s third
  `<switches>` byte sets bit 6, and rapid fire is not something a still frame
  settles.

### One bug found, and fixed

**F2 was claimed twice.** This core's keyboard block uses F2 for the Service
Mode toggle, MAME's own binding for it, and `savestate_ui` used the same
scancode for savestate slot 2. Both acted on the press.

Slot 2 moved to **F5** (scancode 0x03), so the slot keys are now **F1, F5, F3,
F4** for slots 1-4, a plain press to load and Alt+press to save. Moving the
savestate side rather than the Service Mode side keeps MAME's binding, at the
cost of a gap in the F1-F4 convention other MiSTer cores follow; moving all
four clear of F2 would have broken that convention for the three that never
collided.

Verified on the board with the rebuilt bitstream:

| | |
|---|---|
| Alt+F2, the old slot-2 key | no savestate file appears |
| Alt+F5 | writes `Sand Scorpion_2.ss`, 115,464 bytes |
| F5 from a cold attract screen | restores the saved game, score 1800 on the HUD |

Separately, and not fixed because it is not a bug in the core: toggling Service
Mode mid-game does nothing, since the game reads that switch at boot. The
keyboard toggle only bites across a reset.

**The same collision existed in `Arcade-NMK16_MiSTer`**, which shares this
`savestate_ui.sv` and also binds F2 to Service Mode. Fixed there too (NMK-34),
all four of its cores rebuilt and the change verified on the board with
NMK16_Macross2 running Thunder Dragon 2: Alt+F2 writes nothing, Alt+F5 writes
slot 2.

## 2026-09-20 — Audio against MAME, performance, and cycle accuracy

Three measurements against the same reference MAME build (0.289) that every
other claim here uses.

### Cycle accuracy: the clocks are exact, the frame is 0.6 % long

Every chip clock divides exactly out of the 48 MHz `clk_sys` and lands on
MAME's own number:

| | core | MAME | delta |
|---|---|---|---|
| 68000 | 12.0000 MHz | 12.0000 MHz | 0.000 % |
| Z80, YM2203 | 4.0000 MHz | 4.0000 MHz | 0.000 % |
| OKIM6295 | 2.0000 MHz | 2.0000 MHz | 0.000 % |
| pixel | 6.0000 MHz | 6.0000 MHz | 0.000 % |
| line rate | 15,625 Hz | 15,625 Hz | 0.000 % |
| **frame rate** | **59.6374 Hz** | **60.0000 Hz** | **-0.604 %** |

The frame is the only divergence, and it is SS-1 rather than a bug: MAME's
figure is `set_refresh_hz(60)` written by hand in a driver that says its vblank
time is "not accurate", while the core's comes from the sibling Kaneko board's
confirmed 384 x 262 raster. The sim's measured frame period, 804,864 `clk_sys`
cycles = 201,216 68000 cycles, matches the raster parameters exactly.

**How fast the 68000 actually executes**, which is the part a frame rate does
not tell you. `sim/oracle/traces/sandscrp/boot_68k_io.trace` records every
MAME bus access outside the program ROM for 600 frames from reset; the core's
own counters were read at the same frame:

| reset -> frame ~600 | core | MAME |
|---|---|---|
| 68000 cycles | 120,729,601 | 120,000,000 |
| non-ROM bus accesses | 4,879,020 | 4,839,013 |
| accesses per cycle | 0.040413 | 0.040325 |

**+0.217 %**, about one part in 460 over 120 million cycles. Per frame the core
does 0.827 % more work, of which 0.608 % is just the longer frame; the residue
is the execution-rate difference. It is a rate comparison over a long span, not
an instruction-for-instruction match — the two timelines are not identical
(the watchdog reboot lands at core frame 180 against MAME's 187) and the two
sides count accesses with different filters.

### Performance: the sprite engine uses a tenth of its frame

868 frames of real gameplay through the hardware path (`sandscrp_hw`, real
SDRAM controller and model), coin and start and fire scripted in:

| | |
|---|---|
| PANDORA pass, worst observed | 84,415 cycles, **10.5 %** of a frame |
| PANDORA pass, typical | 80,767 cycles, 10.0 % |
| **Late swaps** | **0** — the sprite engine never missed a deadline |
| OKI fetch stalls, whole run | 3,206 cycles, **0.00046 %** of run time |
| ROM byte reads | 34,222 per frame, one every 23.5 cycles |

The sprite pass is the only hard per-frame deadline in this design — it has to
snapshot 512 entries, clear a plane and draw it between two vblanks — and it
finishes with 89.5 % of the frame still unused.

One counter needs reading carefully: `okistall` already stands at 27,142,655 at
frame 0 and moves by 3,206 across the entire run. That bulk accrues during the
ROM download, while the CPUs are held in reset and the OKI cache is empty; it
is not a runtime cost. Taking the raw cumulative figure would report a 3.9 %
stall rate where the true one is four ten-thousandths of a percent.

### Audio: right tune, right time, 5 dB quiet — does not meet the gate

MAME renders silence for the first **15.58 s** and then the attract music, so a
30 s capture of the core gives a 13 s window where both are playing. Over it:

| | |
|---|---|
| Alignment | core lags MAME by **50 ms** |
| Mean band correlation (24 bands) | **0.62** — the plan's gate is 0.95 |
| Envelope correlation | 0.56 to 0.70 |
| Level | core **4.97 dB** quieter (RMS 3,872 against 6,859) |

What is right: the music starts on the same second, and all 24 bands correlate
positively, so the sound CPU reaches the same tune at the same point in the
program. What is wrong: the core is uniformly quiet and its envelope only
loosely tracks MAME's.

Two explanations were tested and **ruled out**, rather than assumed:

- **Not aliasing from the testbench's sampling.** The dump is a naive 48 kHz
  decimation with no anti-alias filter, which is a fair suspicion. Low-passing
  both sides at 24, 12, 8, 4 and 2 kHz leaves the envelope correlation at 0.56
  throughout.
- **Not MAME's own effects.** MAME 0.289 puts Filters, Compressor, Reverb and
  Equalizer in the speaker's default chain, which would flatter the reference.
  Re-rendering with the chain removed from `cfg/sandscrp.cfg` produced a
  **bit-identical** file, so it is not touching `-wavwrite`.

SS-10 is reproduced exactly: the core emits a burst at reset (RMS 212) where
MAME is silent.

**The honest limit of this measurement.** It compares mixes, which SS-10
explicitly warns against. It is close to an FM-only comparison in practice --
the OKI takes one write in 300 frames of attract -- but not by construction.
Real isolation needs a per-source tap on the core side, and MAME exposes no
per-device gain through either its Lua interface (`set_output_gain` is not
bound) or its config file (`<mixer>` carries the speaker map, not device
volumes). That is the next step on SS-10, and it is a harness change, not a
core change.

## 2026-09-20 — Distribution: an XML defect, and the core in a downloader database

The core is now published through
[kuzecores](https://github.com/kuzearcade/kuzecores), a custom database for the
MiSTer *downloader*, so it arrives through `update_all` like any other core and
appears in release trackers that read `db.json.zip`. All three `.mra` are in it,
with the bitstream listed externally and pinned to a commit in this repository.

Adding it turned up a defect in this project's own `.mra`, and in ten of the
NMK16 ones, worth recording because it is invisible from the board.

**All three of this core's `.mra` were not well-formed XML.** Each had a `--`
inside the header comment, which the XML spec forbids ("Sand Scorpion -- FACE
1992", and again in the `<switches>` note). MiSTer's own `.mra` reader is
lenient, so the games always ran correctly — but the database builder reads each
file with a strict parser to learn which core it needs, and on a parse error it
silently drops **every tag taken from the file's contents**: the per-core tag,
the set-name term, and the `alternatives` marker. Ten NMK16 files had already
shipped that way, tagged only by their path, so filtering the database by core
did not show them.

Fixed in the generators (`x()` for element text and attribute values, `xc()` for
comment bodies) as well as in the files, so it cannot recur. The published
database now carries 100 `.mra` with **zero missing a per-core tag**, and Sand
Scorpion's own `arcadesandscrp` tag on all three sets.

Two notes for whoever maintains this next:

- **Do not fix a `.mra` by re-running its generator.** Each writes every set
  flat into `releases/` and emits only its own blocks, so a plain regeneration
  scatters the `_alternatives/` layout and strips the high-score and cheat
  blocks that `gen_hiscore_mra.py` and `gen_cheats_mra.py` append afterwards.
  Tried it, reverted it.
- **The published `db.json.zip` is aggressively cached.** After a rebuild, the
  branch URL served the previous file even with cache-busting headers; only the
  commit-hash URL gave the current one. The size is the quick tell.

## 2026-09-20 — The tracked bitstream

`releases/Arcade-SandScrp_20260920.rbf` is the current build, md5
`c954c05ee36d9be263e94c37ee8c3873`, the same bytes as `output_files_sandscrp/SandScrp.rbf`.
The date in the name is the one `build_id.v` carries and the OSD shows, so a
bitstream running on a board can be traced back to a build. Copy the current
`.rbf` there after every build, as the NMK16 project does.

It is tracked so that someone with a DE10-Nano can run this core without
installing Quartus first. It is the build that boots, plays and passes the
feature tests above — but it is still not a release: audio has never been
compared against MAME on hardware, and three OSD options remain unverified.

**A trap worth repeating from the NMK16 rebuild:** `build_id.v` is written by
the `PRE_FLOW_SCRIPT_FILE`, which does **not** run when `quartus_map` is
invoked directly. A bitstream built that way carries whatever date the file
already held, so it can be named for today and report a week-old version in the
OSD. Run `quartus_sh -t sys/build_id.tcl <project> <revision>` first, or build
through a full flow.
