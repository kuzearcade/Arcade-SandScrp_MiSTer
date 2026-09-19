// Wrapper so the testbench can drive rtl/kaneko/kaneko_hit.sv's word registers
// directly and read the result a clock later.
module kaneko_hit_test_top (
	input         clk,
	input         reset,
	input  [3:0]  addr,
	input  [15:0] din,
	input         we_hi, we_lo,
	input         rd,
	output [15:0] dout,
	output        watchdog_strobe
);
	kaneko_hit dut (
		.clk(clk), .reset(reset), .addr(addr), .din(din),
		.we_hi(we_hi), .we_lo(we_lo), .rd(rd), .dout(dout), .watchdog_strobe(watchdog_strobe)
	);
endmodule
