// Kaneko VIEW2 tilemap chip, as MAME kaneko/kaneko_tmap.cpp models it for
// Sand Scorpion (one chip, two 512x512 layers of 16x16x4 tiles, per-row
// line scroll, 8 priority categories).
//
// Memory (68000 0x400000-0x403FFF, word addresses here):
//   0x000-0x7FF  layer 1 ("FG", m_tmap[1]) tiles: 32x32 x {attr, code}
//   0x800-0xFFF  layer 0 ("BG", m_tmap[0]) tiles
//   0x1000-0x17FF layer 1 line scroll (512 words used, 2048 mapped)
//   0x1800-0x1FFF layer 0 line scroll
// Registers (0x300000-1F): 0 layer-1 scroll X, 1 layer-1 scroll Y, 2 layer-0
// scroll X, 3 layer-0 scroll Y (all in 1/64 pixel: value >> 6), 4 control,
// 5..15 stored and unused. Control: bit 12 layer-0 disable, 11 layer-0 line
// scroll, 4 layer-1 disable, 3 layer-1 line scroll -- and bits 9/8 flip X/Y
// for BOTH layers. The chip's own register documentation in kaneko_tmap.cpp
// lists bits 1/0 as a second, per-layer flip pair, but prepare_common()
// ignores them: it gives m_tmap[0] AND m_tmap[1] the flip taken from bits
// 9/8. Sand Scorpion writes 0x0303 with the Flip Screen DIP on -- both pairs
// at once -- so this capture cannot tell the two readings apart; MAME's
// behaviour is what the core matches.
// Tile attr: bits 10-8 category, 7-2 colour, bit 1 flip Y, bit 0 flip X
// (tileinfo.set(..., TILE_FLIPXY(attr & 3)); TILE_FLIPX == 0x01 -- the
// comment block in kaneko_tmap.cpp has the two swapped). Code: 16 bits,
// wrapped to the 8192 tiles of the 1 MB ROM (code % total_elements).
//
// Geometry, straight from tilemap.cpp with set_offset(0x5b, 0, 256, 224)
// (layer 0 dx = -0x5b, layer 1 dx = -(0x5b+2); dx_flipped = xdim + dx - 1,
// dy_flipped = ydim - 1; the flip "around the centre of the visible area"
// uses xextent = 256 and yextent = 256): for the screen pixel at column sx
// and BITMAP row y (= screen row + 16), the UNFLIPPED tilemap coordinates
// are
//     u_y = flipY ? (sy - y + 32)      : (y + sy)            (mod 512)
//     u_x = flipX ? (rs - sx - DX)     : (sx + rs + DX)      (mod 512)
// with sy = reg_y >> 6, rs = (reg_x + (line scroll enabled ? vscroll[u_y]
// : 0)) >> 6 (16-bit sum), DX = 0x5b (layer 0) / 0x5d (layer 1); the line
// scroll table is indexed by the unflipped tilemap row in both cases
// (effective_rowscroll maps index -> 511 - index under FLIPY, which undoes
// the pixmap mirror). The tile at (u_x >> 4, u_y >> 4) is then drawn with
// its own flip bits (the tilemap-level flip mirrors the whole pixmap, tile
// pixels included: tile_update XORs the flip attributes, memory_index
// mirrors the columns/rows).
//
// Pixels: gfx_8x8x4_row_2x2_group_packed_lsb -- 128 bytes per tile, blocks
// TL,TR,BL,BR of 32 bytes, 4 bytes per row, LOW nibble = left pixel
// (tools/decode_kaneko_gfx.py). Pen 0 is transparent.
//
// Implementation: each layer renders one line ahead into a double line
// buffer (256 x {category, colour, pen}) from its own VRAM/scroll RAM ports
// and its own ROM byte stream, so the per-pixel readback never waits on
// memory: at line_start the layer starts rendering bitmap row render_y into
// buffer render_y[0]; the readback serves rd_x from buffer rd_y[0] one clock
// later. The core decides which row comes next (the OSD flip mirrors rows).
// Registers are read live at each line start (the game writes them at
// vblank: 43,725 of 43,800 writes in a 9,000-frame capture landed at vpos
// 218, right after the interrupt).
module view2 #(
	parameter HW_ROMS = 0,
	parameter TILES_FILE = "",
	parameter integer TILES_BYTES = 1048576
) (
	input             clk,
	input             reset,

	// 68000: VRAM map (word address A13..A1) and registers (A4..A1)
	input      [12:0] cpu_vram_addr,
	input      [15:0] cpu_wdata,
	input             cpu_vram_we_hi,
	input             cpu_vram_we_lo,
	output reg [15:0] cpu_vram_rdata,          // registered: valid the clock after the address
	input      [3:0]  cpu_reg_addr,
	input             cpu_reg_we_hi,
	input             cpu_reg_we_lo,
	output     [15:0] cpu_reg_rdata,           // combinational (registers are flops)

	// raster
	input             line_start,              // pulse: start rendering row render_y
	input      [8:0]  render_y,                // bitmap row to render next

	// readback, one clock after rd_x/rd_y
	input      [7:0]  rd_x,
	input      [8:0]  rd_y,                    // bitmap row
	output     [12:0] l0_pix,                  // {category[2:0], colour[5:0], pen[3:0]}
	output     [12:0] l1_pix,

	// tile ROM byte streams (HW_ROMS=1), one per layer
	output     [23:0] rom0_addr,
	input      [7:0]  rom0_data_i,
	input             rom0_ready_i,
	output     [23:0] rom1_addr,
	input      [7:0]  rom1_data_i,
	input             rom1_ready_i,

	output            l0_line_busy,            // diagnostics: renderer still running
	output            l1_line_busy
);
	// ------------------------------------------------------------ registers
	reg [15:0] regs [0:15];
	integer i;
	initial for (i = 0; i < 16; i = i + 1) regs[i] = 16'd0;
	always @(posedge clk) begin
		if (cpu_reg_we_hi) regs[cpu_reg_addr][15:8] <= cpu_wdata[15:8];
		if (cpu_reg_we_lo) regs[cpu_reg_addr][7:0]  <= cpu_wdata[7:0];
	end
	assign cpu_reg_rdata = regs[cpu_reg_addr];
	wire [15:0] ctrl = regs[4];

	// ------------------------------------------------------------ layers
	wire        sel1 = (cpu_vram_addr[12:11] == 2'b00);  // 0x0000-07FF
	wire        sel0 = (cpu_vram_addr[12:11] == 2'b01);  // 0x0800-0FFF
	wire        sels1 = (cpu_vram_addr[12:11] == 2'b10); // 0x1000-17FF
	wire        sels0 = (cpu_vram_addr[12:11] == 2'b11); // 0x1800-1FFF
	wire [15:0] rd0, rd1, rds0, rds1;
	reg  [1:0]  rsel;
	always @(posedge clk) rsel <= cpu_vram_addr[12:11];
	always @* case (rsel)
		2'b00: cpu_vram_rdata = rd1;
		2'b01: cpu_vram_rdata = rd0;
		2'b10: cpu_vram_rdata = rds1;
		default: cpu_vram_rdata = rds0;
	endcase

	view2_layer #(.HW_ROMS(HW_ROMS), .TILES_FILE(TILES_FILE), .TILES_BYTES(TILES_BYTES), .DX(9'h05b)) l0 (
		.clk(clk), .reset(reset),
		.cpu_addr(cpu_vram_addr[10:0]), .cpu_wdata(cpu_wdata),
		.vram_we_hi(cpu_vram_we_hi & sel0), .vram_we_lo(cpu_vram_we_lo & sel0), .vram_rdata(rd0),
		.scr_we_hi(cpu_vram_we_hi & sels0), .scr_we_lo(cpu_vram_we_lo & sels0), .scr_rdata(rds0),
		.reg_x(regs[2]), .reg_y(regs[3]), .disable_i(ctrl[12]), .ls_en(ctrl[11]), .flip_x(ctrl[9]), .flip_y(ctrl[8]),
		.line_start(line_start), .render_y(render_y), .rd_x(rd_x), .rd_y(rd_y), .pix(l0_pix),
		.rom_addr(rom0_addr), .rom_data_i(rom0_data_i), .rom_ready_i(rom0_ready_i), .line_busy(l0_line_busy)
	);
	view2_layer #(.HW_ROMS(HW_ROMS), .TILES_FILE(TILES_FILE), .TILES_BYTES(TILES_BYTES), .DX(9'h05d)) l1 (
		.clk(clk), .reset(reset),
		.cpu_addr(cpu_vram_addr[10:0]), .cpu_wdata(cpu_wdata),
		.vram_we_hi(cpu_vram_we_hi & sel1), .vram_we_lo(cpu_vram_we_lo & sel1), .vram_rdata(rd1),
		.scr_we_hi(cpu_vram_we_hi & sels1), .scr_we_lo(cpu_vram_we_lo & sels1), .scr_rdata(rds1),
		.reg_x(regs[0]), .reg_y(regs[1]), .disable_i(ctrl[4]), .ls_en(ctrl[3]), .flip_x(ctrl[9]), .flip_y(ctrl[8]),
		.line_start(line_start), .render_y(render_y), .rd_x(rd_x), .rd_y(rd_y), .pix(l1_pix),
		.rom_addr(rom1_addr), .rom_data_i(rom1_data_i), .rom_ready_i(rom1_ready_i), .line_busy(l1_line_busy)
	);
endmodule


module view2_layer #(
	parameter HW_ROMS = 0,
	parameter TILES_FILE = "",
	parameter integer TILES_BYTES = 1048576,
	parameter [8:0] DX = 9'h05b
) (
	input             clk,
	input             reset,

	input      [10:0] cpu_addr,                // word address within the 2048-word VRAM / scroll RAM
	input      [15:0] cpu_wdata,
	input             vram_we_hi, vram_we_lo,
	output     [15:0] vram_rdata,              // registered
	input             scr_we_hi, scr_we_lo,
	output     [15:0] scr_rdata,               // registered

	input      [15:0] reg_x, reg_y,
	input             disable_i, ls_en, flip_x, flip_y,

	input             line_start,
	input      [8:0]  render_y,
	input      [7:0]  rd_x,
	input      [8:0]  rd_y,
	output reg [12:0] pix,

	output     [23:0] rom_addr,
	input      [7:0]  rom_data_i,
	input             rom_ready_i,
	output            line_busy
);
	// ---- VRAM: two 8-bit lanes, CPU port A (write + registered read), renderer port B
	reg [7:0] vram_hi [0:2047];
	reg [7:0] vram_lo [0:2047];
	reg [7:0] vq_hi, vq_lo;
	always @(posedge clk) begin
		if (vram_we_hi) begin vram_hi[cpu_addr] <= cpu_wdata[15:8]; vq_hi <= cpu_wdata[15:8]; end else vq_hi <= vram_hi[cpu_addr];
		if (vram_we_lo) begin vram_lo[cpu_addr] <= cpu_wdata[7:0];  vq_lo <= cpu_wdata[7:0];  end else vq_lo <= vram_lo[cpu_addr];
	end
	assign vram_rdata = {vq_hi, vq_lo};
	reg  [10:0] r_vaddr;
	reg  [15:0] r_vq;
	always @(posedge clk) r_vq <= {vram_hi[r_vaddr], vram_lo[r_vaddr]};

	// ---- line scroll RAM, same shape
	reg [7:0] scr_hi [0:2047];
	reg [7:0] scr_lo [0:2047];
	reg [7:0] sq_hi, sq_lo;
	always @(posedge clk) begin
		if (scr_we_hi) begin scr_hi[cpu_addr] <= cpu_wdata[15:8]; sq_hi <= cpu_wdata[15:8]; end else sq_hi <= scr_hi[cpu_addr];
		if (scr_we_lo) begin scr_lo[cpu_addr] <= cpu_wdata[7:0];  sq_lo <= cpu_wdata[7:0];  end else sq_lo <= scr_lo[cpu_addr];
	end
	assign scr_rdata = {sq_hi, sq_lo};
	reg  [8:0]  r_saddr;
	reg  [15:0] r_sq;
	always @(posedge clk) r_sq <= {scr_hi[{2'b00, r_saddr}], scr_lo[{2'b00, r_saddr}]};

	// ---- line buffers: 2 x 256 x 13
	reg [12:0] lbuf [0:511];
	reg        lb_we;
	reg [8:0]  lb_waddr;
	reg [12:0] lb_wdata;
	always @(posedge clk) begin
		if (lb_we) lbuf[lb_waddr] <= lb_wdata;
		pix <= lbuf[{rd_y[0], rd_x}];
	end

	// ---- ROM
	wire [7:0] rom_data;
	wire       rom_ready;
	generate
	if (!HW_ROMS) begin : g_rom_sim
		reg [7:0] tiles_rom [0:TILES_BYTES-1];
		initial if (TILES_FILE != "") $readmemh(TILES_FILE, tiles_rom);
		assign rom_data  = tiles_rom[rom_addr[19:0]];
		assign rom_ready = 1'b1;
	end else begin : g_rom_hw
		assign rom_data  = rom_data_i;
		assign rom_ready = rom_ready_i;
	end
	endgenerate

	// ---- line renderer
	localparam [2:0] S_IDLE = 0, S_SCR0 = 1, S_SCR1 = 2, S_TILE0 = 3, S_TILE1 = 4, S_TILE2 = 5, S_TILE3 = 6, S_PIX = 7;
	reg [2:0]  state;
	reg        buf_sel;
	reg [8:0]  u_y;                 // unflipped tilemap row
	reg [8:0]  rs;                  // row scroll, pixels
	reg [7:0]  sx;                  // screen column being rendered
	reg [15:0] attr;
	reg [12:0] code;                // 16-bit code wrapped to 8192 tiles
	reg        dis_l;

	// The scroll word is a REGISTERED read: its address must be presented one
	// cycle before the word is used. Presenting it in S_SCR0 and consuming it in
	// S_SCR1 (as this first did) gives every row the PREVIOUS row's scroll --
	// invisible in the whole attract mode, which never enables line scroll, and
	// 22,921 wrong pixels on the first scrolling stage frame that does.
	wire [8:0]  u_y_next = flip_y ? (((reg_y >> 6) - render_y) + 9'd32) : (render_y + (reg_y >> 6));
	wire [15:0] scr_sum = reg_x + (ls_en ? r_sq : 16'd0);
	wire [8:0]  u_x = flip_x ? (rs - {1'b0, sx} - DX) : ({1'b0, sx} + rs + DX);   // mod 512
	wire [3:0]  px  = u_x[3:0] ^ {4{attr[0]}};   // tile flip X (attr bit 0)
	wire [3:0]  py  = u_y[3:0] ^ {4{attr[1]}};   // tile flip Y (attr bit 1)
	assign rom_addr = {4'd0, code, 7'd0} + {py[3], 6'd0} + {px[3], 5'd0} + {py[2:0], 2'd0} + {px[2:1]};
	wire [3:0]  nib = px[0] ? rom_data[7:4] : rom_data[3:0];  // lsb layout: even pixel = low nibble
	// tile boundary: the tile changes when u_x crosses a multiple of 16
	wire        last_in_tile = flip_x ? (u_x[3:0] == 4'd0) : (u_x[3:0] == 4'd15);
	assign line_busy = (state != S_IDLE);

	always @(posedge clk) begin
		lb_we <= 1'b0;
		if (reset) begin
			state <= S_IDLE;
		end else begin
			case (state)
			S_IDLE: if (line_start) begin
				buf_sel  <= render_y[0];
				dis_l    <= disable_i;
				u_y      <= u_y_next;
				r_saddr  <= u_y_next;        // present the scroll address now...
				state    <= S_SCR0;
			end
			S_SCR0: state <= S_SCR1;                                    // ...it lands at the end of this cycle
			S_SCR1: begin
				rs <= scr_sum[14:6];
				sx <= 8'd0;
				state <= S_TILE0;
			end
			S_TILE0: begin                                              // present the tile's attr address
				r_vaddr <= {u_y[8:4], u_x[8:4], 1'b0};
				state <= S_TILE1;
			end
			S_TILE1: begin r_vaddr <= {u_y[8:4], u_x[8:4], 1'b1}; state <= S_TILE2; end   // attr lands
			S_TILE2: begin attr <= r_vq; state <= S_TILE3; end                          // code lands next clock
			S_TILE3: begin code <= r_vq[12:0]; state <= S_PIX; end
			S_PIX: begin
				if (rom_ready || dis_l) begin
					lb_we    <= 1'b1;
					lb_waddr <= {buf_sel, sx};
					lb_wdata <= dis_l ? 13'd0 : {attr[10:8], attr[7:2], nib};
					sx <= sx + 8'd1;
					if (sx == 8'd255) state <= S_IDLE;
					else if (last_in_tile) state <= S_TILE0;
				end
			end
			default: state <= S_IDLE;
			endcase
		end
	end
endmodule
