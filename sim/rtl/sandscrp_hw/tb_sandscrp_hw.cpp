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
	top.reset = 1;
	for (int i = 0; i < 200; i++) tick();
	top.reset = 0;
	while (!top.sdram_ready) tick();
	printf("sdram ready\n");

	// index 0: the ROM image
	top.ioctl_download = 1; top.ioctl_index = 0;
	for (size_t i = 0; i < rom.size(); i++) {
		top.ioctl_addr = i; top.ioctl_dout = rom[i]; top.ioctl_wr = 1; tick();
		top.ioctl_wr = 0; tick();
		if ((i & 0xFFFFF) == 0) { printf("  download %zu/%zu\n", i, rom.size()); fflush(stdout); }
	}
	// index 254 LAST, addresses restarting at 0 -- the real loader's order.
	// Anything that latched an SDRAM write from this would corrupt the reset
	// vector, which is exactly what the index gate in sandscrp_rom_hw prevents.
	if (switches) {
		top.ioctl_index = 254;
		uint8_t sw[3] = { (uint8_t)top.dsw1_i, (uint8_t)top.dsw2_i, 0x00 };
		for (int i = 0; i < 3; i++) { top.ioctl_addr = i; top.ioctl_dout = sw[i]; top.ioctl_wr = 1; tick(); top.ioctl_wr = 0; tick(); }
	}
	top.ioctl_download = 0; top.ioctl_index = 0;
	for (int i = 0; i < 100; i++) tick();
	printf("download done\n"); fflush(stdout);

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
	return 0;
}
