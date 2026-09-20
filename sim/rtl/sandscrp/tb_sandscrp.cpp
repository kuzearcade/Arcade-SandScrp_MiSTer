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
//   TB_SS_CMP=K   compare the frame K after the LOAD COMPLETED against the one
//                 K after the SAVE COMPLETED. The completion frames are what
//                 matter, not the request frames: the CPUs are frozen for the
//                 whole park, so the state's own clock is the instant the save
//                 finished, and the machine resumes from exactly there. A
//                 round trip that restored everything therefore puts the two
//                 on the same timeline, and those two frames must be identical.
//   TB_SS_SLOT    slot 0-3 (default 0)
//
//   TB_SS_DIFF=1  the state-level test, which names the missing words instead
//                 of inferring them from where sprites landed:
//                   save slot 0 at TB_SS_SAVE            (CPU-time T)
//                   save slot 1 K frames after that resumes   (CPU-time T+K)
//                   load slot 0 GAP frames later         (back to T)
//                   save slot 2 K frames after THAT resumes   (CPU-time T+K)
//                 Slot 1 and slot 2 are both the state at T+K, one reached
//                 directly and one through a save/load, so every differing
//                 word is restore error. K is counted from each resume so the
//                 two saves park after the same amount of CPU execution.
//   TB_SS_K       frames from a resume to the paired save (default 10)
//   TB_SS_GAP     frames from the slot-1 save to the load (default 20)
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
	const bool ss_diff_mode = envu("TB_SS_DIFF", 0) != 0;
	const long ss_k   = envu("TB_SS_K", 10);
	const long ss_gap = envu("TB_SS_GAP", 20);
	long ss_next_frame = -1;           // when the next scheduled request fires
	int  ss_phase = 0;                 // 0 idle, 1 saving, 2 saved, 3 loading, 4 loaded
	int  ss_result = 2;                // 0 pass, 1 fail, 2 incomplete
	bool ss_clear = false;
	// A WINDOW of reference frames, not one: the park freezes the CPUs but not
	// the raster, so a resumed machine can be a frame out of step with the run
	// it was saved from without having lost any state. Reporting the best
	// match over the window separates the two, the same way the MAME
	// comparison does.
	const long ss_win = envu("TB_SS_WIN", 3);
	std::vector<std::vector<uint8_t>> ss_ref_imgs;
	std::vector<long> ss_ref_nums;
	long ss_ref_frame = -1, ss_save_ok = -1, ss_load_ok = -1;

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
		if (ss_diff_mode && top.ss_done_ok) {
			// 1 = slot0 saving, 3 = slot1 saving, 5 = loading slot0, 7 = slot2 saving
			if (ss_phase == 1) {
				printf("savestate: slot 0 saved (resumed at frame %ld)\n", frame);
				ss_next_frame = frame + ss_k; ss_phase = 2;
			} else if (ss_phase == 3) {
				printf("savestate: slot 1 saved at frame %ld -- the direct T+K reference\n", frame);
				ss_next_frame = frame + ss_gap; ss_phase = 4;
			} else if (ss_phase == 5) {
				printf("savestate: slot 0 loaded (resumed at frame %ld)\n", frame);
				ss_next_frame = frame + ss_k; ss_phase = 6;
			} else if (ss_phase == 7) {
				printf("savestate: slot 2 saved at frame %ld -- T+K through a round trip\n", frame);
				ss_phase = 8;
			}
			fflush(stdout);
		} else if (top.ss_done_ok) {
			if (ss_phase == 1) {
				ss_phase = 2; ss_save_ok = frame; ss_ref_frame = frame + ss_cmp;
				printf("savestate: SAVE ok at frame %ld (reference frame will be %ld)\n", frame, ss_ref_frame);
				fflush(stdout);
			} else if (ss_phase == 3) {
				ss_phase = 4; ss_load_ok = frame;
				printf("savestate: LOAD ok at frame %ld (comparing frame %ld)\n", frame, frame + ss_cmp);
				fflush(stdout);
			}
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
			if (ss_ref_frame >= 0 && frame >= ss_ref_frame - ss_win && frame <= ss_ref_frame + ss_win) {
				ss_ref_imgs.push_back(img); ss_ref_nums.push_back(frame);
			}
			if (ss_phase == 4 && ss_load_ok >= 0 && frame == ss_load_ok + ss_cmp) {
				if (ss_ref_imgs.empty()) { printf("savestate: no reference frame captured\n"); ss_result = 1; }
				else {
					long nb = 0;
					for (size_t i = 0; i < img.size(); i += 3) if (img[i] | img[i+1] | img[i+2]) nb++;
					long best = -1, best_n = -1;
					for (size_t r = 0; r < ss_ref_imgs.size(); r++) {
						long diff = 0;
						const std::vector<uint8_t> &ref = ss_ref_imgs[r];
						for (size_t i = 0; i < img.size(); i += 3)
							if (img[i] != ref[i] || img[i+1] != ref[i+1] || img[i+2] != ref[i+2]) diff++;
						printf("savestate:   vs the save run's frame %ld (offset %+ld): %ld differing\n",
						       ss_ref_nums[r], ss_ref_nums[r] - ss_ref_frame, diff);
						if (best < 0 || diff < best) { best = diff; best_n = ss_ref_nums[r]; }
					}
					printf("savestate: round trip frame %ld: best match is the save run's frame %ld with %ld "
					       "differing pixels (non-blank %ld) -> %s\n", frame, best_n, best, nb, best ? "FAIL" : "PASS");
					ss_result = best ? 1 : 0;
					if (getenv("TB_SS_DUMP")) {
						auto wr = [&](const char *name, const std::vector<uint8_t> &v) {
							FILE *g = fopen(name, "wb");
							if (g) { fprintf(g, "P6\n256 224\n255\n"); fwrite(v.data(), 1, v.size(), g); fclose(g); }
						};
						wr("ss_restored.ppm", img);
						for (size_t r = 0; r < ss_ref_imgs.size(); r++)
							if (ss_ref_nums[r] == best_n) wr("ss_reference.ppm", ss_ref_imgs[r]);
						printf("savestate: wrote ss_restored.ppm and ss_reference.ppm\n");
					}
				}
				fflush(stdout);
				ss_phase = 9;
			}
			frame++;
			if (ss_diff_mode) {
				if (frame == ss_save_frame && ss_phase == 0) {
					top.ss_slot = 0; top.ss_save = 1; ss_clear = true; ss_phase = 1;
					printf("savestate: saving slot 0 at frame %ld (state T)\n", frame); fflush(stdout);
				} else if (ss_phase == 2 && frame == ss_next_frame) {
					top.ss_slot = 1; top.ss_save = 1; ss_clear = true; ss_phase = 3;
					printf("savestate: saving slot 1 at frame %ld (state T+K, direct)\n", frame); fflush(stdout);
				} else if (ss_phase == 4 && frame == ss_next_frame) {
					top.ss_slot = 0; top.ss_load = 1; ss_clear = true; ss_phase = 5;
					printf("savestate: loading slot 0 at frame %ld\n", frame); fflush(stdout);
				} else if (ss_phase == 6 && frame == ss_next_frame) {
					top.ss_slot = 2; top.ss_save = 1; ss_clear = true; ss_phase = 7;
					printf("savestate: saving slot 2 at frame %ld (state T+K, via a round trip)\n", frame); fflush(stdout);
				} else if (ss_phase == 8) {
					// ---- the diff
					const long SSW = 0x0E180;
					struct Region { long lo, hi; const char *name; };
					const Region regions[] = {
						{0x00000, 0x08000, "work RAM"},
						{0x08000, 0x0A000, "VIEW2 VRAM (tiles + line scroll)"},
						{0x0A000, 0x0A800, "palette"},
						{0x0B000, 0x0C000, "PANDORA sprite RAM"},
						{0x0C000, 0x0E000, "Z80 RAM"},
						{0x0E000, 0x0E100, "YM2203 register shadow"},
						{0x0E100, 0x0E180, "registers"},
					};
					auto word_of = [&](int slot, long w) -> uint16_t {
						uint32_t idx = (uint32_t)slot * 0x8000u + 1u + (uint32_t)(w >> 2);
						top.dbg_ddr_addr = idx; top.eval();
						uint64_t d = top.dbg_ddr_data;
						return (uint16_t)((d >> (16 * (w & 3))) & 0xFFFF);
					};
					long total = 0, shown = 0;
					printf("savestate: word-for-word diff of slot 1 and slot 2 (both the state at T+K)\n");
					for (const Region &r : regions) {
						long bad = 0, first = -1;
						for (long w = r.lo; w < r.hi && w < SSW; w++) {
							uint16_t a = word_of(1, w), b = word_of(2, w);
							if (a != b) { if (first < 0) first = w; bad++; }
						}
						total += bad;
						printf("  %-34s %6ld of %5ld words differ%s\n", r.name, bad, r.hi - r.lo,
						       bad ? "" : "   (identical)");
						if (bad && shown < 4) {
							shown++;
							long printed = 0;
							for (long w = first; w < r.hi && printed < 8; w++) {
								uint16_t a = word_of(1, w), b = word_of(2, w);
								if (a != b) { printf("        word 0x%05lx: direct %04x  round trip %04x\n", w, a, b); printed++; }
							}
						}
					}
					printf("savestate: %ld of %ld words differ -> %s\n", total, SSW, total ? "FAIL" : "PASS");
					ss_result = total ? 1 : 0;
					ss_phase = 9;
					fflush(stdout);
				}
			}
			if (!ss_diff_mode && frame == ss_save_frame && ss_phase == 0) {
				top.ss_save = 1; ss_clear = true; ss_phase = 1;
				printf("savestate: SAVE requested at frame %ld\n", frame); fflush(stdout);
			}
			if (!ss_diff_mode && frame == ss_load_frame && ss_phase == 2) {
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
