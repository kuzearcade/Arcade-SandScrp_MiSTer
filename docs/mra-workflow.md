# `.mra` workflow

## One table, three outputs

`tools/gen_sandscrp_mra.py` holds the only copy of this board's ROM layout —
part names, CRCs, region bases and sizes — and writes all three things that
have to agree about it:

    python3 tools/gen_sandscrp_mra.py            # releases/*.mra
    python3 tools/gen_sandscrp_mra.py --ioctl    # the hardware-sim byte stream
    python3 tools/gen_sandscrp_mra.py --simroms  # the reference-sim $readmemh images
    python3 tools/gen_sandscrp_mra.py --check    # the off-board load model

Then the shared generators, in this order:

    python3 tools/gen_hiscore_mra.py mame/plugins/hiscore/hiscore.dat
    python3 tools/gen_cheats_mra.py  ~/Downloads/cheat0279/cheat
    python3 tools/gen_autofire_mra.py

A region base that exists in two places will eventually differ in two places.
NMK16 shipped a core whose second OKI chip played tile graphics for a week
because one base constant lost a bit; the fix was not a better constant, it
was having one.

## `--check`: the load model

`--check` replays the `.mra` loader's own semantics — `<part>` concatenation
and `<interleave output="16">` with its `map` attributes — on the real zip
members, and asserts:

- every region lands on the base `rtl/sandscrp/sandscrp_rom_hw.sv` expects,
  and the whole stream is exactly 0x2E0000 bytes with no gaps;
- the 68000 words the core will rebuild from stream byte parity equal MAME's
  own big-endian program words, spot-checked at both ends of the region;
- all three sets stream **byte-identical** graphics and sound data, which is
  what lets one RTL path serve them (`sandscrpb`'s single mask ROMs really are
  the parent's `ROM_LOAD16_BYTE` pair interleaved — verified, not assumed);
- `tools/mk_ioctl_stream.py`, which builds the same stream from an independent
  code path, produces the same bytes.

Run it after any change to the table. It takes a second and it is the only
thing standing between a byte-order mistake and a board that boots to garbage.

## Byte order, decided once

| region | MAME | streamed as | consumer |
|---|---|---|---|
| maincpu | `ROM_LOAD16_BYTE` pair | odd-offset file on EVEN stream bytes (`map="01"` first) | 68000 words rebuilt by byte parity |
| audiocpu | plain | as-is | byte |
| sprites | plain (or one mask ROM) | as-is | byte |
| view2 | `ROM_LOAD16_BYTE` pair | MAME memory order, even-offset file first | byte |
| oki | plain | as-is | byte |

The two pairs are streamed in **opposite** orders on purpose. The 68000 region
follows the NMK16 convention so the word-rebuilding path is reused unchanged;
the VIEW2 region is consumed byte-wise by the tile decoder, which addresses
MAME's own region layout, so streaming it in memory order means no `^1` in the
RTL — and makes `sandscrpb`'s single mask ROM, already in that order, take the
same path with no special case.

## Traps this project has already stepped around

- `<dip bits="a,b">` is a start,end **range**, not a bit list.
- The `<buttons>` **count and order** are the gamepad's positional map and must
  equal the core's CONF_STR `J1` list. The names are free; the count is not.
- `?` cannot appear in a `.mra` file name — exFAT silently drops the copy — so
  the Chinese set ships as "Kuai Da Shizi Huangdi (China, Revised Hardware)".
- A clone zip omits files identical to the parent: name `zip="clone|parent"`.
- `<rotation>` is parsed as **text** by Main_MiSTer (`vertical`/`horizontal`,
  `cw`/`ccw`). This ROT90 game ships `vertical (cw)`, matching the official
  Galaga `.mra`; a number would be read as horizontal.
- A saved `config/dips/<mra name>.dip` overrides the whole `<switches>` value,
  third byte included — so an autofire copy shows nothing for a game whose
  DIPs were ever changed until that file is deleted or settings are reset.
- `.nvm` is keyed by the `.mra` **description**, `.dip` by the mra name, and
  `.CFG` by the setname: three different keys for three different files.
