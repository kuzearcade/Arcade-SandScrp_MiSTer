// Load a MAME state dump (tools/ss_state.py output) through the CPU ports,
// run Pandora's eof twice (draw, then swap), then sample one frame off the
// live raster: the pixel presented at ce_pix k is read just before ce_pix
// k+1 (rd_rgb is two clocks behind rd_x, the period is eight).
//   Vvideo_state_top <dump_prefix> <out.ppm> [sprite_flip]
// sprite_flip drives Pandora's own flip (irq_cause bit 0). It is 0 for every
// MAME comparison: MAME leaves kan_pand's flip_screen_set unused for this
// driver (the two assignments in sandscrp.cpp irq_cause_w are commented out),
// so MAME's flipped frames have the LAYERS mirrored and the sprites not. The
// VIEW2 layer flip is not this flag -- it comes from the control register in
// the state dump, as on the board.
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <string>
#include <vector>
#include "Vvideo_state_top.h"
#include "verilated.h"

static std::vector<uint32_t> readhex(const std::string &p) {
	std::vector<uint32_t> v; FILE *f = fopen(p.c_str(), "r");
	if (!f) { fprintf(stderr, "cannot open %s\n", p.c_str()); exit(2); }
	unsigned x; while (fscanf(f, "%x", &x) == 1) v.push_back(x); fclose(f); return v;
}

int main(int argc, char **argv) {
	VerilatedContext ctx; ctx.commandArgs(argc, argv);
	if (argc < 3) { fprintf(stderr, "usage: %s <dump_prefix> <out.ppm> [flip]\n", argv[0]); return 2; }
	std::string pre = argv[1]; const char *out = argv[2]; bool flip = argc > 3 && atoi(argv[3]);
	Vvideo_state_top top{&ctx};
	auto tick = [&]() { top.clk = 0; top.eval(); top.clk = 1; top.eval(); };
	top.reset = 1; top.sprite_flip = flip;
	top.view2_vram_we = top.view2_reg_we = top.pandora_we = top.pal_we = 0;
	for (int i = 0; i < 8; i++) tick();
	top.reset = 0;
	auto load = [&](const std::string &name, int which, unsigned base) {
		auto v = readhex(pre + name);
		for (size_t i = 0; i < v.size(); i++) {
			top.cpu_wdata = v[i]; top.pandora_wdata = v[i] & 0xff;
			switch (which) {
				case 0: top.view2_vram_addr = base + i; top.view2_vram_we = 1; break;
				case 1: top.view2_reg_addr = i; top.view2_reg_we = 1; break;
				case 2: top.pal_addr = i; top.pal_we = 1; break;
				default: top.pandora_addr = i; top.pandora_we = 1; break;
			}
			tick();
			top.view2_vram_we = top.view2_reg_we = top.pandora_we = top.pal_we = 0;
		}
		return v.size();
	};
	size_t n = 0;
	n += load("vram1.hex", 0, 0x0000); n += load("vram0.hex", 0, 0x0800);
	n += load("scroll1.hex", 0, 0x1000); n += load("scroll0.hex", 0, 0x1800);
	n += load("regs.hex", 1, 0); n += load("palette.hex", 2, 0);
	if (!(getenv("VS_NOSPR") && atoi(getenv("VS_NOSPR")))) n += load("spriteram.hex", 3, 0);
	if (getenv("VS_CTRL")) { top.cpu_wdata = strtoul(getenv("VS_CTRL"), nullptr, 16); top.view2_reg_addr = 4; top.view2_reg_we = 1; tick(); top.view2_reg_we = 0; }
	printf("loaded %zu words/bytes\n", n);
	// Pandora: wait for the first eof (draw pass), then the second (swap).
	int eofs = 0; long cycles = 0;
	while (eofs < 2 && cycles < 4000000) { tick(); cycles++; if (top.eof) eofs++; }
	while (top.pandora_busy && cycles < 6000000) { tick(); cycles++; }
	printf("pandora: %d eofs, last pass %u clocks\n", eofs, top.dbg_pass_cycles);
	// wait for the next frame start (vcount 0, hcount 0) then sample 262 lines
	std::vector<uint8_t> img(256 * 224 * 3, 0);
	while (!(top.vcount == 0 && top.hcount == 0 && top.ce_pix)) tick();
	// ce_pix is high during the last clock of a pixel period: hcount/vcount still
	// name that pixel and rd_rgb (two clocks behind) has settled for it.
	for (long t = 0; t < 384L * 262 * 8 + 16; t++) {
		if (top.ce_pix) {
			int px = top.hcount, py = top.vcount;
			if (px < 256 && py >= 16 && py < 240) {
				uint32_t rgb = top.rd_rgb; size_t o = ((py - 16) * 256 + px) * 3;
				img[o] = rgb >> 16; img[o + 1] = rgb >> 8; img[o + 2] = rgb;
			}
		}
		tick();
	}
	FILE *f = fopen(out, "wb"); fprintf(f, "P6\n256 224\n255\n"); fwrite(img.data(), 1, img.size(), f); fclose(f);
	printf("wrote %s\n", out);
	return 0;
}
