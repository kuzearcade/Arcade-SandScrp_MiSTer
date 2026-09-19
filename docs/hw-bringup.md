# Hardware bring-up — Arcade-SandScrp_MiSTer

Dated sections, newest last. Nothing here is a plan; each entry is something
that was built and measured.

---

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
