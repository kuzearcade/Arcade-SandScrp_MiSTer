// Reference simulation of the whole board (HW_ROMS=0): rtl/sandscrp/
// sandscrp_core.sv with $readmemh ROMs, sampled off its own live raster.
//
// Environment:
//   TB_CYCLES     clk_sys cycles to run (default 400M ~ 8.3 s of board time)
//   TB_DUMP_FROM  first frame to write as a PPM (default: none)
//   TB_DUMP_TO    last frame to write
//   TB_DUMP_EVERY write every Nth frame in that range (default 1)
//   TB_DUMP_DIR   where the PPMs go (default ".")
//   TB_DSW1/TB_DSW2  DIP bytes (defaults EF/FF, the .mra defaults)
//   TB_FLIP       OSD flip
//   TB_AUDIO      raw signed 16-bit mono at 48 kHz to this path
//   TB_COIN/TB_START  frame at which to hold coin 1 / start 1 for 8 frames
//   TB_FIRE       frame from which to autofire (4 on, 4 off)
//   TB_REPORT     frames between progress lines (default 300)
//   TB_SS_SAVE=N  request a savestate save at frame N
//   TB_SS_LOAD=M  request a load at frame M (M > N)
//   TB_SS_CMP=K   after the load, compare frame M+K against the frame the save
//                 run produced K frames after N. A round trip that restored
//                 everything puts the machine on the same timeline, so those
//                 two frames must be identical.
//   TB_SS_SLOT    slot 0-3 (default 0)
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>
#include "Vsandscrp_ref_top.h"
#include "verilated.h"

static unsigned long envu(const char *n, unsigned long d) {
	const char *v = getenv(n); return v ? strtoul(v, nullptr, 0) : d;
}

int main(int argc, char **argv) {
	VerilatedContext ctx; ctx.commandArgs(argc, argv);
	Vsandscrp_ref_top top{&ctx};

	const uint64_t cycles   = envu("TB_CYCLES", 400000000ULL);
	const long dump_from    = envu("TB_DUMP_FROM", 0xffffffff);
	const long dump_to      = envu("TB_DUMP_TO", 0);
	const long dump_every   = envu("TB_DUMP_EVERY", 1);
	const std::string ddir  = getenv("TB_DUMP_DIR") ? getenv("TB_DUMP_DIR") : ".";
	const long report_every = envu("TB_REPORT", 300);
	const long coin_f  = envu("TB_COIN", 0xffffffff);
	const long start_f = envu("TB_START", 0xffffffff);
	const long fire_f  = envu("TB_FIRE", 0xffffffff);
	const char *audio_path = getenv("TB_AUDIO");
	FILE *af = audio_path ? fopen(audio_path, "wb") : nullptr;   // opened BEFORE the long loop

	top.p1_i = top.p2_i = top.sys_i = 0xff;
	top.dsw1_i = envu("TB_DSW1", 0xEF);
	top.dsw2_i = envu("TB_DSW2", 0xFF);
	top.osd_flip = envu("TB_FLIP", 0);
	top.pause = 0;
	// the ROM interfaces are tied off inside sandscrp_ref_top (HW_ROMS=0)

	top.reset = 1;
	for (int i = 0; i < 64; i++) { top.clk_sys = 0; top.eval(); top.clk_sys = 1; top.eval(); }
	top.reset = 0;

	// savestate round trip
	const long ss_save_frame = getenv("TB_SS_SAVE") ? atol(getenv("TB_SS_SAVE")) : -1;
	const long ss_load_frame = getenv("TB_SS_LOAD") ? atol(getenv("TB_SS_LOAD")) : -1;
	const long ss_cmp        = envu("TB_SS_CMP", 30);
	top.ss_slot = envu("TB_SS_SLOT", 0);
	top.ss_save = 0; top.ss_load = 0;
	int  ss_phase = 0;                 // 0 idle, 1 saving, 2 saved, 3 loading, 4 loaded
	int  ss_result = 2;                // 0 pass, 1 fail, 2 incomplete
	bool ss_clear = false;
	std::vector<uint8_t> ss_ref_img;   // the frame the save run produced at save+cmp
	long ss_ref_frame = -1;

	std::vector<uint8_t> img(256 * 224 * 3, 0);
	long frame = -1;
	uint64_t audio_acc = 0;
	const uint64_t AUDIO_DIV = 1000;          // 48 MHz / 1000 = 48 kHz
	long nonblank_last = 0;

	auto write_ppm = [&](long f) {
		char path[1024];
		snprintf(path, sizeof(path), "%s/sandscrp_frame_%05ld.ppm", ddir.c_str(), f);
		FILE *g = fopen(path, "wb");
		if (!g) return;
		fprintf(g, "P6\n256 224\n255\n"); fwrite(img.data(), 1, img.size(), g); fclose(g);
	};

	for (uint64_t t = 0; t < cycles; t++) {
		top.clk_sys = 0; top.eval();
		top.clk_sys = 1; top.eval();

		if (top.ce_pix) {
			int x = top.hcount, y = top.vcount;
			if (x < 256 && y >= 16 && y < 240) {
				uint32_t rgb = top.rd_rgb; size_t o = ((y - 16) * 256 + x) * 3;
				img[o] = rgb >> 16; img[o + 1] = rgb >> 8; img[o + 2] = rgb;
			}
		}
		if (ss_clear) { top.ss_save = 0; top.ss_load = 0; ss_clear = false; }
		if (top.ss_done_ok) {
			if (ss_phase == 1) { ss_phase = 2; printf("savestate: SAVE ok at frame %ld\n", frame); fflush(stdout); }
			else if (ss_phase == 3) { ss_phase = 4; printf("savestate: LOAD ok at frame %ld\n", frame); fflush(stdout); }
		}
		if (top.ss_done_fail) {
			printf("savestate: %s FAILED (code %d) at frame %ld\n", ss_phase == 1 ? "SAVE" : "LOAD",
			       (int)top.ss_fail_code, frame);
			fflush(stdout); ss_result = 1; ss_phase = 9;
		}
		if (top.vbl_start) {
			if (frame >= dump_from && frame <= dump_to && ((frame - dump_from) % dump_every) == 0)
				write_ppm(frame);
			// the frame just finished is in img
			if (ss_ref_frame >= 0 && frame == ss_ref_frame) { ss_ref_img = img; }
			if (ss_phase == 4 && ss_load_frame >= 0 && frame == ss_load_frame + ss_cmp) {
				if (ss_ref_img.empty()) { printf("savestate: no reference frame captured\n"); ss_result = 1; }
				else {
					long diff = 0;
					for (size_t i = 0; i < img.size(); i += 3)
						if (img[i] != ss_ref_img[i] || img[i+1] != ss_ref_img[i+1] || img[i+2] != ss_ref_img[i+2]) diff++;
					long nb = 0;
					for (size_t i = 0; i < img.size(); i += 3) if (img[i] | img[i+1] | img[i+2]) nb++;
					printf("savestate: round trip frame %ld vs the save run's frame %ld: %ld differing pixels "
					       "(non-blank %ld) -> %s\n", frame, ss_ref_frame, diff, nb, diff ? "FAIL" : "PASS");
					ss_result = diff ? 1 : 0;
				}
				fflush(stdout);
				ss_phase = 9;
			}
			frame++;
			if (frame == ss_save_frame && ss_phase == 0) {
				top.ss_save = 1; ss_clear = true; ss_phase = 1;
				ss_ref_frame = ss_save_frame + ss_cmp;
				printf("savestate: SAVE requested at frame %ld\n", frame); fflush(stdout);
			}
			if (frame == ss_load_frame && ss_phase == 2) {
				top.ss_load = 1; ss_clear = true; ss_phase = 3;
				printf("savestate: LOAD requested at frame %ld\n", frame); fflush(stdout);
			}
			// inputs, held for 8 frames each
			uint8_t sys = 0xff, p1 = 0xff;
			if (frame >= coin_f  && frame < coin_f  + 8) sys &= ~0x04;   // coin 1
			if (frame >= start_f && frame < start_f + 8) sys &= ~0x01;   // start 1
			if (frame >= fire_f && ((frame / 4) & 1) == 0) p1 &= ~0x10;  // button 1
			top.sys_i = sys; top.p1_i = p1;
			if (report_every && (frame % report_every) == 0) {
				long nb = 0;
				for (size_t i = 0; i < img.size(); i += 3)
					if (img[i] | img[i+1] | img[i+2]) nb++;
				printf("frame %6ld t=%llu nonblank=%6ld ym=%u oki=%u wdog=%u spr=%u late=%u | rom_r=%u ram_r=%u ram_w=%u other=%u last_other=%06x ram70=%04x\n",
				       frame, (unsigned long long)t, nb,
				       top.dbg_ym_writes, top.dbg_oki_writes, top.dbg_wdog_resets,
				       top.dbg_spr_pass_cycles, top.dbg_spr_late_swaps,
				       top.dbg_reads_rom, top.dbg_reads_ram, top.dbg_writes_ram,
				       top.dbg_acc_other, top.dbg_last_other, top.dbg_ram70);
				fflush(stdout);
				nonblank_last = nb;
			}
		}
		if (af && ++audio_acc >= AUDIO_DIV) {
			audio_acc = 0;
			int16_t s = top.snd; fwrite(&s, 2, 1, af);
		}
	}
	if (af) fclose(af);
	if (ss_save_frame >= 0)
		printf("savestate round trip: %s\n", ss_result == 0 ? "PASS" : ss_result == 1 ? "FAIL" : "INCOMPLETE (run longer)");
	printf("done: %ld frames, ym_writes=%u oki_writes=%u watchdog_resets=%u sprite_pass=%u late_swaps=%u\n",
	       frame, top.dbg_ym_writes, top.dbg_oki_writes, top.dbg_wdog_resets,
	       top.dbg_spr_pass_cycles, top.dbg_spr_late_swaps);
	return (ss_save_frame >= 0 && ss_result != 0) ? 1 : 0;
}
