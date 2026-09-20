// Kaneko PANDORA (PX79C480FP-3) sprite generator, as MAME kaneko/kan_pand.cpp
// models it: 512 x 8-byte entries in a 4 KB RAM, rendered whole into a
// framebuffered plane at every eof() (vblank start), double buffered
// ("4 64x4 DRAMs - 256x256 8 bit, double buffered"); the screen shows the
// plane drawn at the PREVIOUS eof with palette index 0 transparent.
//
// Entry (bytes 0-2 unused):
//   3  [7:4] palette bank (16 banks of 16, base 0)  [2] relative position
//      [1] Y bit 8  [0] X bit 8
//   4  X low   5  Y low   6  code low 8 bits
//   7  [7] flip X  [6] flip Y  [5:0] code high 6 bits   (kan_pand.cpp draw():
//      flipx = BIT(attr,7), flipy = BIT(attr,6) -- the code, not the table
//      comment above it, which has the two swapped)
// Entries are walked 0..511; with bit 2 set dx/dy are ADDED to the running
// x/y instead of replacing them (multi-tile objects). Then sx = sext9(x),
// sy = sext9(y) -- a tile straddling the left/top edge shows its visible
// part -- and the 16x16 tile is drawn with pen 0 transparent. Later entries
// overwrite earlier ones. Flip screen (irq_cause bit 0 on this board, which
// MAME leaves commented out -- measured 2026-09-19 with the Flip Screen DIP:
// the game writes 0x1b/0x33/0x3b instead of 0x1a/0x32/0x3a): sx = 240 - x,
// sy = 240 - y, both flips inverted.
//
// Tile pixels: gfx_8x8x4_row_2x2_group_packed_msb -- 128 bytes per tile,
// four 8x8 blocks TL,TR,BL,BR of 32 bytes, 4 bytes per row, HIGH nibble =
// left pixel (tools/decode_kaneko_gfx.py is the checked reference).
//
// Implementation:
//   * Sprite RAM: four 8-bit lane arrays (byte address = {word, lane}) so the
//     68000's one-byte-per-word-address writes and the snapshot's 4-bytes-
//     per-cycle reads both map to M10K. The CPU read is registered.
//   * eof: SNAPSHOT the whole RAM into snap[] (1024 dwords, ~1024 cycles);
//     cpu_hold is high meanwhile so the core stalls any CPU access to the
//     RAM (MAME's copy is instantaneous; the game's vblank handler starts
//     rewriting the table right after the same interrupt). Then CLEAR the
//     draw plane and DRAW the table from the snapshot.
//   * Plane: 2 x 256x224 (visible rows only) bytes, one flat array indexed by
//     plane*PLANE_PX + y*256 + x (an offset, never a concatenation), entry =
//     {bank[3:0], pen[3:0]}, 0 = empty. Readback registered (1 clock).
//   * Swap: the finished plane goes on display at the next eof (lag: the
//     table snapshotted at eof N is visible from the frame after eof N+1,
//     one frame later than MAME) unless LAG1 is set, in which case a pass
//     that finished before the next visible area starts shows from that
//     frame (MAME's own latency) -- measure before choosing (docs/PLAN.md 2.3).
//   * ROM bytes come through rom_addr/rom_data/rom_ready: a $readmemh array
//     when HW_ROMS=0, rom_cache_n_byte in the core when HW_ROMS=1.
module pandora #(
	parameter HW_ROMS = 0,
	parameter SPRITES_FILE = "",
	parameter integer SPRITES_BYTES = 1048576,
	parameter LAG1 = 0,
	parameter integer PLANE_W = 256,
	parameter integer PLANE_H = 224,
	parameter integer ROW0 = 16                // bitmap row of plane row 0
) (
	input             clk,
	input             reset,

	// 68000 side: word address (A12..A1), one byte per word address
	input      [11:0] cpu_addr,
	input      [7:0]  cpu_wdata,
	input             cpu_we,
	output reg [7:0]  cpu_rdata,               // registered: valid the clock after cpu_addr
	output            cpu_hold,                // snapshot in progress: hold DTACK for RAM accesses

	input             eof,                     // one clk pulse at vblank start
	input             vis_start,               // one clk pulse at the first visible line
	input             flip,
	// Savestates: the chip is frozen while the machine is parked, and the
	// DISPLAYED buffer index is saved. That one bit is real state -- it decides
	// which of the two planes is on screen, so restoring it wrong leaves the
	// sprites permanently one frame stale against the tilemaps, which is
	// exactly what it did (docs/known-issues.md SS-13).
	input             ss_hold,
	input             ss_wr,
	input             ss_disp_in,
	output            ss_disp_out,

	// tile ROM byte stream (HW_ROMS=1)
	output     [23:0] rom_addr,
	input      [7:0]  rom_data_i,
	input             rom_ready_i,

	// plane readback, registered
	input      [7:0]  rd_x,
	input      [7:0]  rd_y,
	output reg [7:0]  rd_pix,

	output            busy,                    // snapshot or pass running
	output reg [31:0] dbg_pass_cycles,         // clocks of the last complete snapshot+clear+draw
	output reg [15:0] dbg_late_swaps           // eofs at which the previous pass had not finished
);
	localparam integer PLANE_PX = PLANE_W * PLANE_H;

	// ---------------------------------------------------------------- sprite RAM
	reg [7:0] ram0 [0:1023];
	reg [7:0] ram1 [0:1023];
	reg [7:0] ram2 [0:1023];
	reg [7:0] ram3 [0:1023];
	wire [9:0] cpu_dw = cpu_addr[11:2];
	always @(posedge clk) begin
		if (cpu_we) case (cpu_addr[1:0])
			2'd0: ram0[cpu_dw] <= cpu_wdata;
			2'd1: ram1[cpu_dw] <= cpu_wdata;
			2'd2: ram2[cpu_dw] <= cpu_wdata;
			default: ram3[cpu_dw] <= cpu_wdata;
		endcase
		case (cpu_addr[1:0])
			2'd0: cpu_rdata <= ram0[cpu_dw];
			2'd1: cpu_rdata <= ram1[cpu_dw];
			2'd2: cpu_rdata <= ram2[cpu_dw];
			default: cpu_rdata <= ram3[cpu_dw];
		endcase
	end

	// snapshot: second read port over the four lanes, registered
	reg  [9:0]  snap_rd_addr;
	reg  [31:0] snap_rd_data;
	always @(posedge clk) snap_rd_data <= {ram3[snap_rd_addr], ram2[snap_rd_addr], ram1[snap_rd_addr], ram0[snap_rd_addr]};

	reg  [31:0] snap [0:1023];
	reg  [9:0]  snap_addr;
	reg  [31:0] snap_q;
	always @(posedge clk) snap_q <= snap[snap_addr];

	// ---------------------------------------------------------------- plane
	reg [7:0] plane [0:2*PLANE_PX-1];
	reg       disp_buf;
	reg       draw_buf;
	wire [16:0] rd_off = rd_y * PLANE_W + rd_x;
	always @(posedge clk) rd_pix <= plane[rd_off + (disp_buf ? PLANE_PX : 0)];

	// ---------------------------------------------------------------- ROM
	wire [7:0] rom_data;
	wire       rom_ready;
	generate
	if (!HW_ROMS) begin : g_rom_sim
		reg [7:0] sprites_rom [0:SPRITES_BYTES-1];
		initial if (SPRITES_FILE != "") $readmemh(SPRITES_FILE, sprites_rom);
		assign rom_data  = sprites_rom[rom_addr[19:0]];
		assign rom_ready = 1'b1;
	end else begin : g_rom_hw
		assign rom_data  = rom_data_i;
		assign rom_ready = rom_ready_i;
	end
	endgenerate

	// ---------------------------------------------------------------- FSM
	localparam [3:0] S_IDLE = 0, S_SNAP = 1, S_SNAP_LAST = 2, S_CLEAR = 3, S_HEAD0 = 4, S_HEAD1 = 5,
	                 S_HEAD2 = 6, S_DECIDE = 7, S_PIX = 8, S_DONE = 9;
	reg [3:0]  state;
	reg        pass_done;      // a drawn plane (draw_buf) awaits its swap
	reg        eof_pending;    // eof arrived while a pass was running: start the next pass when done
	reg [16:0] clr_idx;
	reg [8:0]  slot;
	reg [1:0]  snap_ph;
	reg [31:0] w0, w1;
	reg signed [15:0] acc_x, acc_y;            // running position (MAME ints; only bits 8:0 matter)
	reg signed [9:0]  sx, sy;                  // sext9
	reg [12:0] code;
	reg [3:0]  bank;
	reg        fx, fy;
	reg [3:0]  px, py;
	reg [31:0] pass_cnt;

	assign cpu_hold = (state == S_SNAP) || (state == S_SNAP_LAST);
	assign busy     = (state != S_IDLE);
	assign ss_disp_out = disp_buf;

	// per-pixel address, combinational from the registered unit state
	wire [3:0] pxs = fx ? ~px : px;
	wire [3:0] pys = fy ? ~py : py;
	assign rom_addr = {4'd0, code, 7'd0} + {pys[3], 6'd0} + {pxs[3], 5'd0} + {pys[2:0], 2'd0} + {pxs[2:1]};
	wire [3:0] nib  = pxs[0] ? rom_data[3:0] : rom_data[7:4];
	wire signed [10:0] plot_x = sx + $signed({7'd0, px});
	wire signed [10:0] plot_y = sy + $signed({7'd0, py});
	wire plot_on = (plot_x >= 0) && (plot_x < PLANE_W) && (plot_y >= ROW0) && (plot_y < ROW0 + PLANE_H);
	wire [16:0] plot_off = (plot_y - ROW0) * PLANE_W + plot_x;
	// whole tile off the plane: skip it (MAME clips; walking 256 pixels each is what makes a pass long)
	wire tile_off = (sx > PLANE_W - 1) || (sx < -15) || (sy > ROW0 + PLANE_H - 1) || (sy < ROW0 - 15);

	function automatic signed [9:0] sext9(input [8:0] v); sext9 = {v[8], v}; endfunction

	always @(posedge clk) begin
		if (reset) begin
			state <= S_IDLE; pass_done <= 1'b0; eof_pending <= 1'b0; disp_buf <= 1'b0; draw_buf <= 1'b1;
			dbg_pass_cycles <= 32'd0; dbg_late_swaps <= 16'd0; pass_cnt <= 32'd0;
		end else begin
			if (state != S_IDLE) pass_cnt <= pass_cnt + 32'd1;
			// swap rule: the drawn plane goes on display at eof (or, LAG1, at the
			// first visible line if the pass finished in time)
			if (eof && !ss_hold) begin
				if (pass_done) begin disp_buf <= draw_buf; pass_done <= 1'b0; end
				else if (state != S_IDLE) dbg_late_swaps <= dbg_late_swaps + 16'd1;
			end
			if (LAG1 && vis_start && pass_done && !ss_hold) begin disp_buf <= draw_buf; pass_done <= 1'b0; end

			case (state)
			S_IDLE: if ((eof || eof_pending) && !ss_hold) begin
				eof_pending <= 1'b0;
				state <= S_SNAP; snap_rd_addr <= 10'd0; snap_ph <= 2'd0; snap_addr <= 10'd0; pass_cnt <= 32'd1;
				// draw into the plane not on display (if a finished pass is still waiting for
				// its swap, its plane is about to be shown; draw over the other one)
				draw_buf <= pass_done ? disp_buf : ~disp_buf;
				if (pass_done) begin disp_buf <= draw_buf; pass_done <= 1'b0; end
			end
			// snapshot: one dword per clock through the registered lane read (one-cycle lag)
			S_SNAP: begin
				snap_rd_addr <= snap_rd_addr + 10'd1;
				if (snap_ph == 2'd0) snap_ph <= 2'd1;
				else begin
					snap[snap_rd_addr - 10'd1] <= snap_rd_data;
					if (snap_rd_addr == 10'd0) state <= S_SNAP_LAST; // wrapped: the last word lands next cycle
				end
			end
			S_SNAP_LAST: begin                          // the wrap cycle above wrote word 1023
				state <= S_CLEAR; clr_idx <= 17'd0;
			end
			S_CLEAR: begin
				plane[clr_idx + (draw_buf ? PLANE_PX : 0)] <= 8'd0;
				if (clr_idx == PLANE_PX - 1) begin
					state <= S_HEAD0; slot <= 9'd0; acc_x <= 16'sd0; acc_y <= 16'sd0;
					snap_addr <= 10'd0;
				end else clr_idx <= clr_idx + 17'd1;
			end
			// header: two registered dword reads (settle cycle each)
			// snap_addr already points at word 0 (set when the slot advanced / after the clear)
			S_HEAD0: begin snap_addr <= {slot, 1'b1}; state <= S_HEAD1; end      // snap_q <- word 0 next clock
			S_HEAD1: begin w0 <= snap_q; state <= S_HEAD2; end                    // snap_q <- word 1 next clock
			S_HEAD2: begin w1 <= snap_q; state <= S_DECIDE; end
			S_DECIDE: begin : decide
				reg [15:0] dx, dy;
				reg signed [15:0] nx, ny;
				reg signed [15:0] fxv, fyv;
				dx = {7'd0, w0[24], w1[7:0]};         // byte 4, X bit 8 from byte 3 bit 0
				dy = {7'd0, w0[25], w1[15:8]};        // byte 5, Y bit 8 from byte 3 bit 1
				nx = w0[26] ? acc_x + $signed(dx) : $signed(dx);
				ny = w0[26] ? acc_y + $signed(dy) : $signed(dy);
				acc_x <= nx; acc_y <= ny;
				fxv = flip ? 16'sd240 - nx : nx;
				fyv = flip ? 16'sd240 - ny : ny;
				sx <= sext9(fxv[8:0]);
				sy <= sext9(fyv[8:0]);
				code <= {w1[28:24], w1[23:16]};       // 14-bit code & 0x1FFF (8192 tiles in 1 MB)
				bank <= w0[31:28];
				fx <= w1[31] ^ flip; fy <= w1[30] ^ flip;
				px <= 4'd0; py <= 4'd0;
				state <= S_PIX;
			end
			S_PIX: begin
				if (tile_off) begin
					state <= (slot == 9'd511) ? S_DONE : S_HEAD0; slot <= slot + 9'd1; snap_addr <= {slot + 9'd1, 1'b0};
				end else if (rom_ready) begin
					if (plot_on && nib != 4'd0) plane[plot_off + (draw_buf ? PLANE_PX : 0)] <= {bank, nib};
					px <= px + 4'd1;
					if (px == 4'd15) begin
						py <= py + 4'd1;
						if (py == 4'd15) begin
							state <= (slot == 9'd511) ? S_DONE : S_HEAD0; slot <= slot + 9'd1; snap_addr <= {slot + 9'd1, 1'b0};
						end
					end
				end
			end
			S_DONE: begin
				pass_done <= 1'b1; dbg_pass_cycles <= pass_cnt; state <= S_IDLE;
			end
			default: state <= S_IDLE;
			endcase
			if (eof && state != S_IDLE && !ss_hold) eof_pending <= 1'b1;
			// last, so it wins over any swap decided this cycle
			if (ss_wr) disp_buf <= ss_disp_in;
		end
	end
endmodule
