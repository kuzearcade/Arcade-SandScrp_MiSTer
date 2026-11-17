// SS-24 regression test: a cache-fed jt6295 must match an array-fed one
// sample for sample. See this directory's Makefile and docs/known-issues.md SS-24.
// Drives okirom_tb_top: preload the OKI ROM into SDRAM, then start phrases on
// both chips at identical SAMPLE indices of each chip, and compare outputs.
#include "Vokirom_tb_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <vector>
#include <string>
#include <cmath>
#include <algorithm>
static Vokirom_tb_top *t; static uint64_t cyc = 0;
static uint32_t z_pc = 0;
static void tick() {
	t->clk = 0; t->eval(); t->clk = 1; t->eval(); cyc++;
	if (t->z_ready && (cyc % 24) == 0) {   // Z80-ish contention on the arbiter
		z_pc = (rand() % 8 == 0) ? (rand() % 0x20000) : ((z_pc + 1) & 0x1FFFF);
		t->z_addr = z_pc;
	}
}
int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	const char *hex = argv[1]; long nsamp = atol(argv[2]);
	std::vector<uint8_t> rom;
	{ FILE *f = fopen(hex, "r"); unsigned v; while (fscanf(f, "%x", &v) == 1) rom.push_back(v); fclose(f); }
	rom.resize(262144, 0);
	// valid phrases: start < stop, both inside the ROM, past the table
	std::vector<int> ph;
	for (int p = 1; p < 128; p++) {
		uint32_t s = (rom[p*8] << 16 | rom[p*8+1] << 8 | rom[p*8+2]) & 0x3FFFF;
		uint32_t e = (rom[p*8+3] << 16 | rom[p*8+4] << 8 | rom[p*8+5]) & 0x3FFFF;
		if (s >= 0x400 && e > s) ph.push_back(p);
	}
	printf("valid phrases: %zu\n", ph.size());
	t = new Vokirom_tb_top;
	t->reset = 1; t->run = 0; t->ref_wrn = 1; t->dut_wrn = 1; t->w_req = 0;
	for (int i = 0; i < 20; i++) tick();
	t->reset = 0;
	while (!t->sdram_ready_o) tick();
	for (int a = 0; a < 131072; a++) {
		t->w_addr = a; t->w_din = rom[2*a] | (rom[2*a+1] << 8); t->w_req = 1; t->eval();
		while (!t->w_valid) tick();
		t->w_req = 0; tick();
	}
	printf("preloaded 256 KB\n");
	// schedule: every 150 samples, start a random phrase on the next channel
	struct Cmd { long at; uint8_t b0, b1; };
	std::vector<Cmd> cmds; srand(7);
	for (long k = 50, c = 0; k < nsamp; k += 150, c++) {
		int p = ph[rand() % ph.size()];
		cmds.push_back({k, (uint8_t)(0x80 | p), (uint8_t)((0x10 << (c & 3)) | 0)});
	}
	std::vector<int> rs, ds; size_t ri = 0, di = 0;
	int rpend = 0, dpend = 0;   // 2 = send b0 next, 1 = send b1 next
	long rsent_at = 0, dsent_at = 0; long stall_cyc = 0;
	t->run = 1;
	while ((long)ds.size() < nsamp) {
		tick();
		if (t->dut_stall) stall_cyc++;
		// one strobe per chip per call, 6 clocks apart
		auto drive = [&](bool isref) {
			auto &q = isref ? ri : di; auto &pend = isref ? rpend : dpend; auto &at = isref ? rsent_at : dsent_at;
			long n = isref ? rs.size() : ds.size();
			if (!pend && q < cmds.size() && cmds[q].at <= n) { pend = 2; at = cyc; }
			if (pend && cyc - at == 2)  { (isref ? t->ref_din : t->dut_din) = (pend == 2) ? cmds[q].b0 : cmds[q].b1; (isref ? t->ref_wrn : t->dut_wrn) = 0; }
			if (pend && cyc - at == 3)  { (isref ? t->ref_wrn : t->dut_wrn) = 1; }
			if (pend && cyc - at == 8)  { if (--pend == 0) q++; else at = cyc - 0; }
		};
		drive(true); drive(false);
		if (t->ref_sample) rs.push_back(t->ref_snd);
		if (t->dut_sample) ds.push_back(t->dut_snd);
	}
	long n = std::min(rs.size(), ds.size()), diff = 0, first = -1;
	double err = 0, sig = 0;
	for (long i = 0; i < n; i++) {
		if (rs[i] != ds[i]) { diff++; if (first < 0) first = i; }
		err += double(rs[i] - ds[i]) * (rs[i] - ds[i]); sig += double(rs[i]) * rs[i];
	}
	printf("samples %ld, differing %ld (%.2f%%), first at %ld, error/signal %.1f dB, stalled %.2f%% of clocks, %zu phrase starts\n",
	       n, diff, 100.0 * diff / n, first, 10 * log10((err + 1e-9) / (sig + 1e-9)), 100.0 * stall_cyc / cyc, cmds.size());
	FILE *f = fopen(argv[3], "wb");
	for (long i = 0; i < n; i++) { int16_t a = rs[i] << 2, b = ds[i] << 2; fwrite(&a, 2, 1, f); fwrite(&b, 2, 1, f); }
	fclose(f);
	return 0;
}
