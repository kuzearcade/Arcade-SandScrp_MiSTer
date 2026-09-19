# Reference simulation of the whole board (HW_ROMS=0).
#   make roms          # build the $readmemh images from mame_roms/
#   make run           # boot and report
#   TB_DUMP_FROM=560 TB_DUMP_TO=600 make run
SET ?= sandscrp
RTL := ../../../rtl
R := roms/$(SET)
OBJ := obj_dir
FX := $(RTL)/third_party/fx68k
SRC := $(RTL)/sandscrp/sandscrp_core.sv $(RTL)/kaneko/video_sandscrp.sv $(RTL)/kaneko/view2.sv \
       $(RTL)/kaneko/pandora.sv $(RTL)/kaneko/kaneko_hit.sv $(RTL)/kaneko/video_timing_sandscrp.sv \
       $(FX)/fx68k.sv $(FX)/fx68kAlu.sv $(FX)/uaddrPla.sv \
       $(RTL)/third_party_gen/t80/T80s.v $(RTL)/third_party/jt12/hdl/jt03.v $(RTL)/third_party/jt6295/hdl/jt6295.v
# 0.1 s instead of the board's 3 s: the game hangs on a cold boot until the
# watchdog reboots it (docs/known-issues.md SS-7) and the wait is pure sim time.
WDOG ?= 144000000

.PHONY: all roms run clean
all: $(OBJ)/Vsandscrp_core

roms:
	python3 ../../../tools/gen_sandscrp_mra.py --simroms $(SET)

# Makefile is a dependency on purpose: WDOG and the ROM file names are
# substituted into the verilator command line, so an edit here MUST rebuild.
# (It did not, and a run spent 20 minutes with the wrong watchdog.)
$(OBJ)/Vsandscrp_core: $(SRC) tb_sandscrp.cpp Makefile
	verilator --cc --exe --build -Wall -Wno-fatal -Wno-DECLFILENAME -Wno-UNUSED -Wno-WIDTH \
		-Wno-PINCONNECTEMPTY -Wno-EOFNEWLINE -Wno-TIMESCALEMOD -Wno-VARHIDDEN -Wno-CASEINCOMPLETE \
		-Wno-GENUNNAMED -Wno-BLKANDNBLK -Wno-SYNCASYNCNET -Wno-UNOPTFLAT -Wno-MULTIDRIVEN \
		--top-module sandscrp_core --Mdir $(OBJ) -O2 \
		-y $(RTL)/third_party/jt12/hdl -y $(RTL)/third_party/jt12/jt49/hdl -y $(RTL)/third_party/jt6295/hdl \
		-GROM_FILE=\"$(R)_maincpu.hex\" -GZ80_FILE=\"$(R)_audiocpu.hex\" \
		-GTILES_FILE=\"$(R)_view2.hex\" -GSPRITES_FILE=\"$(R)_sprites.hex\" -GOKI_FILE=\"$(R)_oki.hex\" \
		-GWDOG_CYCLES=$(WDOG) \
		$(SRC) tb_sandscrp.cpp -o Vsandscrp_core
	cp $(FX)/microrom.mem $(FX)/nanorom.mem .

run: $(OBJ)/Vsandscrp_core
	./$(OBJ)/Vsandscrp_core

clean:
	rm -rf $(OBJ) *.ppm *.mem
