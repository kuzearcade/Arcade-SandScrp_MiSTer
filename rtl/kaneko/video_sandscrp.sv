// Sand Scorpion video: VIEW2 (two tile layers) + PANDORA (sprite plane) +
// the 2048-entry xGRB_555 palette, composed per pixel exactly as
// sandscrp.cpp screen_update draws: fill with palette index 0; tile
// categories 0..3 (layer 0 then layer 1 for each); the sprite plane with
// index 0 transparent; categories 4..7 (layer 0 then layer 1). Every draw
// is a plain overwrite, so per pixel: the highest-category opaque tile
// pixel wins among tiles (layer 1 on a tie); if its category is 4..7 it
// covers the sprite, otherwise an opaque sprite pixel covers it; nothing
// opaque gives index 0.
//
// Palette: sprites use entries 0x000-0x0FF (bank*16 + pen), tiles
// 0x400 + colour*16 + pen (set_colbase(0x400)). xGRB_555: bit 15 unused,
// G = bits 14-10, R = 9-5, B = 4-0, expanded 5->8 bits as pal5bit
// ((v << 3) | (v >> 2)).
//
// Readback: rd_rgb is TWO clocks behind rd_x/rd_y (stage 1: line buffers +
// sprite plane, registered; stage 2: palette word, registered), inside the
// eight-clock pixel period. rd_y is the BITMAP row (16..239 visible).
// The core supplies render_y (the bitmap row the tile renderers prepare
// during the current line) so the OSD flip, which mirrors the rows the
// core asks for, needs nothing here.
module video_sandscrp #(
	parameter HW_ROMS = 0,
	parameter TILES_FILE = "",
	parameter SPRITES_FILE = "",
	parameter PANDORA_LAG1 = 0
) (
	input             clk,
	input             reset,

	// 68000 ports (all registered reads, valid the clock after the address)
	input      [12:0] view2_vram_addr,          // 0x400000-0x403FFF, A13..A1
	input      [3:0]  view2_reg_addr,           // 0x300000-0x30001F, A4..A1
	input      [11:0] pandora_addr,             // 0x500000-0x501FFF, A12..A1
	input      [10:0] pal_addr,                 // 0x600000-0x600FFF, A11..A1
	input      [15:0] cpu_wdata,
	input             view2_vram_we_hi, view2_vram_we_lo,
	input             view2_reg_we_hi,  view2_reg_we_lo,
	input             pandora_we,               // byte from whichever lane the CPU drives (core selects)
	input      [7:0]  pandora_wdata,
	input             pal_we_hi, pal_we_lo,
	output     [15:0] view2_vram_rdata,
	output     [15:0] view2_reg_rdata,          // combinational
	output     [7:0]  pandora_rdata,
	output            pandora_hold,
	output     [15:0] pal_rdata,

	// raster
	input             line_start,
	input      [8:0]  render_y,
	input             eof,                      // vblank start: Pandora eof
	input             vis_start,
	input             sprite_flip,              // irq_cause bit 0
	input             ss_hold,                  // freeze the sprite engine while parked
	input             ss_disp_wr,
	input             ss_disp_in,
	output            ss_disp_out,

	// readback
	input      [7:0]  rd_x,
	input      [8:0]  rd_y,                     // bitmap row
	output     [23:0] rd_rgb,

	// tile / sprite ROM byte streams (HW_ROMS=1)
	output     [23:0] rom0_addr, rom1_addr, roms_addr,
	input      [7:0]  rom0_data, rom1_data, roms_data,
	input             rom0_ready, rom1_ready, roms_ready,

	output            pandora_busy,
	output     [31:0] dbg_pass_cycles,
	output     [15:0] dbg_late_swaps
);
	// ------------------------------------------------------------ palette
	reg [7:0] pal_hi [0:2047];
	reg [7:0] pal_lo [0:2047];
	reg [7:0] pq_hi, pq_lo;
	always @(posedge clk) begin
		if (pal_we_hi) begin pal_hi[pal_addr] <= cpu_wdata[15:8]; pq_hi <= cpu_wdata[15:8]; end else pq_hi <= pal_hi[pal_addr];
		if (pal_we_lo) begin pal_lo[pal_addr] <= cpu_wdata[7:0];  pq_lo <= cpu_wdata[7:0];  end else pq_lo <= pal_lo[pal_addr];
	end
	assign pal_rdata = {pq_hi, pq_lo};

	// ------------------------------------------------------------ layers
	wire [12:0] l0_pix, l1_pix;
	view2 #(.HW_ROMS(HW_ROMS), .TILES_FILE(TILES_FILE)) view2_i (
		.clk(clk), .reset(reset),
		.cpu_vram_addr(view2_vram_addr), .cpu_wdata(cpu_wdata),
		.cpu_vram_we_hi(view2_vram_we_hi), .cpu_vram_we_lo(view2_vram_we_lo), .cpu_vram_rdata(view2_vram_rdata),
		.cpu_reg_addr(view2_reg_addr), .cpu_reg_we_hi(view2_reg_we_hi), .cpu_reg_we_lo(view2_reg_we_lo), .cpu_reg_rdata(view2_reg_rdata),
		.line_start(line_start), .render_y(render_y),
		.rd_x(rd_x), .rd_y(rd_y), .l0_pix(l0_pix), .l1_pix(l1_pix),
		.rom0_addr(rom0_addr), .rom0_data_i(rom0_data), .rom0_ready_i(rom0_ready),
		.rom1_addr(rom1_addr), .rom1_data_i(rom1_data), .rom1_ready_i(rom1_ready),
		.l0_line_busy(), .l1_line_busy()
	);

	// ------------------------------------------------------------ sprites
	wire [7:0] spr_pix;
	wire       rd_in_plane = (rd_y >= 9'd16) && (rd_y < 9'd240);
	pandora #(.HW_ROMS(HW_ROMS), .SPRITES_FILE(SPRITES_FILE), .LAG1(PANDORA_LAG1)) pandora_i (
		.clk(clk), .reset(reset),
		.cpu_addr(pandora_addr), .cpu_wdata(pandora_wdata), .cpu_we(pandora_we), .cpu_rdata(pandora_rdata), .cpu_hold(pandora_hold),
		.eof(eof), .vis_start(vis_start), .flip(sprite_flip),
		.ss_hold(ss_hold), .ss_wr(ss_disp_wr), .ss_disp_in(ss_disp_in), .ss_disp_out(ss_disp_out),
		.rom_addr(roms_addr), .rom_data_i(roms_data), .rom_ready_i(roms_ready),
		.rd_x(rd_x), .rd_y(rd_y[7:0] - 8'd16), .rd_pix(spr_pix),
		.busy(pandora_busy), .dbg_pass_cycles(dbg_pass_cycles), .dbg_late_swaps(dbg_late_swaps)
	);

	// ------------------------------------------------------------ composition
	// stage 1 (one clock after rd_x): l0_pix, l1_pix, spr_pix are all registered reads
	reg in_plane_r;
	always @(posedge clk) in_plane_r <= rd_in_plane;
	wire l0_op = (l0_pix[3:0] != 4'd0);
	wire l1_op = (l1_pix[3:0] != 4'd0);
	wire tile_pick1 = l1_op && (!l0_op || (l1_pix[12:10] >= l0_pix[12:10]));   // layer 1 wins ties
	wire [12:0] tpix = tile_pick1 ? l1_pix : l0_pix;
	wire tile_op = l0_op | l1_op;
	wire spr_op = in_plane_r && (spr_pix != 8'd0);
	wire tile_over = tile_op && (tpix[12] || !spr_op);                       // category 4..7 covers sprites
	wire [10:0] index = tile_over ? {1'b1, tpix[9:4], tpix[3:0]} :           // 0x400 + colour*16 + pen
	                    spr_op    ? {3'b000, spr_pix} : 11'd0;
	// stage 2: palette read (registered), then xGRB_555 -> RGB
	reg [7:0] vq_hi, vq_lo;
	always @(posedge clk) begin vq_hi <= pal_hi[index]; vq_lo <= pal_lo[index]; end
	wire [4:0] g5 = vq_hi[6:2];
	wire [4:0] r5 = {vq_hi[1:0], vq_lo[7:5]};
	wire [4:0] b5 = vq_lo[4:0];
	assign rd_rgb = {r5, r5[4:2], g5, g5[4:2], b5, b5[4:2]};
endmodule
