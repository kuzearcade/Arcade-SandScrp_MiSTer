// Reference simulation with the savestate engine attached: the core
// (HW_ROMS=0) plus rtl/savestate/savestate.sv against a behavioural DDR
// model, so a save/load round trip can be exercised and compared.
//
// The engine's DDR side normally runs on the framework's DDRAM clock; here it
// shares clk_sys, which is fine because the handshake between the two sides is
// a toggle either way.
module sandscrp_ref_top #(
	parameter ROM_FILE = "", parameter Z80_FILE = "",
	parameter TILES_FILE = "", parameter SPRITES_FILE = "", parameter OKI_FILE = "",
	parameter [31:0] WDOG_CYCLES = 32'd144_000_000
) (
	input         clk_sys,
	input         reset,
	input         pause,
	input  [7:0]  p1_i, p2_i, sys_i, dsw1_i, dsw2_i,
	input         osd_flip,

	// savestate control
	input         ss_save,
	input         ss_load,
	input  [1:0]  ss_slot,
	output        ss_busy,
	output        ss_done_ok,
	output        ss_done_fail,
	output [1:0]  ss_fail_code,

	output        ce_pix,
	output [8:0]  hcount, vcount,
	output        hblank, vblank, vbl_start,
	output [23:0] rd_rgb,
	output signed [15:0] snd,

	output [31:0] dbg_ym_writes, dbg_oki_writes, dbg_spr_pass_cycles, dbg_wdog_resets,
	output [15:0] dbg_spr_late_swaps, dbg_ram70,
	output [31:0] dbg_reads_rom, dbg_reads_ram, dbg_writes_ram, dbg_acc_other,
	output [23:0] dbg_last_other,

	// Readback into the DDR model, so the testbench can diff two saved images
	// word for word. A slot is SLOT_STRIDE (0x8000) 64-bit words: a control
	// word, then the image four state words to a DDR word.
	input  [16:0] dbg_ddr_addr,
	output [63:0] dbg_ddr_data
);
	localparam integer SS_WORDS = 20'h0E180;

	wire        ss_freeze, ss_frozen, ss_parked, ss_resume, ss_active, ss_wr, ss_replay, ss_replay_done;
	wire [19:0] ss_addr;
	wire [15:0] ss_rdata, ss_wdata;

	wire        ddr_we, ddr_rd;
	wire [28:0] ddr_addr;
	wire [63:0] ddr_din;
	reg  [63:0] ddr_dout = 64'd0;
	reg         ddr_ready = 1'b0;
	reg  [63:0] ddr_mem [0:131071];      // four slots
	integer di;
	initial for (di = 0; di < 131072; di = di + 1) ddr_mem[di] = 64'd0;
	wire [16:0] ddr_idx = ddr_addr[16:0];
	always @(posedge clk_sys) begin
		ddr_ready <= 1'b0;
		if (ddr_we) ddr_mem[ddr_idx] <= ddr_din;
		if (ddr_rd) begin ddr_dout <= ddr_mem[ddr_idx]; ddr_ready <= 1'b1; end
	end

	assign dbg_ddr_data = ddr_mem[dbg_ddr_addr];

	savestate #(.SS_WORDS(SS_WORDS)) ss (
		.clk(clk_sys), .reset(reset),
		.save_req(ss_save), .load_req(ss_load), .slot(ss_slot), .vblank(vblank), .allow(1'b1),
		.ss_freeze(ss_freeze), .ss_frozen(ss_frozen), .ss_parked(ss_parked),
		.ss_resume(ss_resume), .ss_active(ss_active),
		.ss_addr(ss_addr), .ss_rdata(ss_rdata), .ss_wr(ss_wr), .ss_wdata(ss_wdata),
		.ss_replay(ss_replay), .ss_replay_done(ss_replay_done),
		.busy(ss_busy), .done_ok(ss_done_ok), .done_fail(ss_done_fail), .fail_code(ss_fail_code), .was_load(),
		.clk_ddr(clk_sys), .ddr_busy(1'b0), .rot_we(1'b0),
		.ddr_we(ddr_we), .ddr_rd(ddr_rd), .ddr_addr(ddr_addr), .ddr_din(ddr_din),
		.ddr_dout(ddr_dout), .ddr_dout_ready(ddr_ready)
	);

	sandscrp_core #(.HW_ROMS(0), .ROM_FILE(ROM_FILE), .Z80_FILE(Z80_FILE),
	                .TILES_FILE(TILES_FILE), .SPRITES_FILE(SPRITES_FILE), .OKI_FILE(OKI_FILE),
	                .WDOG_CYCLES(WDOG_CYCLES)) core (
		.clk_sys(clk_sys), .reset(reset), .pause(pause),
		.p1_i(p1_i), .p2_i(p2_i), .sys_i(sys_i), .dsw1_i(dsw1_i), .dsw2_i(dsw2_i), .osd_flip(osd_flip),
		.ce_pix(ce_pix), .hcount(hcount), .vcount(vcount),
		.hblank(hblank), .vblank(vblank), .vbl_start(vbl_start), .rd_rgb(rd_rgb), .snd(snd),
		.rom0_addr(), .rom1_addr(), .roms_addr(), .okirom_addr(),
		.rom0_data(8'd0), .rom1_data(8'd0), .roms_data(8'd0), .okirom_data(8'd0),
		.rom0_ready(1'b1), .rom1_ready(1'b1), .roms_ready(1'b1),
		.prog_word_addr(), .prog_word_data(16'd0), .prog_ready(1'b1),
		.z80rom_addr(), .z80rom_data(8'd0), .z80rom_ready(1'b1), .okirom_stall(1'b0),
		.ss_freeze(ss_freeze), .ss_resume(ss_resume), .ss_active(ss_active),
		.ss_frozen(ss_frozen), .ss_parked(ss_parked),
		.ss_addr(ss_addr), .ss_rdata(ss_rdata), .ss_wr(ss_wr), .ss_wdata(ss_wdata),
		.ss_replay(ss_replay), .ss_replay_done(ss_replay_done),
		.dbg_m68k_pc_addr(), .dbg_ym_writes(dbg_ym_writes), .dbg_oki_writes(dbg_oki_writes),
		.dbg_spr_pass_cycles(dbg_spr_pass_cycles), .dbg_spr_late_swaps(dbg_spr_late_swaps),
		.dbg_wdog_resets(dbg_wdog_resets), .dbg_ym_snd(), .dbg_oki_snd(),
		.dbg_ram70(dbg_ram70), .dbg_reads_rom(dbg_reads_rom), .dbg_reads_ram(dbg_reads_ram),
		.dbg_writes_ram(dbg_writes_ram), .dbg_acc_other(dbg_acc_other), .dbg_last_other(dbg_last_other)
	);
endmodule
