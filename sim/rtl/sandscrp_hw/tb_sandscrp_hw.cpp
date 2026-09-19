// Hardware-path testbench: stream the real ioctl bytes into SDRAM, then boot.
//
// Every ROM byte the core sees comes back out of rtl/sdram.sv, so this is the
// harness that can catch a byte-order or region-base mistake -- the class of
// bug that looks perfect in the reference simulation and ships combed sprites.
//
// Environment:
//   TB_STREAM     path to the ioctl .bin (tools/gen_sandscrp_mra.py --ioctl)
//   TB_CYCLES     clk_sys cycles AFTER the download (default 400M)
//   TB_SWITCHES   send a <switches> block on index 254 after index 0 (default 1)
//   TB_DUMP_FROM/TO/EVERY/DIR, TB_DSW1/2, TB_FLIP, TB_AUDIO, TB_REPORT
//                 as in sim/rtl/sandscrp
//   TB_COIN/TB_START/TB_FIRE   frame numbers, as in sim/rtl/sandscrp
//   TB_AUDIT      1 = run the golden-byte audit after the download and exit.
//                 Walks every byte of every region through the REAL cache and
//                 the REAL SDRAM controller and compares it against the ioctl
//                 image, then prints the per-channel counters. This is the
//                 measurement that separates "the cache never fills" from
//                 "the cache fills with the wrong bytes".
//   TB_AUDIT_STEP address stride for the audit (default 1 = every byte)
//   TB_AUDIT_MAX  stop a region after this many mismatches are printed
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <string>
#include <vector>
#include "Vsandscrp_hw_top.h"
#include "verilated.h"

static unsigned long envu(const char *n, unsigned long d) {
	const char *v = getenv(n); return v ? strtoul(v, nullptr, 0) : d;
}

int main(int argc, char **argv) {
	VerilatedContext ctx; ctx.commandArgs(argc, argv);
	Vsandscrp_hw_top top{&ctx};

	const std::string stream_path = getenv("TB_STREAM") ? getenv("TB_STREAM") : "roms/sandscrp_ioctl.bin";
	const uint64_t cycles   = envu("TB_CYCLES", 400000000ULL);
	const long dump_from    = envu("TB_DUMP_FROM", 0xffffffff);
	const long dump_to      = envu("TB_DUMP_TO", 0);
	const long dump_every   = envu("TB_DUMP_EVERY", 1);
	const std::string ddir  = getenv("TB_DUMP_DIR") ? getenv("TB_DUMP_DIR") : ".";
	const long report_every = envu("TB_REPORT", 300);
	const long coin_f  = envu("TB_COIN", 0xffffffff);
	const long start_f = envu("TB_START", 0xffffffff);
	const long fire_f  = envu("TB_FIRE", 0xffffffff);
	const bool switches = envu("TB_SWITCHES", 1) != 0;
	FILE *af = getenv("TB_AUDIO") ? fopen(getenv("TB_AUDIO"), "wb") : nullptr;

	std::vector<uint8_t> rom;
	{
		FILE *f = fopen(stream_path.c_str(), "rb");
		if (!f) { fprintf(stderr, "cannot open %s (run `make roms`)\n", stream_path.c_str()); return 2; }
		fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
		rom.resize(n); if (fread(rom.data(), 1, n, f) != (size_t)n) { fprintf(stderr, "short read\n"); return 2; }
		fclose(f);
		printf("ioctl stream: %ld bytes from %s\n", n, stream_path.c_str());
	}

	// clk_ram runs at 3 edges per clk_sys cycle, a 144 MHz-equivalent against
	// this core's 48 MHz -- slightly more bandwidth than the real 96 MHz, which
	// is why the headroom numbers this prints are an optimistic bound.
	auto tick = [&]() {
		for (int k = 0; k < 3; k++) { top.clk_ram = 0; top.eval(); top.clk_ram = 1; top.eval(); }
		top.clk_sys = 0; top.eval();
		for (int k = 0; k < 3; k++) { top.clk_ram = 0; top.eval(); top.clk_ram = 1; top.eval(); }
		top.clk_sys = 1; top.eval();
	};

	top.p1_i = top.p2_i = top.sys_i = 0xff;
	top.dsw1_i = envu("TB_DSW1", 0xEF);
	top.dsw2_i = envu("TB_DSW2", 0xFF);
	top.osd_flip = envu("TB_FLIP", 0);
	top.pause = 0;
	top.ioctl_download = 0; top.ioctl_wr = 0; top.ioctl_addr = 0; top.ioctl_dout = 0; top.ioctl_index = 0;
	top.audit_en = 0; top.audit_sel = 0; top.audit_addr = 0; top.dbg_sel = 0;
	top.reset = 1;
	for (int i = 0; i < 200; i++) tick();
	top.reset = 0;
	while (!top.sdram_ready) tick();
	printf("sdram ready\n");

	// index 0: the ROM image
	top.ioctl_download = 1; top.ioctl_index = 0;
	// Honour ioctl_wait, as the real loader does: the SDRAM write takes about
	// eight clk_sys cycles and the arbiter does not queue, so offering the next
	// byte before the previous one lands silently throws it away.
	long dropped_check = 0; uint64_t wait_total = 0;
	const size_t dl_limit = envu("TB_DL_LIMIT", 0) ? envu("TB_DL_LIMIT", 0) : rom.size();
	for (size_t i = 0; i < dl_limit; i++) {
		top.ioctl_addr = i; top.ioctl_dout = rom[i]; top.ioctl_wr = 1; tick();
		top.ioctl_wr = 0;
		int guard = 0;
		while (top.ioctl_wait && guard < 1000) { tick(); guard++; }
		if (guard >= 1000) dropped_check++;
		wait_total += guard;
		if ((i & 0xFFFF) == 0) { printf("  download %zu/%zu (avg wait %.1f ticks/byte, never-completed %ld)\n",
		                                i, dl_limit, i ? (double)wait_total / i : 0.0, dropped_check); fflush(stdout); }
	}
	if (dropped_check) printf("  WARNING: %ld download writes never completed\n", dropped_check);
	// index 254 LAST, addresses restarting at 0 -- the real loader's order.
	// Anything that latched an SDRAM write from this would corrupt the reset
	// vector, which is exactly what the index gate in sandscrp_rom_hw prevents.
	if (switches) {
		top.ioctl_index = 254;
		uint8_t sw[3] = { (uint8_t)top.dsw1_i, (uint8_t)top.dsw2_i, 0x00 };
		for (int i = 0; i < 3; i++) {
			top.ioctl_addr = i; top.ioctl_dout = sw[i]; top.ioctl_wr = 1; tick(); top.ioctl_wr = 0;
			int guard = 0; while (top.ioctl_wait && guard < 1000) { tick(); guard++; }
		}
	}
	top.ioctl_download = 0; top.ioctl_index = 0;
	for (int i = 0; i < 100; i++) tick();
	printf("download done\n"); fflush(stdout);

	auto counters = [&](const char *when) {
		static const char *chan[6] = {"prog", "z80 ", "spr ", "v2L0", "v2L1", "oki "};
		printf("--- cache counters (%s)\n", when);
		for (int c = 0; c < 6; c++) {
			top.dbg_sel = 3 * c + 0; top.eval(); uint32_t rq = top.dbg_cnt;
			top.dbg_sel = 3 * c + 1; top.eval(); uint32_t vl = top.dbg_cnt;
			top.dbg_sel = 3 * c + 2; top.eval(); uint32_t st = top.dbg_cnt;
			printf("    %s  fetches started %9u  finished %9u  stall cycles %10u\n", chan[c], rq, vl, st);
		}
		top.dbg_sel = 26; top.eval(); uint32_t dlr = top.dbg_cnt;
		top.dbg_sel = 27; top.eval(); uint32_t dlg = top.dbg_cnt;
		printf("    download  requests raised %9u  writes completed %9u\n", dlr, dlg);
		for (int p = 0; p < 4; p++) {
			top.dbg_sel = 18 + 2 * p; top.eval(); uint32_t rq = top.dbg_cnt;
			top.dbg_sel = 19 + 2 * p; top.eval(); uint32_t ak = top.dbg_cnt;
			printf("    sdram port %d  req %9u  ack %9u\n", p, rq, ak);
		}
		fflush(stdout);
	};

	if (envu("TB_AUDIT", 0)) {
		// region base in the ioctl image, length, audit_sel, name, word-wide?
		struct Region { uint32_t base, len; int sel; const char *name; bool word; };
		const Region regions[] = {
			{0x000000, 0x080000, 0, "maincpu (68000 words)", true},
			{0x080000, 0x020000, 1, "audiocpu (Z80 bytes)",  false},
			{0x0A0000, 0x100000, 2, "sprites (bytes)",       false},
			{0x1A0000, 0x100000, 3, "view2 L0 (bytes)",      false},
			{0x1A0000, 0x100000, 4, "view2 L1 (bytes)",      false},
			{0x2A0000, 0x040000, 5, "oki (bytes)",           false},
		};
		const uint32_t step = envu("TB_AUDIT_STEP", 1);
		const uint32_t limit = envu("TB_AUDIT_LEN", 0);
		const uint32_t maxshow = envu("TB_AUDIT_MAX", 6);
		top.audit_en = 1;
		for (int i = 0; i < 20; i++) tick();
		long total_bad = 0, total_checked = 0, total_timeouts = 0;
		for (const Region &r : regions) {
			long bad = 0, checked = 0, timeouts = 0, shown = 0;
			uint64_t wait_cycles = 0;
			top.audit_sel = r.sel;
			// a word region is addressed in bytes here too; step by 2
			uint32_t inc = r.word ? (step * 2) : step;
			const uint32_t rlen = limit && limit < r.len ? limit : r.len;
			for (uint32_t a = 0; a < rlen; a += inc) {
				top.audit_addr = a;
				int waited = 0;
				top.eval();
				while (!top.audit_ready && waited < 4000) { tick(); waited++; }
				wait_cycles += waited;
				if (waited >= 4000) { timeouts++; if (shown < maxshow) { printf("    TIMEOUT at %s +0x%06x\n", r.name, a); shown++; } continue; }
				uint32_t got = top.audit_data, want;
				if (r.word) want = rom[r.base + a] | (rom[r.base + a + 1] << 8);   // even stream byte = low byte
				else        want = rom[r.base + a];
				checked++;
				if (got != want) {
					bad++;
					if (shown < maxshow) { printf("    WRONG  %s +0x%06x: got %04x want %04x\n", r.name, a, got, want); shown++; }
				}
			}
			printf("  %-24s %8ld checked, %8ld wrong, %6ld timeouts, %.2f avg wait cycles\n",
			       r.name, checked, bad, timeouts, checked ? (double)wait_cycles / checked : 0.0);
			fflush(stdout);
			total_bad += bad; total_checked += checked; total_timeouts += timeouts;
		}
		top.audit_en = 0;
		printf("GOLDEN-BYTE AUDIT: %ld checked, %ld wrong, %ld timeouts -> %s\n",
		       total_checked, total_bad, total_timeouts,
		       (total_bad == 0 && total_timeouts == 0) ? "PASS" : "FAIL");
		counters("after the audit");
		return (total_bad == 0 && total_timeouts == 0) ? 0 : 1;
	}

	std::vector<uint8_t> img(256 * 224 * 3, 0);
	long frame = -1, nonblank_last = 0;
	uint64_t audio_acc = 0;

	for (uint64_t t = 0; t < cycles; t++) {
		tick();
		if (top.ce_pix) {
			int x = top.hcount, y = top.vcount;
			if (x < 256 && y >= 16 && y < 240) {
				uint32_t rgb = top.rd_rgb; size_t o = ((y - 16) * 256 + x) * 3;
				img[o] = rgb >> 16; img[o + 1] = rgb >> 8; img[o + 2] = rgb;
			}
		}
		if (top.vbl_start) {
			if (frame >= dump_from && frame <= dump_to && ((frame - dump_from) % dump_every) == 0) {
				char path[1024];
				snprintf(path, sizeof(path), "%s/sandscrp_hw_frame_%05ld.ppm", ddir.c_str(), frame);
				FILE *g = fopen(path, "wb");
				if (g) { fprintf(g, "P6\n256 224\n255\n"); fwrite(img.data(), 1, img.size(), g); fclose(g); }
			}
			frame++;
			uint8_t sys = 0xff, p1 = 0xff;
			if (frame >= coin_f  && frame < coin_f  + 8) sys &= ~0x04;
			if (frame >= start_f && frame < start_f + 8) sys &= ~0x01;
			if (frame >= fire_f && ((frame / 4) & 1) == 0) p1 &= ~0x10;
			top.sys_i = sys; top.p1_i = p1;
			if (report_every && (frame % report_every) == 0) {
				long nb = 0;
				for (size_t i = 0; i < img.size(); i += 3) if (img[i] | img[i+1] | img[i+2]) nb++;
				printf("frame %6ld nonblank=%6ld (was %6ld) ym=%u oki=%u wdog=%u spr=%u late=%u okistall=%u | rom_r=%u ram_r=%u ram_w=%u ram70=%04x\n",
				       frame, nb, nonblank_last, top.dbg_ym_writes, top.dbg_oki_writes,
				       top.dbg_wdog_resets, top.dbg_spr_pass_cycles, top.dbg_spr_late_swaps,
				       top.dbg_oki_unserved, top.dbg_reads_rom, top.dbg_reads_ram,
				       top.dbg_writes_ram, top.dbg_ram70);
				fflush(stdout);
				nonblank_last = nb;
			}
		}
		if (af && ++audio_acc >= 1000) { audio_acc = 0; int16_t s = top.snd; fwrite(&s, 2, 1, af); }
	}
	if (af) fclose(af);
	printf("done: %ld frames, ym=%u oki=%u wdog=%u sprite_pass=%u late_swaps=%u oki_stall_cycles=%u\n",
	       frame, top.dbg_ym_writes, top.dbg_oki_writes, top.dbg_wdog_resets,
	       top.dbg_spr_pass_cycles, top.dbg_spr_late_swaps, top.dbg_oki_unserved);
	counters("end of run");
	return 0;
}
