// SDRAM side of the board: the six ROM consumers of sandscrp_core, their
// caches, and the ioctl download path, across rtl/sdram.sv's four ports.
//
// Region layout (one source of truth: tools/gen_sandscrp_mra.py, which writes
// the .mra, the ioctl stream and the simulation images from the same table):
//
//   maincpu   0x000000  0x080000   68000 program, word reads
//   audiocpu  0x080000  0x020000   Z80 program, byte reads
//   sprites   0x0A0000  0x100000   PANDORA tiles, byte reads
//   view2     0x1A0000  0x100000   VIEW2 tiles, byte reads (both layers)
//   oki       0x2A0000  0x040000   ADPCM samples, byte reads
//   end       0x2E0000
//
// Ports:
//   0  ioctl writes, then the 68000 program cache (never both: the CPU is
//      held in reset for the whole download)
//   1  sprite bytes, alone -- the draw pass is the heaviest single consumer
//   2  the two VIEW2 layers, round-robin
//   3  Z80 program and OKI samples, round-robin
//
// Why plain one-pair caches suffice for the tile layers, where the NMK16
// cores need a 16-pixel lookahead prefetcher: those render straight into the
// raster, so a fetch has one pixel of slack. This chip renders a whole line
// AHEAD into a line buffer, so a layer has a full line -- 3,072 clk_sys
// cycles -- to pull the 32 four-byte groups its 256 pixels need, about 640
// cycles' worth. The prefetcher would buy nothing.
//
// ioctl: every SDRAM write is gated on ioctl_index == 0. The .mra loader
// sends the <switches> block as a SECOND session on index 254 with its own
// addresses restarting at 0; ungated, that block lands on the 68000's reset
// vector. This was NMK16's first black screen and a week of SDRAM theories.
module sandscrp_rom_hw (
	input             clk,
	input             reset,

	// ioctl download (index 0 only)
	input             ioctl_download,
	input             ioctl_wr,
	input      [24:0] ioctl_addr,
	input      [7:0]  ioctl_dout,
	input      [15:0] ioctl_index,
	output            ioctl_wait,

	// consumer side -- the core's own ROM ports
	input      [22:0] prog_word_addr,
	output     [15:0] prog_word_data,
	output            prog_ready,
	input      [16:0] z80rom_addr,
	output     [7:0]  z80rom_data,
	output            z80rom_ready,
	input      [23:0] roms_addr,           // sprites
	output     [7:0]  roms_data,
	output            roms_ready,
	input      [23:0] rom0_addr, rom1_addr, // VIEW2 layer 0 / layer 1
	output     [7:0]  rom0_data, rom1_data,
	output            rom0_ready, rom1_ready,
	input      [23:0] okirom_addr,
	output     [7:0]  okirom_data,
	output            okirom_stall,

	// rtl/sdram.sv ports
	output     [24:1] sd_addr0, sd_addr1, sd_addr2, sd_addr3,
	output            sd_wrl0, sd_wrh0,
	output     [15:0] sd_din0,
	output            sd_req0, sd_req1, sd_req2, sd_req3,
	input             sd_ack0, sd_ack1, sd_ack2, sd_ack3,
	input      [15:0] sd_dout0, sd_dout1, sd_dout2, sd_dout3,
	input      [31:0] sd_dout0_pair, sd_dout1_pair, sd_dout2_pair, sd_dout3_pair,

	// audits
	output     [31:0] dbg_oki_unserved
);
	localparam [22:0] BASE_PROG = 23'h000000 >> 1;
	localparam [22:0] BASE_Z80  = 23'h080000 >> 1;
	localparam [22:0] BASE_SPR  = 23'h0A0000 >> 1;
	localparam [22:0] BASE_V2   = 23'h1A0000 >> 1;
	localparam [22:0] BASE_OKI  = 23'h2A0000 >> 1;

	// ---------------------------------------------------------------- port 0
	// The download owns the port while it runs; the cache owns it afterwards.
	wire dl_active = ioctl_download & (ioctl_index == 16'd0);
	reg        dl_req;
	reg [24:1] dl_addr;
	reg [15:0] dl_din;
	reg        dl_wrl, dl_wrh;
	always @(posedge clk) begin
		dl_req <= 1'b0;
		if (dl_active & ioctl_wr) begin
			// bytes arrive in stream order; even addresses are the LOW byte of
			// the word, which is what rebuilds ROM_LOAD16_BYTE pairs streamed
			// with the odd-offset file first (see the .mra generator)
			dl_addr <= ioctl_addr[24:1];
			dl_din  <= {ioctl_dout, ioctl_dout};
			dl_wrl  <= ~ioctl_addr[0];
			dl_wrh  <=  ioctl_addr[0];
			dl_req  <= 1'b1;
		end
	end
	assign ioctl_wait = 1'b0;    // one write per byte at the loader's pace; the port keeps up

	wire [24:1] pc_addr;
	wire        pc_req;
	rom_cache_n #(.LINES(16), .PREFETCH(1), .LAST_PAIR(22'h01FFFF)) prog_cache (
		.clk(clk), .reset(reset),
		.addr(prog_word_addr), .data(prog_word_data), .ready(prog_ready),
		.sd_addr(pc_addr), .sd_req(pc_req), .sd_busy(dl_active), .sd_valid(sd_ack0 & ~dl_active),
		.sd_dout(sd_dout0), .sd_dout_pair(sd_dout0_pair)
	);
	assign sd_addr0 = dl_active ? dl_addr : pc_addr;
	assign sd_req0  = dl_active ? dl_req  : pc_req;
	assign sd_wrl0  = dl_active & dl_wrl;
	assign sd_wrh0  = dl_active & dl_wrh;
	assign sd_din0  = dl_din;

	// ---------------------------------------------------------------- port 1
	rom_cache_n_byte #(.LINES(8), .PREFETCH(1)) spr_cache (
		.clk(clk), .reset(reset),
		.base_word(BASE_SPR), .byte_addr(roms_addr), .data(roms_data), .word(), .ready(roms_ready),
		.sd_addr(sd_addr1), .sd_req(sd_req1), .sd_busy(1'b0), .sd_valid(sd_ack1),
		.sd_dout(sd_dout1), .sd_dout_pair(sd_dout1_pair)
	);

	// ---------------------------------------------------------------- port 2
	wire [24:1] v2a [0:1];
	wire        v2r [0:1], v2b [0:1], v2v [0:1];
	wire [15:0] v2d [0:1];
	wire [31:0] v2p [0:1];
	rom_cache1_byte v2_l0 (
		.clk(clk), .reset(reset), .base_word(BASE_V2), .byte_addr(rom0_addr),
		.data(rom0_data), .word(), .ready(rom0_ready),
		.sd_addr(v2a[0]), .sd_req(v2r[0]), .sd_busy(v2b[0]), .sd_valid(v2v[0]),
		.sd_dout(v2d[0]), .sd_dout_pair(v2p[0])
	);
	rom_cache1_byte v2_l1 (
		.clk(clk), .reset(reset), .base_word(BASE_V2), .byte_addr(rom1_addr),
		.data(rom1_data), .word(), .ready(rom1_ready),
		.sd_addr(v2a[1]), .sd_req(v2r[1]), .sd_busy(v2b[1]), .sd_valid(v2v[1]),
		.sd_dout(v2d[1]), .sd_dout_pair(v2p[1])
	);
	wire [24:1] arb2_i_addr [0:1]; wire arb2_i_we [0:1], arb2_i_wrl [0:1], arb2_i_wrh [0:1];
	wire [15:0] arb2_i_din [0:1];
	assign arb2_i_addr[0] = v2a[0]; assign arb2_i_addr[1] = v2a[1];
	assign arb2_i_we[0] = 1'b0; assign arb2_i_we[1] = 1'b0;
	assign arb2_i_wrl[0] = 1'b0; assign arb2_i_wrl[1] = 1'b0;
	assign arb2_i_wrh[0] = 1'b0; assign arb2_i_wrh[1] = 1'b0;
	assign arb2_i_din[0] = 16'd0; assign arb2_i_din[1] = 16'd0;
	wire arb2_req [0:1]; assign arb2_req[0] = v2r[0]; assign arb2_req[1] = v2r[1];
	wire arb2_busy [0:1]; assign v2b[0] = arb2_busy[0]; assign v2b[1] = arb2_busy[1];
	wire arb2_valid [0:1]; assign v2v[0] = arb2_valid[0]; assign v2v[1] = arb2_valid[1];
	wire [15:0] arb2_dout [0:1]; assign v2d[0] = arb2_dout[0]; assign v2d[1] = arb2_dout[1];
	wire [31:0] arb2_pair [0:1]; assign v2p[0] = arb2_pair[0]; assign v2p[1] = arb2_pair[1];
	sdram_arb #(.N(2)) arb_tiles (
		.clk(clk), .reset(reset),
		.i_addr(arb2_i_addr), .i_we(arb2_i_we), .i_wrl(arb2_i_wrl), .i_wrh(arb2_i_wrh), .i_din(arb2_i_din),
		.i_req(arb2_req), .i_busy(arb2_busy), .i_valid(arb2_valid), .i_dout(arb2_dout), .i_dout_pair(arb2_pair),
		.sdram_addr(sd_addr2), .sdram_wrl(), .sdram_wrh(), .sdram_din(),
		.sdram_dout(sd_dout2), .sdram_dout_pair(sd_dout2_pair), .sdram_req(sd_req2), .sdram_ack(sd_ack2)
	);

	// ---------------------------------------------------------------- port 3
	wire [24:1] z3a, o3a;
	wire        z3r, z3b, z3v, o3r, o3b, o3v;
	wire [15:0] z3d, o3d;
	wire [31:0] z3p, o3p;
	rom_cache1_byte z80_cache (
		.clk(clk), .reset(reset), .base_word(BASE_Z80), .byte_addr({7'd0, z80rom_addr}),
		.data(z80rom_data), .word(), .ready(z80rom_ready),
		.sd_addr(z3a), .sd_req(z3r), .sd_busy(z3b), .sd_valid(z3v), .sd_dout(z3d), .sd_dout_pair(z3p)
	);
	oki_rom_cache #(.LINES(16)) oki_cache (
		.clk(clk), .reset(reset), .base_word(BASE_OKI), .byte_addr(okirom_addr[21:0]),
		.data(okirom_data), .ready(), .stall(okirom_stall),
		.sd_addr(o3a), .sd_req(o3r), .sd_busy(o3b), .sd_valid(o3v), .sd_dout(o3d), .sd_dout_pair(o3p)
	);
	wire [24:1] arb3_i_addr [0:1]; wire arb3_i_we [0:1], arb3_i_wrl [0:1], arb3_i_wrh [0:1];
	wire [15:0] arb3_i_din [0:1];
	assign arb3_i_addr[0] = z3a; assign arb3_i_addr[1] = o3a;
	assign arb3_i_we[0] = 1'b0; assign arb3_i_we[1] = 1'b0;
	assign arb3_i_wrl[0] = 1'b0; assign arb3_i_wrl[1] = 1'b0;
	assign arb3_i_wrh[0] = 1'b0; assign arb3_i_wrh[1] = 1'b0;
	assign arb3_i_din[0] = 16'd0; assign arb3_i_din[1] = 16'd0;
	wire arb3_req [0:1]; assign arb3_req[0] = z3r; assign arb3_req[1] = o3r;
	wire arb3_busy [0:1]; assign z3b = arb3_busy[0]; assign o3b = arb3_busy[1];
	wire arb3_valid [0:1]; assign z3v = arb3_valid[0]; assign o3v = arb3_valid[1];
	wire [15:0] arb3_dout [0:1]; assign z3d = arb3_dout[0]; assign o3d = arb3_dout[1];
	wire [31:0] arb3_pair [0:1]; assign z3p = arb3_pair[0]; assign o3p = arb3_pair[1];
	sdram_arb #(.N(2)) arb_snd (
		.clk(clk), .reset(reset),
		.i_addr(arb3_i_addr), .i_we(arb3_i_we), .i_wrl(arb3_i_wrl), .i_wrh(arb3_i_wrh), .i_din(arb3_i_din),
		.i_req(arb3_req), .i_busy(arb3_busy), .i_valid(arb3_valid), .i_dout(arb3_dout), .i_dout_pair(arb3_pair),
		.sdram_addr(sd_addr3), .sdram_wrl(), .sdram_wrh(), .sdram_din(),
		.sdram_dout(sd_dout3), .sdram_dout_pair(sd_dout3_pair), .sdram_req(sd_req3), .sdram_ack(sd_ack3)
	);

	// Sample bytes the OKI consumed while its cache was stalling -- the audit
	// NMK16 needed to find 37.6% stale bytes. Should stay at 0.
	reg [31:0] unserved;
	always @(posedge clk) if (reset) unserved <= 32'd0; else if (okirom_stall) unserved <= unserved + 32'd1;
	assign dbg_oki_unserved = unserved;
endmodule
