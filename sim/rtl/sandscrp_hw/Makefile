# Hardware-path simulation: real SDRAM controller + model, real ioctl stream.
#   make roms && make run
SET ?= sandscrp
RTL := ../../../rtl
OBJ := obj_dir
FX := $(RTL)/third_party/fx68k
WDOG ?= 144000000
SRC := sandscrp_hw_top.sv $(RTL)/sandscrp/sandscrp_core.sv $(RTL)/sandscrp/sandscrp_rom_hw.sv \
       $(RTL)/kaneko/video_sandscrp.sv $(RTL)/kaneko/view2.sv $(RTL)/kaneko/pandora.sv \
       $(RTL)/kaneko/kaneko_hit.sv $(RTL)/kaneko/video_timing_sandscrp.sv \
       $(RTL)/sdram.sv $(RTL)/sdram_req.sv $(RTL)/sdram_arb.sv \
       $(RTL)/rom_cache1.sv $(RTL)/rom_cache1_byte.sv $(RTL)/rom_cache_n.sv $(RTL)/rom_cache_n_byte.sv \
       $(RTL)/oki_rom_cache.sv ../../models/sdram_model.sv \
       $(FX)/fx68k.sv $(FX)/fx68kAlu.sv $(FX)/uaddrPla.sv \
       $(RTL)/third_party_gen/t80/T80s.v $(RTL)/third_party/jt12/hdl/jt03.v $(RTL)/third_party/jt6295/hdl/jt6295.v

.PHONY: all roms run clean
all: $(OBJ)/Vsandscrp_hw_top

roms:
	python3 ../../../tools/gen_sandscrp_mra.py --ioctl $(SET)
	cp ../sandscrp/roms/$(SET)_ioctl.bin roms/ 2>/dev/null || true

$(OBJ)/Vsandscrp_hw_top: $(SRC) tb_sandscrp_hw.cpp Makefile
	verilator --cc --exe --build -Wall -Wno-fatal -Wno-DECLFILENAME -Wno-UNUSED -Wno-WIDTH \
		-Wno-PINCONNECTEMPTY -Wno-EOFNEWLINE -Wno-TIMESCALEMOD -Wno-VARHIDDEN -Wno-CASEINCOMPLETE \
		-Wno-GENUNNAMED -Wno-BLKANDNBLK -Wno-SYNCASYNCNET -Wno-UNOPTFLAT -Wno-MULTIDRIVEN \
		-Wno-BLKSEQ -Wno-PINMISSING -Wno-CASEX -Wno-WIDTHCONCAT \
		--top-module sandscrp_hw_top --Mdir $(OBJ) -O2 +define+SIMULATION \
		-y $(RTL)/third_party/jt12/hdl -y $(RTL)/third_party/jt12/jt49/hdl -y $(RTL)/third_party/jt6295/hdl \
		-GWDOG_CYCLES=$(WDOG) \
		$(SRC) tb_sandscrp_hw.cpp -o Vsandscrp_hw_top
	cp $(FX)/microrom.mem $(FX)/nanorom.mem .

run: $(OBJ)/Vsandscrp_hw_top
	./$(OBJ)/Vsandscrp_hw_top

clean:
	rm -rf $(OBJ) *.ppm *.mem
