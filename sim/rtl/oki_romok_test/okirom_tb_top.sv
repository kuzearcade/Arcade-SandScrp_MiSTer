// SS-24 / MS1-77: two jt6295s on identical commands. u_ref reads the sample
// ROM from an array; u_dut reads it through oki_rom_cache -> sdram_arb ->
// sdram -> sdram_model, sharing the arbiter with a busy Z80-like reader, as
// sandscrp_rom_hw.sv's port 3 does. The dut's cen is gated by the stall as in
// sandscrp_core.sv; its rom_ok is the cache's ready only with +define+ROMOK_GATED.
module okirom_tb_top (
	input clk, input reset,
	output sdram_ready_o,
	input  [16:0] z_addr, output [7:0] z_data, output z_ready,
	input  [24:1] w_addr, input [15:0] w_din, input w_req, output w_valid,
	input         ref_wrn, dut_wrn, input [7:0] ref_din, dut_din,
	input         run,
	output        ref_sample, dut_sample,
	output signed [13:0] ref_snd, dut_snd,
	output        dut_stall
);
	wire [15:0] SDRAM_DQ; wire [12:0] SDRAM_A; wire [1:0] SDRAM_BA;
	wire SDRAM_DQML, SDRAM_DQMH, SDRAM_nCS, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nWE, SDRAM_CLK, SDRAM_CKE, sdram_ready;
	assign sdram_ready_o = sdram_ready;
	wire [24:1] p0_addr, p1_addr; wire p0_wrl, p0_wrh, p1_wrl, p1_wrh; wire [15:0] p0_din, p1_din, p0_dout, p1_dout;
	wire [31:0] p0_pair; wire p0_req, p0_ack, p1_req, p1_ack;
	sdram sdram_inst (
		.SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
		.SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS),
		.SDRAM_nCAS(SDRAM_nCAS), .SDRAM_CLK(SDRAM_CLK), .SDRAM_CKE(SDRAM_CKE), .ready(sdram_ready),
		.init(reset), .clk(clk), .prio_mode(2'd0),
		.addr0(p0_addr), .wrl0(p0_wrl), .wrh0(p0_wrh), .din0(p0_din), .dout0(p0_dout), .dout0_pair(p0_pair), .req0(p0_req), .ack0(p0_ack),
		.addr1(p1_addr), .wrl1(p1_wrl), .wrh1(p1_wrh), .din1(p1_din), .dout1(p1_dout), .req1(p1_req), .ack1(p1_ack),
		.addr2('0), .wrl2(1'b0), .wrh2(1'b0), .din2('0), .dout2(), .req2(1'b0), .ack2(),
		.addr3('0), .wrl3(1'b0), .wrh3(1'b0), .din3('0), .dout3(), .req3(1'b0), .ack3()
	);
	sdram_model model_inst (
		.SDRAM_CLK(SDRAM_CLK), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA), .SDRAM_DQ(SDRAM_DQ),
		.SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH), .SDRAM_nCS(SDRAM_nCS),
		.SDRAM_nCAS(SDRAM_nCAS), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_CKE(SDRAM_CKE)
	);
	wire a_busy [0:1]; wire a_valid [0:1]; wire [24:1] a_addr [0:1]; wire a_req [0:1];
	wire [15:0] a_dout [0:1]; wire [31:0] a_pair [0:1];
	sdram_arb #(.N(2)) arb_inst (
		.clk(clk), .reset(reset),
		.i_addr(a_addr), .i_we('{1'b0, 1'b0}), .i_wrl('{1'b0, 1'b0}), .i_wrh('{1'b0, 1'b0}), .i_din('{16'd0, 16'd0}),
		.i_req(a_req), .i_busy(a_busy), .i_valid(a_valid), .i_dout(a_dout), .i_dout_pair(a_pair),
		.sdram_addr(p0_addr), .sdram_wrl(p0_wrl), .sdram_wrh(p0_wrh), .sdram_din(p0_din),
		.sdram_dout(p0_dout), .sdram_dout_pair(p0_pair), .sdram_req(p0_req), .sdram_ack(p0_ack)
	);
	// channel 0: Z80-like program reader at word 0x40000 (past the OKI ROM)
	rom_cache1_byte z_cache_inst (
		.base_word(23'h40000), .clk(clk), .reset(reset),
		.byte_addr({7'd0, z_addr}), .data(z_data), .ready(z_ready),
		.sd_addr(a_addr[0]), .sd_req(a_req[0]), .sd_busy(a_busy[0]), .sd_valid(a_valid[0]), .sd_dout(a_dout[0]), .sd_dout_pair(a_pair[0])
	);
	wire [17:0] dut_a; wire [7:0] dut_d; wire dut_ready;
	oki_rom_cache #(.LINES(16)) oki_cache (
		.clk(clk), .reset(reset), .base_word(23'd0),
		.byte_addr({4'd0, dut_a}), .data(dut_d), .ready(dut_ready), .stall(dut_stall),
		.sd_addr(a_addr[1]), .sd_req(a_req[1]), .sd_busy(a_busy[1]), .sd_valid(a_valid[1]), .sd_dout(a_dout[1]), .sd_dout_pair(a_pair[1])
	);
	sdram_req w_req_inst (
		.clk(clk), .reset(reset), .addr(w_addr), .we(1'b1), .wrl(1'b1), .wrh(1'b1), .din(w_din),
		.req(w_req), .busy(), .valid(w_valid), .dout(),
		.sdram_addr(p1_addr), .sdram_wrl(p1_wrl), .sdram_wrh(p1_wrh),
		.sdram_din(p1_din), .sdram_dout(p1_dout), .sdram_req(p1_req), .sdram_ack(p1_ack)
	);

	reg [4:0] oki_div = 5'd0;    // 48 MHz / 24 = 2 MHz, as sandscrp_core.sv
	always @(posedge clk) oki_div <= (oki_div == 5'd23) ? 5'd0 : oki_div + 5'd1;
	wire oki_cen = run & (oki_div == 5'd23);

	reg [7:0] rom [0:262143];
	initial $readmemh(`OKI_HEX, rom);
	wire [17:0] ref_a;
	jt6295 #(.INTERPOL(0), .SAMPLE(1)) u_ref (
		.rst(reset | ~run), .clk(clk), .cen(oki_cen), .ss(1'b1),
		.wrn(ref_wrn), .din(ref_din), .dout(),
		.rom_addr(ref_a), .rom_data(rom[ref_a]), .rom_ok(1'b1),
		.sound(ref_snd), .sample(ref_sample)
	);
`ifdef ROMOK_GATED
	wire dut_rom_ok = dut_ready;
`else
	wire dut_rom_ok = 1'b1;
`endif
	jt6295 #(.INTERPOL(0), .SAMPLE(1)) u_dut (
		.rst(reset | ~run), .clk(clk), .cen(oki_cen & ~dut_stall), .ss(1'b1),
		.wrn(dut_wrn), .din(dut_din), .dout(),
		.rom_addr(dut_a), .rom_data(dut_d), .rom_ok(dut_rom_ok),
		.sound(dut_snd), .sample(dut_sample)
	);
endmodule
