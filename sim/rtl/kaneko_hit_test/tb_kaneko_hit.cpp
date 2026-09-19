// CALC1 (kaneko_hit type 0) against a direct transcription of MAME's own
// kaneko_hit_type0_r/w. Random rectangles, including the cases that decide
// the signedness questions: values straddling 0x8000, sums that overflow 16
// bits, and equal coordinates.
//
// This matters more than MAME's own comment suggests. Measured over 9,000
// attract frames, Sand Scorpion reads the collision word 257,177 times and
// the random word 94 times; the comment says it "only uses Random Number?".
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include "Vkaneko_hit_test_top.h"
#include "verilated.h"

struct Hit { uint16_t x1p, x1s, y1p, y1s, x2p, x2s, y2p, y2s, mult_a, mult_b; };

// kaneko_hit.cpp, case 0x04/2 -- fields are uint16_t, the four differences
// int16_t, so the compares are UNSIGNED and the overlap test is on the sign
// of a 16-bit truncation.
static uint16_t mame_collide(const Hit &h) {
	uint16_t data = 0;
	if      (h.x1p >  h.x2p) data |= 0x0200;
	else if (h.x1p == h.x2p) data |= 0x0400;
	else if (h.x1p <  h.x2p) data |= 0x0800;
	if      (h.y1p >  h.y2p) data |= 0x2000;
	else if (h.y1p == h.y2p) data |= 0x4000;
	else if (h.y1p <  h.y2p) data |= 0x8000;
	int16_t x12 = (int16_t)(h.x1p - (uint16_t)(h.x2p + h.x2s));
	int16_t y12 = (int16_t)(h.y1p - (uint16_t)(h.y2p + h.y2s));
	int16_t x21 = (int16_t)((uint16_t)(h.x1p + h.x1s) - h.x2p);
	int16_t y21 = (int16_t)((uint16_t)(h.y1p + h.y1s) - h.y2p);
	if (x12 < 0 && y12 < 0 && x21 >= 0 && y21 >= 0) data |= 0x0001;
	return data;
}

int main(int argc, char **argv) {
	VerilatedContext ctx; ctx.commandArgs(argc, argv);
	Vkaneko_hit_test_top top{&ctx};
	auto tick = [&]() { top.clk = 0; top.eval(); top.clk = 1; top.eval(); };
	top.reset = 1; top.we_hi = top.we_lo = top.rd = 0; top.addr = 0; top.din = 0;
	for (int i = 0; i < 4; i++) tick();
	top.reset = 0;

	auto wr = [&](int a, uint16_t v) {
		top.addr = a; top.din = v; top.we_hi = 1; top.we_lo = 1; tick();
		top.we_hi = top.we_lo = 0;
	};
	auto rd = [&](int a) -> uint16_t {
		top.addr = a; top.rd = 1; tick(); top.rd = 0; top.eval(); return top.dout;
	};

	srand(12345);
	long n = 0, bad_coll = 0, bad_mul = 0;
	auto rnd16 = [&]() -> uint16_t {
		int k = rand() % 6;
		if (k == 0) return 0;
		if (k == 1) return 0xFFFF;
		if (k == 2) return 0x8000 + (rand() & 0xF);       // around the sign boundary
		if (k == 3) return 0x7FFF - (rand() & 0xF);
		return (uint16_t)(rand() & 0xFFFF);
	};
	for (int trial = 0; trial < 200000; trial++) {
		Hit h;
		h.x1p = rnd16(); h.x1s = rnd16(); h.y1p = rnd16(); h.y1s = rnd16();
		h.x2p = rnd16(); h.x2s = rnd16(); h.y2p = rnd16(); h.y2s = rnd16();
		h.mult_a = rnd16(); h.mult_b = rnd16();
		if ((trial % 7) == 0) h.x2p = h.x1p;           // force the "equal" branches
		if ((trial % 11) == 0) h.y2p = h.y1p;
		wr(0, h.x1p); wr(1, h.x1s); wr(2, h.y1p); wr(3, h.y1s);
		wr(4, h.x2p); wr(5, h.x2s); wr(6, h.y2p); wr(7, h.y2s);
		wr(8, h.mult_a); wr(9, h.mult_b);
		uint16_t got = rd(2), want = mame_collide(h);
		if (got != want) {
			if (bad_coll < 5)
				printf("MISMATCH collide: x1p=%04x x1s=%04x y1p=%04x y1s=%04x x2p=%04x x2s=%04x y2p=%04x y2s=%04x -> rtl %04x mame %04x\n",
				       h.x1p, h.x1s, h.y1p, h.y1s, h.x2p, h.x2s, h.y2p, h.y2s, got, want);
			bad_coll++;
		}
		uint32_t prod = (uint32_t)h.mult_a * (uint32_t)h.mult_b;
		uint16_t hi = rd(8), lo = rd(9);
		if (hi != (uint16_t)(prod >> 16) || lo != (uint16_t)prod) {
			if (bad_mul < 5) printf("MISMATCH mult: %04x * %04x -> rtl %04x%04x mame %08x\n", h.mult_a, h.mult_b, hi, lo, prod);
			bad_mul++;
		}
		n++;
	}
	// the random word must not be constant, and register 0 must strobe the watchdog
	uint16_t r0 = rd(10), r1 = rd(10), r2 = rd(10);
	int distinct = (r0 != r1) + (r1 != r2);
	top.addr = 0; top.rd = 1; top.eval();
	int wd = top.watchdog_strobe;
	top.rd = 0; top.eval();
	printf("%ld cases: %ld collision mismatches, %ld multiply mismatches; random %04x %04x %04x (%s); watchdog strobe on register 0: %s\n",
	       n, bad_coll, bad_mul, r0, r1, r2, distinct ? "varying" : "CONSTANT", wd ? "yes" : "NO");
	bool ok = (bad_coll == 0) && (bad_mul == 0) && distinct && wd;
	printf("%s\n", ok ? "PASS" : "FAIL");
	return ok ? 0 : 1;
}
