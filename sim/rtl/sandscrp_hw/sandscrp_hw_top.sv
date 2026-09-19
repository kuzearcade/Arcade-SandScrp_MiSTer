// Hardware-path simulation: sandscrp_core with HW_ROMS=1, every ROM byte
// coming out of the real rtl/sdram.sv talking to sim/models/sdram_model.sv,
// filled by a real ioctl_download byte stream -- the same bytes, in the same
// order, that the .mra loader sends on the board.
//
// The stream arrives in LOADER ORDER from the start (index 0, then anything
// else, then the <switches> block on index 254 LAST), because that is the
// order the real loader uses and any decision taken while a ROM streams sees
// the switches at their idle value. NMK16 shipped a bug that every simulation
// passed and the board failed, for exactly this reason.
module sandscrp_hw_top #(
	parameter [31:0] WDOG_CYCLES = 32'd144_000_000
) (
	input         clk_sys,        // 48 MHz
	input         clk_ram,        // SDRAM controller clock
	input         reset,
	input         pause,

	input  [7:0]  p1_i, p2_i, sys_i, dsw1_i, dsw2_i,
	input         osd_flip,

	// ioctl download
	input         ioctl_download,
	input         ioctl_wr,
	input  [24:0] ioctl_addr,
	input  [7:0]  ioctl_dout,
	input  [15:0] ioctl_index,

	output        ce_pix,
	output [8:0]  hcount, vcount,
	output        hblank, vblank, vbl_start,
	output [23:0] rd_rgb,
	output signed [15:0] snd,

	output        sdram_ready,
	output [31:0] dbg_ym_writes, dbg_oki_writes, dbg_spr_pass_cycles, dbg_wdog_resets,
	output [15:0] dbg_spr_late_swaps,
	output [31:0] dbg_oki_unserved,
	output [31:0] dbg_reads_rom, dbg_reads_ram, dbg_writes_ram, dbg_acc_other,
	output [15:0] dbg_ram70
);
	wire [15:0] SDRAM_DQ;
	wire [12:0] SDRAM_A;
	wire [1:0]  SDRAM_BA;
	wire        SDRAM_DQML, SDRAM_DQMH, SDRAM_nCS, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nWE, SDRAM_CLK, SDRAM_CKE;

	wire [24:1] p0_addr, p1_addr, p2_addr, p3_addr;
	wire        p0_wrl, p0_wrh;
	wire [15:0] p0_din;
	wire [15:0] p0_dout, p1_dout, p2_dout, p3_dout;
	wire [31:0] p0_dout_pair, p1_dout_pair, p2_dout_pair, p3_dout_pair;
	wire        p0_req, p1_req, p2_req, p3_req, p0_ack, p1_ack, p2_ack, p3_ack;

	sdram #(.REFRESH_CYCLES(10'd740)) sdram_inst (
		.SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
		.SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS),
		.SDRAM_nCAS(SDRAM_nCAS), .SDRAM_CLK(SDRAM_CLK), .SDRAM_CKE(SDRAM_CKE), .ready(sdram_ready),
		.init(reset), .clk(clk_ram), .prio_mode(2'd0),
		.addr0(p0_addr), .wrl0(p0_wrl), .wrh0(p0_wrh), .din0(p0_din), .dout0(p0_dout), .dout0_pair(p0_dout_pair), .req0(p0_req), .ack0(p0_ack),
		.addr1(p1_addr), .wrl1(1'b0), .wrh1(1'b0), .din1('0), .dout1(p1_dout), .dout1_pair(p1_dout_pair), .req1(p1_req), .ack1(p1_ack),
		.addr2(p2_addr), .wrl2(1'b0), .wrh2(1'b0), .din2('0), .dout2(p2_dout), .dout2_pair(p2_dout_pair), .req2(p2_req), .ack2(p2_ack),
		.addr3(p3_addr), .wrl3(1'b0), .wrh3(1'b0), .din3('0), .dout3(p3_dout), .dout3_pair(p3_dout_pair), .req3(p3_req), .ack3(p3_ack)
	);
	sdram_model model_inst (
		.SDRAM_CLK(SDRAM_CLK), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA), .SDRAM_DQ(SDRAM_DQ),
		.SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH), .SDRAM_nCS(SDRAM_nCS),
		.SDRAM_nCAS(SDRAM_nCAS), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_CKE(SDRAM_CKE)
	);

	wire [22:0] prog_word_addr; wire [15:0] prog_word_data; wire prog_ready;
	wire [16:0] z80rom_addr;    wire [7:0]  z80rom_data;    wire z80rom_ready;
	wire [23:0] roms_addr, rom0_addr, rom1_addr, okirom_addr;
	wire [7:0]  roms_data, rom0_data, rom1_data, okirom_data;
	wire        roms_ready, rom0_ready, rom1_ready, okirom_stall;

	sandscrp_rom_hw rom_hw (
		.clk(clk_sys), .reset(reset),
		.ioctl_download(ioctl_download), .ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr),
		.ioctl_dout(ioctl_dout), .ioctl_index(ioctl_index), .ioctl_wait(),
		.prog_word_addr(prog_word_addr), .prog_word_data(prog_word_data), .prog_ready(prog_ready),
		.z80rom_addr(z80rom_addr), .z80rom_data(z80rom_data), .z80rom_ready(z80rom_ready),
		.roms_addr(roms_addr), .roms_data(roms_data), .roms_ready(roms_ready),
		.rom0_addr(rom0_addr), .rom1_addr(rom1_addr), .rom0_data(rom0_data), .rom1_data(rom1_data),
		.rom0_ready(rom0_ready), .rom1_ready(rom1_ready),
		.okirom_addr(okirom_addr), .okirom_data(okirom_data), .okirom_stall(okirom_stall),
		.sd_addr0(p0_addr), .sd_addr1(p1_addr), .sd_addr2(p2_addr), .sd_addr3(p3_addr),
		.sd_wrl0(p0_wrl), .sd_wrh0(p0_wrh), .sd_din0(p0_din),
		.sd_req0(p0_req), .sd_req1(p1_req), .sd_req2(p2_req), .sd_req3(p3_req),
		.sd_ack0(p0_ack), .sd_ack1(p1_ack), .sd_ack2(p2_ack), .sd_ack3(p3_ack),
		.sd_dout0(p0_dout), .sd_dout1(p1_dout), .sd_dout2(p2_dout), .sd_dout3(p3_dout),
		.sd_dout0_pair(p0_dout_pair), .sd_dout1_pair(p1_dout_pair),
		.sd_dout2_pair(p2_dout_pair), .sd_dout3_pair(p3_dout_pair),
		.dbg_oki_unserved(dbg_oki_unserved)
	);

	// The CPUs stay in reset for the whole download and until the controller
	// reports ready, so no cache can be asked for a byte that is not there yet.
	wire core_reset = reset | ioctl_download | ~sdram_ready;

	sandscrp_core #(.HW_ROMS(1), .WDOG_CYCLES(WDOG_CYCLES)) core (
		.clk_sys(clk_sys), .reset(core_reset), .pause(pause),
		.p1_i(p1_i), .p2_i(p2_i), .sys_i(sys_i), .dsw1_i(dsw1_i), .dsw2_i(dsw2_i),
		.osd_flip(osd_flip),
		.ce_pix(ce_pix), .hcount(hcount), .vcount(vcount),
		.hblank(hblank), .vblank(vblank), .vbl_start(vbl_start), .rd_rgb(rd_rgb), .snd(snd),
		.rom0_addr(rom0_addr), .rom1_addr(rom1_addr), .roms_addr(roms_addr), .okirom_addr(okirom_addr),
		.rom0_data(rom0_data), .rom1_data(rom1_data), .roms_data(roms_data), .okirom_data(okirom_data),
		.rom0_ready(rom0_ready), .rom1_ready(rom1_ready), .roms_ready(roms_ready),
		.prog_word_addr(prog_word_addr), .prog_word_data(prog_word_data), .prog_ready(prog_ready),
		.z80rom_addr(z80rom_addr), .z80rom_data(z80rom_data), .z80rom_ready(z80rom_ready),
		.okirom_stall(okirom_stall),
		.dbg_m68k_pc_addr(), .dbg_ym_writes(dbg_ym_writes), .dbg_oki_writes(dbg_oki_writes),
		.dbg_spr_pass_cycles(dbg_spr_pass_cycles), .dbg_spr_late_swaps(dbg_spr_late_swaps),
		.dbg_wdog_resets(dbg_wdog_resets), .dbg_ym_snd(), .dbg_oki_snd(),
		.dbg_ram70(dbg_ram70), .dbg_reads_rom(dbg_reads_rom), .dbg_reads_ram(dbg_reads_ram),
		.dbg_writes_ram(dbg_writes_ram), .dbg_acc_other(dbg_acc_other), .dbg_last_other()
	);
endmodule
