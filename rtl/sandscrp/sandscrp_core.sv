// Sand Scorpion (FACE, 1992) — board core. One machine config serves all
// three sets (sandscrp, sandscrpa, sandscrpb); they differ only in the 68000
// program ROM and in how the graphics ROMs are packaged, and the .mra
// generator makes all three stream identical graphics bytes.
//
// From kaneko/sandscrp.cpp:
//   TMP68HC000N-12 @ 12 MHz, Z8400AB1 @ 4 MHz, YM2203C @ 4 MHz,
//   OKIM6295 @ 12 MHz/6 = 2 MHz pin 7 HIGH, watchdog 3 s.
//   The Z80 reads BOTH DIP banks through the YM2203's port A/B; the 68000
//   never sees them, so the OSD DIP bytes go to jt03's IOA_in/IOB_in.
//
// clk_sys is 48 MHz, which divides EXACTLY into every clock this board has:
// 68000 /4, Z80 and YM2203 /12, OKI /24, pixel clock /8 = 6 MHz. (The NMK16
// cores this borrows from run 40 MHz with per-mille accumulators because
// their boards need 8 and 14 MHz; nothing here does, and an exact divider
// cannot drift.)
//
// 68000 map. Everything not listed is unmapped and reads 0x0000 -- MAME's
// unmapped value for this driver, which has no set_unmap_high; a core that
// returns 0xFFFF instead can spin forever on a bad vector (NMK16's airattcka).
//   000000-07FFFF  program ROM (512 KB)
//   100001 (byte)  IRQ acknowledge: bit 3 sprite, 4 unknown, 5 vblank.
//                  Bit 0 is PANDORA's flip (see docs/known-issues.md SS-6).
//   200000-20001F  CALC1
//   300000-30001F  VIEW2 registers
//   400000-403FFF  VIEW2 VRAM (tiles x2, line scroll x2)
//   500000-501FFF  PANDORA sprite RAM: ONE BYTE per WORD address, taken from
//                  whichever lane the CPU drives (LDS wins), read back in both
//   600000-600FFF  palette, 2048 x xGRB_555
//   700000-70FFFF  work RAM, 64 KB
//   800001 (byte)  IRQ cause: 0x08 sprite, 0x10 unknown, 0x20 vblank
//   A00001 (byte)  coin counters
//   B00000/2/4/6   P1, P2, SYSTEM, UNK -- all active low, high byte all ones
//   E00001 (byte)  read = latch 1 (from Z80), write = latch 0 (to Z80, NMI)
//   E40001 (byte)  latch status, bit 7 = latch 0 full, bit 6 = latch 1 full
//   EC0000         watchdog reset on read
//
// Z80: 0000-7FFF ROM, 8000-BFFF banked 16 KB window (port 0 & 7), C000-DFFF
// RAM. I/O 00 bank, 02/03 YM2203, 04 OKI, 06 latch 1 write, 07 latch 0 read,
// 08 latch status with the two bits SWAPPED relative to the 68000 side.
// NMI = latch 0 holds unread data; INT = YM2203 timer.
//
// Every memory select is qualified with the Z80's own mreq/rd: an `in a,(n)`
// puts A on the high address byte, so an unqualified ROM decode answers the
// YM status read and every busy-wait loop hangs (NMK16's NMK-14).
module sandscrp_core #(
	parameter HW_ROMS = 0,
	parameter ROM_FILE = "", parameter Z80_FILE = "",
	parameter TILES_FILE = "", parameter SPRITES_FILE = "", parameter OKI_FILE = "",
	// 3 s at 48 MHz. The game DELIBERATELY hangs on a cold boot until the
	// watchdog reboots it (docs/known-issues.md SS-7), so the sim needs this
	// to boot at all -- but not at full length: shorten it to reach the same
	// state sooner. Behaviour does not change with it, only the wait.
	parameter [31:0] WDOG_CYCLES = 32'd144_000_000,
	parameter SIM_DSW = 0
) (
	input             clk_sys,
	input             reset,
	input             pause,

	// active-low switch inputs, bit per control (0 = pressed)
	input      [7:0]  p1_i,          // 0 up 1 down 2 left 3 right 4 shot 5 bomb
	input      [7:0]  p2_i,
	input      [7:0]  sys_i,         // 0 start1 1 start2 2 coin1 3 coin2 4 tilt 6 service
	input      [7:0]  dsw1_i,        // SW1 -> YM2203 port A
	input      [7:0]  dsw2_i,        // SW2 -> YM2203 port B

	input             osd_flip,      // OSD "Flip screen": mirror the readback coordinates

	// video
	output            ce_pix,
	output     [8:0]  hcount,
	output     [8:0]  vcount,
	output            hblank,
	output            vblank,
	output            vbl_start,
	output     [23:0] rd_rgb,

	// audio
	output signed [15:0] snd,

	// SDRAM-side ROM streams (HW_ROMS=1); unused at HW_ROMS=0
	output     [23:0] rom0_addr, rom1_addr, roms_addr, okirom_addr,
	input      [7:0]  rom0_data, rom1_data, roms_data, okirom_data,
	input             rom0_ready, rom1_ready, roms_ready,
	output     [22:0] prog_word_addr,
	input      [15:0] prog_word_data,
	input             prog_ready,
	output     [16:0] z80rom_addr,
	input      [7:0]  z80rom_data,
	input             z80rom_ready,
	// jt6295's ADPCM fetch ignores rom_ok entirely (jt6295_rom.v), so a byte
	// that has not arrived is used anyway: the OKI cache's STALL must be ANDed
	// into the chip's cen instead. NMK16 shipped 37.6% stale sample bytes for a
	// week before this was understood -- "corrupted sound effects" on the board,
	// nothing at all in simulation.
	input             okirom_stall,

	// debug / measurement
	output     [23:0] dbg_m68k_pc_addr,
	output     [31:0] dbg_ym_writes,
	output     [31:0] dbg_oki_writes,
	output     [31:0] dbg_spr_pass_cycles,
	output     [15:0] dbg_spr_late_swaps,
	output     [31:0] dbg_wdog_resets,
	output     [15:0] dbg_ram70,        // the word at 0x700070 the boot check tests
	output     [31:0] dbg_reads_rom, dbg_reads_ram, dbg_writes_ram, dbg_acc_other,
	output     [23:0] dbg_last_other,
	output signed [15:0] dbg_ym_snd,
	output signed [15:0] dbg_oki_snd
);
	// ------------------------------------------------------------------
	// Clock enables — every one an exact divider of 48 MHz
	// ------------------------------------------------------------------
	reg [1:0] cpu_div = 2'd0;
	always @(posedge clk_sys) cpu_div <= cpu_div + 2'd1;
	wire enPhi1 = (cpu_div == 2'd3);          // 12 MHz, two phases
	wire enPhi2 = (cpu_div == 2'd1);

	reg [3:0] z80_div = 4'd0;
	always @(posedge clk_sys) z80_div <= (z80_div == 4'd11) ? 4'd0 : z80_div + 4'd1;
	wire z80_cen = (z80_div == 4'd11);        // 4 MHz
	wire ym_cen  = (z80_div == 4'd5);         // 4 MHz, offset so the two never collide

	reg [4:0] oki_div = 5'd0;
	always @(posedge clk_sys) oki_div <= (oki_div == 5'd23) ? 5'd0 : oki_div + 5'd1;
	wire oki_cen = (oki_div == 5'd23);        // 2 MHz, pin 7 high

	reg [2:0] pix_div = 3'd0;
	always @(posedge clk_sys) pix_div <= reset ? 3'd0 : pix_div + 3'd1;
	assign ce_pix = (pix_div == 3'd7);        // 6 MHz

	// ------------------------------------------------------------------
	// Raster
	// ------------------------------------------------------------------
	wire vis_start, hactive, vactive, line_start;
	wire [8:0] hc, vc;
	video_timing_sandscrp timing (
		.clk_sys(clk_sys), .ce_pix(ce_pix), .reset(reset),
		.hcount(hc), .vcount(vc), .line_start(line_start),
		.hblank(hblank), .vblank(vblank), .vbl_start(vbl_start), .vis_start(vis_start),
		.hactive(hactive), .vactive(vactive)
	);
	assign hcount = hc;
	assign vcount = vc;

	// OSD flip mirrors the readback window (rot180 of the 256x224 visible
	// area), exactly as the NMK16 cores do it, so it reaches every output
	// including direct video. The tile renderer prepares the row the raster
	// is about to show, so the flip has to mirror the PREPARED row too.
	wire [7:0] rd_x  = osd_flip ? (8'd255 - hc[7:0]) : hc[7:0];
	wire [8:0] rd_y  = osd_flip ? (9'd255 - vc)      : vc;       // 16..239 mirrored onto itself
	wire [8:0] nxt_y = (vc == 9'd261) ? 9'd0 : vc + 9'd1;
	wire [8:0] render_y = osd_flip ? (9'd255 - nxt_y) : nxt_y;

	// ------------------------------------------------------------------
	// 68000
	// ------------------------------------------------------------------
	wire        eRWn, ASn, LDSn, UDSn, VMAn, FC0, FC1, FC2, BGn, oRESETn, oHALTEDn;
	wire [15:0] oEdb;
	wire [23:1] eab;
	reg  [15:0] iEdb;

	wire iack_cycle = FC0 & FC1 & FC2 & ~ASn;
	wire VPAn = ~iack_cycle;                   // autovectored
	wire [23:0] byte_addr = {eab, 1'b0};
	wire cpu_write = ~eRWn & ~ASn;
	wire cpu_read  =  eRWn & ~ASn;
	wire uds = ~UDSn, lds = ~LDSn;

	// NMK-24: gate the CPU on whole phi1/phi2 PAIRS. fx68k needs strict
	// alternation; masking the two enables with a raw `pause` deletes however
	// many pulses fall in the window, often an odd number, and the sequencer
	// wedges mid-bus-cycle. Sampling on the UNGATED enPhi2 lands on a pair
	// boundary and keeps ticking while paused, so the CPU can be released.
	reg pause_68k = 1'b0;
	always @(posedge clk_sys) if (enPhi2) pause_68k <= pause;

	// ---- decode
	wire sel_rom     = (byte_addr <  24'h080000);
	wire sel_irqack  = (byte_addr[23:16] == 8'h10);
	wire sel_calc1   = (byte_addr[23:16] == 8'h20) & (byte_addr[15:5] == 11'd0);
	wire sel_v2reg   = (byte_addr[23:16] == 8'h30) & (byte_addr[15:5] == 11'd0);
	wire sel_v2vram  = (byte_addr[23:16] == 8'h40) & (byte_addr[15:14] == 2'b00);
	wire sel_pandora = (byte_addr[23:16] == 8'h50) & (byte_addr[15:13] == 3'd0);
	wire sel_pal     = (byte_addr[23:16] == 8'h60) & (byte_addr[15:12] == 4'd0);
	wire sel_ram     = (byte_addr[23:16] == 8'h70);
	wire sel_irqcause= (byte_addr[23:16] == 8'h80);
	wire sel_coin    = (byte_addr[23:16] == 8'hA0);
	wire sel_in      = (byte_addr[23:16] == 8'hB0) & (byte_addr[15:3] == 13'd0);
	wire sel_latch   = (byte_addr[23:16] == 8'hE0);
	wire sel_latchst = (byte_addr[23:16] == 8'hE4);
	wire sel_wdog    = (byte_addr[23:16] == 8'hEC);

	// ---- program ROM
	wire [15:0] rom_dout;
	wire        rom_ready;
	assign prog_word_addr = {8'd0, eab[15:1]};
	generate
	if (!HW_ROMS) begin : g_prog_sim
		reg [15:0] prog_rom [0:262143];
		initial if (ROM_FILE != "") $readmemh(ROM_FILE, prog_rom);
		reg [15:0] prog_q;
		always @(posedge clk_sys) prog_q <= prog_rom[eab[18:1]];
		reg [17:0] prog_a_r;
		always @(posedge clk_sys) prog_a_r <= eab[18:1];
		assign rom_dout  = prog_q;
		assign rom_ready = (prog_a_r == eab[18:1]);     // combinational compare on the REGISTERED address
	end else begin : g_prog_hw
		assign rom_dout  = prog_word_data;
		assign rom_ready = prog_ready;
	end
	endgenerate

	// ---- work RAM, 32768 words as two byte lanes (one M10K set, registered read)
	wire [14:0] ram_a = eab[15:1];
	reg [7:0] ram_hi [0:32767];
	reg [7:0] ram_lo [0:32767];
	reg [7:0] ram_qh, ram_ql;
	wire ram_we_hi = sel_ram & cpu_write & uds;
	wire ram_we_lo = sel_ram & cpu_write & lds;
	always @(posedge clk_sys) begin
		if (ram_we_hi) begin ram_hi[ram_a] <= oEdb[15:8]; ram_qh <= oEdb[15:8]; end else ram_qh <= ram_hi[ram_a];
		if (ram_we_lo) begin ram_lo[ram_a] <= oEdb[7:0];  ram_ql <= oEdb[7:0];  end else ram_ql <= ram_lo[ram_a];
	end
	reg [14:0] ram_a_r;
	always @(posedge clk_sys) ram_a_r <= ram_a;
	wire [15:0] ram_dout  = {ram_qh, ram_ql};
	wire        ram_ready = (ram_a_r == ram_a);

	// ---- video block (VIEW2 + PANDORA + palette)
	wire [15:0] v2vram_dout, v2reg_dout, pal_dout;
	wire [7:0]  pandora_dout;
	wire        pandora_hold;
	wire [12:0] v2vram_addr = eab[13:1];
	wire [11:0] pandora_addr = eab[12:1];
	wire [10:0] pal_addr = eab[11:1];
	reg [12:0] v2vram_a_r; reg [11:0] pandora_a_r; reg [10:0] pal_a_r;
	always @(posedge clk_sys) begin
		v2vram_a_r <= v2vram_addr; pandora_a_r <= pandora_addr; pal_a_r <= pal_addr;
	end
	wire v2vram_ready  = (v2vram_a_r == v2vram_addr);
	wire pandora_ready = (pandora_a_r == pandora_addr) & ~pandora_hold;
	wire pal_ready     = (pal_a_r == pal_addr);

	wire sprite_flip;
	video_sandscrp #(.HW_ROMS(HW_ROMS), .TILES_FILE(TILES_FILE), .SPRITES_FILE(SPRITES_FILE)) video (
		.clk(clk_sys), .reset(reset),
		.view2_vram_addr(v2vram_addr), .view2_reg_addr(eab[4:1]),
		.pandora_addr(pandora_addr), .pal_addr(pal_addr), .cpu_wdata(oEdb),
		.view2_vram_we_hi(sel_v2vram & cpu_write & uds), .view2_vram_we_lo(sel_v2vram & cpu_write & lds),
		.view2_reg_we_hi(sel_v2reg & cpu_write & uds),   .view2_reg_we_lo(sel_v2reg & cpu_write & lds),
		// spriteram_lsb_w: the byte goes in whichever lane the CPU drives, LDS last and so winning
		.pandora_we(sel_pandora & cpu_write & (uds | lds)),
		.pandora_wdata(lds ? oEdb[7:0] : oEdb[15:8]),
		.pal_we_hi(sel_pal & cpu_write & uds), .pal_we_lo(sel_pal & cpu_write & lds),
		.view2_vram_rdata(v2vram_dout), .view2_reg_rdata(v2reg_dout),
		.pandora_rdata(pandora_dout), .pandora_hold(pandora_hold), .pal_rdata(pal_dout),
		.line_start(line_start), .render_y(render_y), .eof(vbl_start), .vis_start(vis_start),
		.sprite_flip(sprite_flip),
		.rd_x(rd_x), .rd_y(rd_y), .rd_rgb(rd_rgb),
		.rom0_addr(rom0_addr), .rom1_addr(rom1_addr), .roms_addr(roms_addr),
		.rom0_data(rom0_data), .rom1_data(rom1_data), .roms_data(roms_data),
		.rom0_ready(rom0_ready), .rom1_ready(rom1_ready), .roms_ready(roms_ready),
		.pandora_busy(), .dbg_pass_cycles(dbg_spr_pass_cycles), .dbg_late_swaps(dbg_spr_late_swaps)
	);

	// ---- CALC1
	wire [15:0] calc1_dout;
	wire        calc1_wdog;
	reg  [3:0]  calc1_a_r;
	always @(posedge clk_sys) calc1_a_r <= eab[4:1];
	wire calc1_ready = (calc1_a_r == eab[4:1]);
	kaneko_hit calc1 (
		.clk(clk_sys), .reset(reset), .addr(eab[4:1]), .din(oEdb),
		.we_hi(sel_calc1 & cpu_write & uds), .we_lo(sel_calc1 & cpu_write & lds),
		.rd(sel_calc1 & cpu_read), .dout(calc1_dout), .watchdog_strobe(calc1_wdog)
	);

	// ---- interrupts: an INPUT_MERGER_ANY_HIGH of three sources on IPL1
	reg vblank_irq, sprite_irq, unknown_irq;
	wire irq_ack_w = sel_irqack & cpu_write & lds;
	always @(posedge clk_sys) begin
		if (reset) begin vblank_irq <= 1'b0; sprite_irq <= 1'b0; unknown_irq <= 1'b0; end
		else begin
			// the vblank interrupt and the sprite interrupt are the same instant:
			// set_vblank_int fires at vblank start, screen_vblank's rising edge
			// sets SPRITE_IRQ and runs pandora->eof() alongside it
			if (vbl_start) begin vblank_irq <= 1'b1; sprite_irq <= 1'b1; end
			if (irq_ack_w) begin
				if (oEdb[3]) sprite_irq  <= 1'b0;
				if (oEdb[4]) unknown_irq <= 1'b0;
				if (oEdb[5]) vblank_irq  <= 1'b0;
			end
		end
	end
	// PANDORA's flip: the two lines that would set it are commented out in
	// sandscrp.cpp, but the game writes this bit exactly when the Flip Screen
	// DIP is on (0x1b/0x33/0x3b instead of 0x1a/0x32/0x3a -- measured), and
	// the chip has the mechanism. See docs/known-issues.md SS-6.
	reg spr_flip_r;
	always @(posedge clk_sys) if (reset) spr_flip_r <= 1'b0; else if (irq_ack_w) spr_flip_r <= oEdb[0];
	assign sprite_flip = spr_flip_r;

	wire irq_any = vblank_irq | sprite_irq | unknown_irq;
	wire [2:0] ipl = irq_any ? 3'd1 : 3'd0;

	// ---- sound latches
	reg [7:0] latch0, latch1;      // 0: 68000 -> Z80, 1: Z80 -> 68000
	reg [1:0] latch_full;
	wire z80_io_re, z80_io_we;
	wire [15:0] z80_a;
	wire [7:0]  z80_do;
	wire l0_w_68k = sel_latch   & cpu_write & lds;
	wire l1_r_68k = sel_latch   & cpu_read  & lds;
	wire lst_w68k = sel_latchst & cpu_write & lds;
	wire l1_w_z80 = z80_io_we & (z80_a[7:0] == 8'h06);
	wire l0_r_z80 = z80_io_re & (z80_a[7:0] == 8'h07);
	reg  l1_r_68k_d, l0_r_z80_d;
	always @(posedge clk_sys) begin
		if (reset) begin latch0 <= 8'd0; latch1 <= 8'd0; latch_full <= 2'd0; end
		else begin
			if (l0_w_68k) begin latch0 <= oEdb[7:0]; latch_full[0] <= 1'b1; end
			if (l1_w_z80) begin latch1 <= z80_do;    latch_full[1] <= 1'b1; end
			if (l1_r_68k & ~l1_r_68k_d) latch_full[1] <= 1'b0;
			if (l0_r_z80 & ~l0_r_z80_d) latch_full[0] <= 1'b0;
			if (lst_w68k) latch_full <= {oEdb[6], oEdb[7]};   // {full[1], full[0]}
		end
		l1_r_68k_d <= l1_r_68k;
		l0_r_z80_d <= l0_r_z80;
	end

	// ---- watchdog. The 68000 clears it by READING 0xEC0000; CALC1 register 0
	// does the same. It must pause with the CPU, or any pause longer than the
	// timeout reboots the game (OSD, hiscore, cheats, savestates).
	reg [31:0] wdog_cnt;
	reg        wdog_reset;
	reg [31:0] wdog_resets;
	wire wdog_kick = (sel_wdog & cpu_read) | calc1_wdog;
	always @(posedge clk_sys) begin
		wdog_reset <= 1'b0;
		if (reset) begin wdog_cnt <= 32'd0; wdog_resets <= 32'd0; end
		else if (wdog_kick) wdog_cnt <= 32'd0;
		else if (!pause) begin
			if (wdog_cnt >= WDOG_CYCLES) begin
				wdog_cnt <= 32'd0; wdog_reset <= 1'b1; wdog_resets <= wdog_resets + 32'd1;
			end else wdog_cnt <= wdog_cnt + 32'd1;
		end
	end
	assign dbg_wdog_resets = wdog_resets;
	wire sys_reset = reset | wdog_reset;

	// ---- coin counters (no lockout on this board)
	reg [1:0] coin_ctr;
	always @(posedge clk_sys) if (reset) coin_ctr <= 2'd0; else if (sel_coin & cpu_write & lds) coin_ctr <= oEdb[1:0];

	// ---- inputs: active low, unused bits and the whole high byte read as ones
	reg [15:0] in_word;
	always @(*) case (eab[2:1])
		2'd0: in_word = {8'hFF, p1_i};
		2'd1: in_word = {8'hFF, p2_i};
		2'd2: in_word = {8'hFF, sys_i};
		default: in_word = 16'hFFFF;                 // "UNK", all ones
	endcase

	// ---- read mux. Unmapped reads give 0x0000 (MAME's unmap value here).
	always @(*) begin
		if      (sel_rom)      iEdb = rom_dout;
		else if (sel_ram)      iEdb = ram_dout;
		else if (sel_v2vram)   iEdb = v2vram_dout;
		else if (sel_v2reg)    iEdb = v2reg_dout;
		else if (sel_pandora)  iEdb = {pandora_dout, pandora_dout};   // spriteram_lsb_r mirrors the byte
		else if (sel_pal)      iEdb = pal_dout;
		else if (sel_calc1)    iEdb = calc1_dout;
		else if (sel_irqcause) iEdb = {8'h00, 2'b00, vblank_irq, unknown_irq, sprite_irq, 3'b000};
		else if (sel_in)       iEdb = in_word;
		else if (sel_latch)    iEdb = {8'h00, latch1};
		else if (sel_latchst)  iEdb = {8'h00, latch_full[0], latch_full[1], 6'd0};
		else                   iEdb = 16'h0000;
	end
	// ---- DTACK: every registered read gets its one wait state, and nothing else waits
	wire DTACKn = ASn | iack_cycle
	            | (sel_rom     & cpu_read & ~rom_ready)
	            | (sel_ram     & cpu_read & ~ram_ready)
	            | (sel_v2vram  & cpu_read & ~v2vram_ready)
	            | (sel_pal     & cpu_read & ~pal_ready)
	            | (sel_calc1   & cpu_read & ~calc1_ready)
	            | (sel_pandora & ~ASn     & ~pandora_ready);   // also holds WRITES off during the snapshot

	fx68k fx68k_inst (
		.clk(clk_sys), .HALTn(1'b1), .extReset(sys_reset), .pwrUp(sys_reset),
		.enPhi1(enPhi1 & ~pause_68k), .enPhi2(enPhi2 & ~pause_68k),
		.eRWn(eRWn), .ASn(ASn), .LDSn(LDSn), .UDSn(UDSn), .E(), .VMAn(VMAn),
		.FC0(FC0), .FC1(FC1), .FC2(FC2), .BGn(BGn), .oRESETn(oRESETn), .oHALTEDn(oHALTEDn),
		.DTACKn(DTACKn), .VPAn(VPAn), .BERRn(1'b1), .BRn(1'b1), .BGACKn(1'b1),
		.IPL0n(~ipl[0]), .IPL1n(~ipl[1]), .IPL2n(~ipl[2]),
		.iEdb(iEdb), .oEdb(oEdb), .eab(eab)
	);
	assign dbg_m68k_pc_addr = byte_addr;

	// ---- measurement probes (simulation only in practice; a handful of counters)
	reg [15:0] ram70; reg [31:0] c_rom, c_ramr, c_ramw, c_other; reg [23:0] last_other;
	reg        asn_d;
	always @(posedge clk_sys) begin
		asn_d <= ASn;
		if (sys_reset) begin c_rom <= 0; c_ramr <= 0; c_ramw <= 0; c_other <= 0; end
		else if (asn_d & ~ASn) begin           // one count per bus cycle, on ASn falling
			if      (sel_rom & cpu_read)  c_rom  <= c_rom  + 1;
			else if (sel_ram & cpu_read)  c_ramr <= c_ramr + 1;
			else if (sel_ram & cpu_write) c_ramw <= c_ramw + 1;
			else begin c_other <= c_other + 1; last_other <= byte_addr; end
		end
		if (sel_ram & cpu_write & (eab[15:1] == 15'h0038)) ram70 <= oEdb;
	end
	assign dbg_ram70 = ram70;
	assign dbg_reads_rom = c_rom; assign dbg_reads_ram = c_ramr;
	assign dbg_writes_ram = c_ramw; assign dbg_acc_other = c_other; assign dbg_last_other = last_other;

	// ------------------------------------------------------------------
	// Z80 sound section
	// ------------------------------------------------------------------
	wire [7:0] z80_di_w;
	wire       z80_wait_n;
	wire       z80_m1_n, z80_mreq_n, z80_iorq_n, z80_rd_n, z80_wr_n, z80_rfsh_n, z80_halt_n, z80_busak_n;
	// NMI while latch 0 holds data the Z80 has not read (generic_latch_8's
	// data_pending_callback). The sound driver's every command arrives this way.
	wire z80_nmi_n = ~latch_full[0];
	wire ym_irq_n;
	T80s z80_cpu (
		.RESET_n(~sys_reset), .CLK(clk_sys), .CEN(z80_cen & ~pause), .WAIT_n(z80_wait_n),
		.INT_n(ym_irq_n), .NMI_n(z80_nmi_n), .BUSRQ_n(1'b1), .OUT0(1'b0),
		.DI(z80_di_w), .M1_n(z80_m1_n), .MREQ_n(z80_mreq_n), .IORQ_n(z80_iorq_n),
		.RD_n(z80_rd_n), .WR_n(z80_wr_n), .RFSH_n(z80_rfsh_n), .HALT_n(z80_halt_n),
		.BUSAK_n(z80_busak_n), .A(z80_a), .DO(z80_do)
	);
	wire z80_mem_re = ~z80_mreq_n & ~z80_rd_n;
	wire z80_mem_we = ~z80_mreq_n & ~z80_wr_n;
	assign z80_io_re = ~z80_iorq_n & ~z80_rd_n;
	assign z80_io_we = ~z80_iorq_n & ~z80_wr_n;

	reg [2:0] z80_bank;
	always @(posedge clk_sys) if (sys_reset) z80_bank <= 3'd0;
	                          else if (z80_io_we & (z80_a[7:0] == 8'h00)) z80_bank <= z80_do[2:0];

	wire sel_z80_rom  = z80_mem_re & (z80_a < 16'h8000);
	wire sel_z80_bank = z80_mem_re & (z80_a >= 16'h8000) & (z80_a < 16'hC000);
	wire sel_z80_ram  = (z80_a >= 16'hC000) & (z80_a < 16'hE000);
	// WAIT_n: the Z80's own ROM cache may not have the byte yet (HW_ROMS=1).
	// Held only during a ROM/bank memory read, so RAM and I/O stay zero-wait.
	assign z80_wait_n = ~(HW_ROMS[0] & (sel_z80_rom | sel_z80_bank) & ~z80rom_ready);
	// 128 KB ROM: the fixed window is the first 32 KB, the banked window is any
	// of eight 16 KB pages of the SAME file (banks 0 and 1 are the fixed half again)
	assign z80rom_addr = sel_z80_bank ? {2'd0, z80_bank, z80_a[13:0]} : {3'd0, z80_a[15:0]} & 17'h1FFFF;
	wire [7:0] z80_rom_byte;
	generate
	if (!HW_ROMS) begin : g_z80_sim
		reg [7:0] z80_rom [0:131071];
		initial if (Z80_FILE != "") $readmemh(Z80_FILE, z80_rom);
		assign z80_rom_byte = z80_rom[z80rom_addr];
	end else begin : g_z80_hw
		assign z80_rom_byte = z80rom_data;
	end
	endgenerate

	reg [7:0] z80_ram [0:8191];
	reg [7:0] z80_ram_q;
	always @(posedge clk_sys) begin
		if (sel_z80_ram & z80_mem_we) z80_ram[z80_a[12:0]] <= z80_do;
		z80_ram_q <= z80_ram[z80_a[12:0]];
	end

	// YM2203: jt03 has no read strobe, so a status read must see the live port
	// decode. Writes are stretched, as the NMK16 cores do, because the chip
	// samples on its own cen.
	wire ym_a0 = (z80_a[7:0] == 8'h03);
	wire ym_sel = z80_io_we & ((z80_a[7:0] == 8'h02) | (z80_a[7:0] == 8'h03));
	reg [7:0] ym_din_latch; reg ym_addr_latch; reg [5:0] ym_wr_hold = 6'd0;
	reg ym_we_prev; reg [31:0] ym_writes;
	always @(posedge clk_sys) begin
		ym_we_prev <= ym_sel;
		if (ym_sel & ~ym_we_prev) begin
			ym_din_latch <= z80_do; ym_addr_latch <= ym_a0; ym_wr_hold <= 6'd40;
			ym_writes <= ym_writes + 32'd1;
		end else if (ym_wr_hold != 6'd0) ym_wr_hold <= ym_wr_hold - 6'd1;
		if (sys_reset) ym_writes <= 32'd0;
	end
	wire ym_wr_n = ~(ym_wr_hold != 6'd0);
	wire ym_addr_sel = (ym_wr_hold != 6'd0) ? ym_addr_latch : ym_a0;
	wire [7:0] ym_dout;
	wire signed [15:0] ym_snd;
	// DSW1 on port A, DSW2 on port B: on this board the Z80 is the only thing
	// that can read the dip switches, and it reads them through the sound chip.
	jt03 ym (
		.rst(sys_reset), .clk(clk_sys), .cen(ym_cen),
		.din(ym_din_latch), .addr(ym_addr_sel), .cs_n(1'b0), .wr_n(ym_wr_n),
		.dout(ym_dout), .irq_n(ym_irq_n),
		.IOA_in(dsw1_i), .IOB_in(dsw2_i), .IOA_out(), .IOB_out(), .IOA_oe(), .IOB_oe(),
		.psg_A(), .psg_B(), .psg_C(), .fm_snd(), .psg_snd(), .snd(ym_snd), .snd_sample(),
		.debug_view()
	);

	// OKIM6295 at 2 MHz, pin 7 HIGH -> ss = 1 (2 MHz / 132 = 15.15 kHz)
	wire oki_sel = z80_io_we & (z80_a[7:0] == 8'h04);
	reg [7:0] oki_din_latch; reg [5:0] oki_wr_hold = 6'd0; reg oki_we_prev; reg [31:0] oki_writes;
	always @(posedge clk_sys) begin
		oki_we_prev <= oki_sel;
		if (oki_sel & ~oki_we_prev) begin
			oki_din_latch <= z80_do; oki_wr_hold <= 6'd40; oki_writes <= oki_writes + 32'd1;
		end else if (oki_wr_hold != 6'd0) oki_wr_hold <= oki_wr_hold - 6'd1;
		if (sys_reset) oki_writes <= 32'd0;
	end
	wire [17:0] oki_rom_addr;
	wire [7:0]  oki_rom_byte;
	generate
	if (!HW_ROMS) begin : g_oki_sim
		reg [7:0] oki_rom [0:262143];
		initial if (OKI_FILE != "") $readmemh(OKI_FILE, oki_rom);
		assign oki_rom_byte = oki_rom[oki_rom_addr];
	end else begin : g_oki_hw
		assign oki_rom_byte = okirom_data;
	end
	endgenerate
	assign okirom_addr = {6'd0, oki_rom_addr};
	wire signed [13:0] oki_snd;
	jt6295 #(.INTERPOL(0)) oki (
		.rst(sys_reset), .clk(clk_sys), .cen(oki_cen & ~(HW_ROMS[0] & okirom_stall)), .ss(1'b1),
		.wrn(~(oki_wr_hold != 6'd0)), .din(oki_din_latch), .dout(),
		.rom_addr(oki_rom_addr), .rom_data(oki_rom_byte), .rom_ok(1'b1),
		.sound(oki_snd), .sample()
	);

	// Z80 read mux — every select qualified with mreq/rd (NMK-14)
	reg [7:0] z80_rdata;
	always @(*) begin
		if      (sel_z80_rom | sel_z80_bank)          z80_rdata = z80_rom_byte;
		else if (sel_z80_ram & z80_mem_re)             z80_rdata = z80_ram_q;
		else if (z80_io_re & (z80_a[7:0] == 8'h02))    z80_rdata = ym_dout;
		else if (z80_io_re & (z80_a[7:0] == 8'h03))    z80_rdata = ym_dout;
		else if (z80_io_re & (z80_a[7:0] == 8'h07))    z80_rdata = latch0;
		// latch status, bits SWAPPED against the 68000 side (the driver's own "swapped!?")
		else if (z80_io_re & (z80_a[7:0] == 8'h08))    z80_rdata = {latch_full[1], latch_full[0], 6'd0};
		else                                           z80_rdata = 8'hFF;
	end
	assign z80_di_w = z80_rdata;

	// ---- mix. MAME routes both chips at 0.5; its OKI stream is full 16-bit
	// scale, i.e. jt6295's 14-bit `sound` x4, so the OKI term is shifted up two
	// places against the FM before the halving. Every term gets its own signed
	// wire: a ternary chain with an unsigned concatenation in it evaluates
	// unsigned and turns >>> logical (NMK16's tomagic clipping thump).
	wire signed [17:0] ym_term  = {{2{ym_snd[15]}}, ym_snd};
	wire signed [17:0] oki_term = {{2{oki_snd[13]}}, oki_snd, 2'b00};
	wire signed [17:0] mix = (ym_term + oki_term) >>> 1;
	assign snd = (mix > 18'sd32767)  ?  16'sd32767 :
	             (mix < -18'sd32768) ? -16'sd32768 : mix[15:0];
	assign dbg_ym_snd  = ym_snd;
	assign dbg_oki_snd = {oki_snd, 2'b00};
	assign dbg_ym_writes  = ym_writes;
	assign dbg_oki_writes = oki_writes;
endmodule
