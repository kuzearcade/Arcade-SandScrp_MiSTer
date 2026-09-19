# CALC1 against a transcription of MAME's own kaneko_hit_type0_r/w.
RTL := ../../../rtl/kaneko
OBJ := obj_dir
SRC := kaneko_hit_test_top.sv $(RTL)/kaneko_hit.sv
all: run
$(OBJ)/Vkaneko_hit_test_top: $(SRC) tb_kaneko_hit.cpp Makefile
	verilator --cc --exe --build -Wall -Wno-fatal -Wno-DECLFILENAME -Wno-UNUSED -Wno-WIDTH \
		--top-module kaneko_hit_test_top --Mdir $(OBJ) $(SRC) tb_kaneko_hit.cpp -o Vkaneko_hit_test_top
run: $(OBJ)/Vkaneko_hit_test_top
	./$(OBJ)/Vkaneko_hit_test_top
clean:
	rm -rf $(OBJ)
