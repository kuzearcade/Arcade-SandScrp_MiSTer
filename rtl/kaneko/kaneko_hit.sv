// Kaneko CALC1 (40-pin DIP ULA, no internal ROM), the `kaneko_hit` type 0 of
// MAME kaneko/kaneko_hit.cpp: eight rectangle registers, a 16x16 multiplier
// and a random source, behind ten word registers at 0x200000.
//
// MAME's own note calls Sand Scorpion a set that "only uses Random Number?".
// Measured over 9,000 attract frames, that is backwards: the game reads the
// COLLISION word 257,177 times (28.6 per frame) and the random word 94 times
// in all, and never touches the multiplier. The collision logic is what makes
// shots hit, so it is transcribed exactly, signedness included.
//
// Writes (offset = A4..A1), `data &= mem_mask` as in the device, so a byte
// write stores only that lane and zeroes the other:
//   0 x1p   1 x1s   2 y1p   3 y1s   4 x2p   5 x2s   6 y2p   7 y2s
//   8 mult_a   9 mult_b
// Reads:
//   0  watchdog reset, returns 0
//   1  unknown, returns 0
//   2  collision:
//        bits 9/10/11  x1p >/==/< x2p    UNSIGNED compares (uint16_t fields)
//        bits 13/14/15 y1p >/==/< y2p
//        bit 0         the two rectangles overlap, from four differences
//                      truncated to int16_t and tested for sign:
//                        x12 = x1p - (x2p + x2s)   < 0
//                        y12 = y1p - (y2p + y2s)   < 0
//                        x21 = (x1p + x1s) - x2p  >= 0
//                        y21 = (y1p + y1s) - y2p  >= 0
//   8  product >> 16    9  product & 0xffff   (unsigned 16 x 16)
//   A  random
// Anything else reads 0 (MAME logs and returns its `data`, which is 0 there).
//
// The random source is a 32-bit maximal LFSR clocked every cycle; MAME uses
// its host RNG, so this cannot match cycle for cycle and does not try to.
module kaneko_hit (
	input             clk,
	input             reset,
	input      [3:0]  addr,          // A4..A1
	input      [15:0] din,
	input             we_hi,         // UDS
	input             we_lo,         // LDS
	input             rd,            // a read is happening this cycle (for the watchdog strobe)
	output reg [15:0] dout,          // registered, valid the clock after addr
	output            watchdog_strobe
);
	reg [15:0] x1p, x1s, y1p, y1s, x2p, x2s, y2p, y2s, mult_a, mult_b;
	reg [31:0] lfsr;

	wire [15:0] wdata = {we_hi ? din[15:8] : 8'h00, we_lo ? din[7:0] : 8'h00};  // data &= mem_mask
	wire        we    = we_hi | we_lo;

	// collision word
	wire [15:0] x12 = x1p - (x2p + x2s);
	wire [15:0] y12 = y1p - (y2p + y2s);
	wire [15:0] x21 = (x1p + x1s) - x2p;
	wire [15:0] y21 = (y1p + y1s) - y2p;
	wire        overlap = x12[15] & y12[15] & ~x21[15] & ~y21[15];
	wire [15:0] collide = {(y1p <  y2p), (y1p == y2p), (y1p >  y2p), 1'b0,
	                       (x1p <  x2p), (x1p == x2p), (x1p >  x2p), 1'b0,
	                       7'd0, overlap};
	wire [31:0] product = mult_a * mult_b;

	assign watchdog_strobe = rd & (addr == 4'd0);

	always @(posedge clk) begin
		if (reset) begin
			{x1p, x1s, y1p, y1s, x2p, x2s, y2p, y2s, mult_a, mult_b} <= 160'd0;
			lfsr <= 32'h1234_5678;
		end else begin
			lfsr <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
			if (we) case (addr)
				4'd0: x1p <= wdata;  4'd1: x1s <= wdata;
				4'd2: y1p <= wdata;  4'd3: y1s <= wdata;
				4'd4: x2p <= wdata;  4'd5: x2s <= wdata;
				4'd6: y2p <= wdata;  4'd7: y2s <= wdata;
				4'd8: mult_a <= wdata; 4'd9: mult_b <= wdata;
				default: ;
			endcase
		end
		case (addr)
			4'd2:    dout <= collide;
			4'd8:    dout <= product[31:16];
			4'd9:    dout <= product[15:0];
			4'd10:   dout <= lfsr[15:0];
			default: dout <= 16'd0;
		endcase
	end
endmodule
