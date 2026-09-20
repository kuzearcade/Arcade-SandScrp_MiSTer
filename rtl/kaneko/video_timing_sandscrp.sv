// Sand Scorpion raster timing. Nothing in MAME documents this board's raster
// (sandscrp.cpp: set_refresh_hz(60), set_vblank_time(2500 us) "not accurate",
// set_size(256,256), set_visarea(0,255,16,239)); the values here are the
// sibling Kaneko/Pandora board snowbros.cpp's confirmed ones (12 MHz/2 pixel
// clock, 384 pixels per line, 262 lines, visible bitmap rows 16..239, "~57.5
// Hz confirmed") except VTOTAL, which is a parameter: 262 gives 59.64 Hz,
// 264 59.19 Hz at 15.625 kHz. A PCB measurement should settle it (see
// docs/known-issues.md SS-1). Everything timing-related hangs off these
// parameters; no magic numbers elsewhere.
//
// Coordinates are MAME's BITMAP coordinates: vcount == bitmap row, so the
// visible window is rows 16..239 (224 lines) and columns 0..255 of the
// 384-pixel line. The vblank interrupt, the sprite interrupt and Pandora's
// eof all happen at the first vblank line (vcount == VACTIVE_END, hcount 0),
// which MAME models as one instant (screen.cpp vblank_begin: render, then
// the vblank callbacks).
//
// Reset phase: vcount starts at VACTIVE_END, the first vblank line, as MAME's
// screen device does at machine time 0 (NMK16 video_timing.sv's measured
// finding), so the first interrupt comes one full frame after reset.
module video_timing_sandscrp #(
	parameter HTOTAL = 384,
	parameter VTOTAL = 262,
	parameter HACTIVE_END = 256,   // exclusive; active columns 0..255
	parameter VACTIVE_START = 16,
	parameter VACTIVE_END = 240    // exclusive; active rows 16..239
) (
	input            clk_sys,
	input            ce_pix,       // 6 MHz pixel enable
	input            reset,
	output reg [8:0] hcount,       // 0..HTOTAL-1
	output reg [8:0] vcount,       // 0..VTOTAL-1 (bitmap row)
	output           line_start,   // ce_pix pulse at hcount == 0
	output           hblank,
	output           vblank,
	output           vbl_start,    // one clk_sys pulse: first vblank line, hcount 0 (IRQ / eof instant)
	output           vis_start,    // one clk_sys pulse: first visible line, hcount 0
	output           hactive,
	output           vactive
);
	always @(posedge clk_sys) begin
		if (reset) begin
			hcount <= 9'd0;
			vcount <= VACTIVE_END[8:0];
		end else if (ce_pix) begin
			if (hcount == HTOTAL - 1) begin
				hcount <= 9'd0;
				vcount <= (vcount == VTOTAL - 1) ? 9'd0 : vcount + 9'd1;
			end else begin
				hcount <= hcount + 9'd1;
			end
		end
	end

	assign line_start = ce_pix & (hcount == 9'd0);
	assign hactive    = (hcount < HACTIVE_END);
	assign vactive    = (vcount >= VACTIVE_START) && (vcount < VACTIVE_END);
	assign hblank     = ~hactive;
	assign vblank     = ~vactive;
	assign vbl_start  = line_start & (vcount == VACTIVE_END);
	assign vis_start  = line_start & (vcount == VACTIVE_START);
endmodule
