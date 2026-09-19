# M1 video harness: one MAME state dump -> one RTL frame (PPM).
#   make DUMP=dump/f560_ OUT=f560.ppm run
#   make DUMP=dump/flip1400_ OUT=flip1400.ppm run   (layer flip comes from the dump)
RTL := ../../../rtl/kaneko
ROMS := ../sandscrp/roms
OBJ := obj_dir
DUMP ?= dump/f560_
OUT ?= video_state.ppm
FLIP ?= 0
SOURCES := video_state_top.sv $(RTL)/video_timing_sandscrp.sv $(RTL)/video_sandscrp.sv $(RTL)/view2.sv $(RTL)/pandora.sv

$(OBJ)/Vvideo_state_top: $(SOURCES) tb_video_state.cpp
	verilator --cc --exe --build -Wall -Wno-fatal -Wno-UNUSED -Wno-PINCONNECTEMPTY -Wno-WIDTH --top-module video_state_top \
		--Mdir $(OBJ) -GTILES_FILE=\"$(ROMS)/sandscrp_view2.hex\" -GSPRITES_FILE=\"$(ROMS)/sandscrp_sprites.hex\" \
		$(SOURCES) tb_video_state.cpp -o Vvideo_state_top

run: $(OBJ)/Vvideo_state_top
	./$(OBJ)/Vvideo_state_top $(DUMP) $(OUT) $(FLIP)

clean:
	rm -rf $(OBJ)
