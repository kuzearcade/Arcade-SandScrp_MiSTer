// M1 harness: rtl/kaneko/video_sandscrp.sv (HW_ROMS=0) driven by
// video_timing_sandscrp, loaded with one MAME state dump through the real
// 68000 write ports (tb_video_state.cpp), then one frame sampled off the
// live raster into a PPM for a pixel-exact comparison with MAME's frame.
module video_state_top #(
	parameter TILES_FILE = "",
	parameter SPRITES_FILE = ""
) (
	input         clk,
	input         reset,
	input         sprite_flip,
	// CPU-side loads
	input  [12:0] view2_vram_addr, input [3:0] view2_reg_addr, input [11:0] pandora_addr, input [10:0] pal_addr,
	input  [15:0] cpu_wdata, input [7:0] pandora_wdata,
	input         view2_vram_we, view2_reg_we, pandora_we, pal_we,
	output [15:0] view2_vram_rdata, view2_reg_rdata, pal_rdata,
	output [7:0]  pandora_rdata,
	// raster state for the testbench
	output        ce_pix, hactive, vactive, eof, line_start,
	output [8:0]  hcount, vcount,
	output [23:0] rd_rgb,
	output        pandora_busy,
	output [31:0] dbg_pass_cycles
);
	reg [2:0] div = 3'd0;
	always @(posedge clk) div <= reset ? 3'd0 : div + 3'd1;
	assign ce_pix = (div == 3'd7);
	wire vis_start, hblank, vblank;
	video_timing_sandscrp timing (
		.clk_sys(clk), .ce_pix(ce_pix), .reset(reset), .hcount(hcount), .vcount(vcount),
		.line_start(line_start), .hblank(hblank), .vblank(vblank), .vbl_start(eof), .vis_start(vis_start),
		.hactive(hactive), .vactive(vactive)
	);
	wire [8:0] render_y = (vcount == 9'd261) ? 9'd0 : vcount + 9'd1;
	video_sandscrp #(.HW_ROMS(0), .TILES_FILE(TILES_FILE), .SPRITES_FILE(SPRITES_FILE)) video (
		.clk(clk), .reset(reset),
		.view2_vram_addr(view2_vram_addr), .view2_reg_addr(view2_reg_addr), .pandora_addr(pandora_addr), .pal_addr(pal_addr),
		.cpu_wdata(cpu_wdata),
		.view2_vram_we_hi(view2_vram_we), .view2_vram_we_lo(view2_vram_we),
		.view2_reg_we_hi(view2_reg_we), .view2_reg_we_lo(view2_reg_we),
		.pandora_we(pandora_we), .pandora_wdata(pandora_wdata),
		.pal_we_hi(pal_we), .pal_we_lo(pal_we),
		.view2_vram_rdata(view2_vram_rdata), .view2_reg_rdata(view2_reg_rdata), .pandora_rdata(pandora_rdata), .pandora_hold(), .pal_rdata(pal_rdata),
		.line_start(line_start), .render_y(render_y), .eof(eof), .vis_start(vis_start), .sprite_flip(sprite_flip),
		.rd_x(hcount[7:0]), .rd_y(vcount), .rd_rgb(rd_rgb),
		.rom0_addr(), .rom1_addr(), .roms_addr(), .rom0_data(8'd0), .rom1_data(8'd0), .roms_data(8'd0),
		.rom0_ready(1'b1), .rom1_ready(1'b1), .roms_ready(1'b1),
		.pandora_busy(pandora_busy), .dbg_pass_cycles(dbg_pass_cycles), .dbg_late_swaps()
	);
endmodule
