# SS-24: does a jt6295 reading its sample ROM through oki_rom_cache + SDRAM
# produce the same samples as one reading a plain array? Two builds of
# okirom_tb_top.sv, differing only in the cache-fed chip's rom_ok:
#
#   make gated   rom_ok = the cache's ready (sandscrp_core.sv since SS-24)
#                expect: "differing 0"
#   make tied    rom_ok = 1'b1 (before SS-24)
#                expect: nearly every sample differs
#
# Needs sim/rtl/sandscrp/roms/sandscrp_oki.hex
# (python3 tools/gen_sandscrp_mra.py --simroms sandscrp). ~1.5 min per run.
RTL   := ../../../rtl
MODEL := ../../models
HEX   := $(abspath ../sandscrp/roms/sandscrp_oki.hex)
NSAMP ?= 60000
SRC   := okirom_tb_top.sv $(RTL)/sdram.sv $(RTL)/sdram_req.sv $(RTL)/sdram_arb.sv \
         $(RTL)/rom_cache1.sv $(RTL)/rom_cache1_byte.sv $(RTL)/oki_rom_cache.sv $(MODEL)/sdram_model.sv
V := verilator --cc --exe --build -O3 -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT -Wno-BLKANDNBLK \
     -Wno-CASEINCOMPLETE -Wno-TIMESCALEMOD -Wno-MULTIDRIVEN --top-module okirom_tb_top \
     +define+SIMULATION '+define+OKI_HEX="$(HEX)"' -y $(RTL)/third_party/jt6295/hdl

.PHONY: all gated tied clean
all: gated tied

obj_gated/Vtb: $(SRC) tb_okirom.cpp
	$(V) +define+ROMOK_GATED -Mdir obj_gated $(SRC) tb_okirom.cpp -o Vtb
obj_tied/Vtb: $(SRC) tb_okirom.cpp
	$(V) -Mdir obj_tied $(SRC) tb_okirom.cpp -o Vtb

gated: obj_gated/Vtb
	./obj_gated/Vtb $(HEX) $(NSAMP) obj_gated/out.raw
tied: obj_tied/Vtb
	./obj_tied/Vtb $(HEX) $(NSAMP) obj_tied/out.raw

clean:
	rm -rf obj_gated obj_tied
