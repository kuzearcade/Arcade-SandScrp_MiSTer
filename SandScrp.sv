// Arcade-SandScrp_MiSTer — MiSTer top level for Sand Scorpion (FACE, 1992).
//
// One .rbf for all three sets: sandscrp, sandscrpa and sandscrpb share one
// machine configuration and byte-identical graphics and sound data, so the
// .mra chooses the set by which program ROM it loads and nothing here needs a
// game-select bit.
//
// Adapted from Arcade-NMK16_MiSTer's NMK16_Macross2.sv (the closest family:
// 68000 + Z80 + YM2203 + OKIM6295), keeping its OSD layout, keyboard map,
// autofire, pause, high-score, cheat, savestate and CRT Adjust wiring. What
// differs here, and why:
//
//   * clk_sys is 48 MHz, not 40. Every clock on this board divides into it
//     exactly (68000 /4, Z80 and YM2203 /12, OKI /24, pixel /8 = 6 MHz), so
//     no accumulator can drift. rtl/pll.v is retuned to 24/25.
//   * The DIP switches never reach the 68000. On this board the Z80 reads
//     both banks through the YM2203's port A/B, so the .mra's <switches>
//     bytes go to the core's dsw1_i/dsw2_i and from there to jt03's IOA/IOB.
//   * The game is ROT90, where the NMK16 sets are ROT270, so the two Vert
//     choices are the other way round: rotate_ccw = 0 is the MAME-correct
//     quarter turn here.
//   * The raster is 384x262 at a 6 MHz pixel clock, not 512x278 at 8 MHz.
//     Every consumer of it (video_retime, crt_chain) is parameterised, and
//     the numbers themselves are a documented unknown -- see
//     docs/known-issues.md SS-1: nothing in MAME describes this board's
//     timing, so these come from the closest sibling Kaneko board and want a
//     PCB measurement.
//
// NOT yet run on hardware. Everything below compiles and is consistent with
// the simulations, which are pixel-exact against MAME through the SDRAM path,
// but no bitstream has been on a DE10-Nano.
module emu
(
	`include "sys/emu_ports.vh"
);

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;

assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

assign AUDIO_S = 1; // signed PCM
assign AUDIO_MIX = 0;

assign LED_DISK = 0;
assign LED_POWER = 0;
assign BUTTONS = 0;

wire [1:0] ar = status[122:121];
// "Original" aspect follows the orientation: 4:3 as the board outputs it,
// 3:4 once the framebuffer rotation turns the game upright.
assign VIDEO_ARX = (!ar) ? (video_rotated ? 12'd3 : 12'd4) : (ar - 1'd1);
assign VIDEO_ARY = (!ar) ? (video_rotated ? 12'd4 : 12'd3) : 12'd0;

`include "build_id.v"
localparam CONF_STR = {
	"SandScrp;SS3E000000:40000;",   // savestates: 4 x 256 KB slots at 0x3E000000
	"-;",
	// Aspect ratio and Scandoubler Fx are the scaler's business; both hidden
	// (HB, menumask bit 11) under direct video, where the picture goes out at
	// native timing.
	"HBO[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"HBO[3:1],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
	// Sand Scorpion is ROT90 in MAME: a vertical game the board draws on its
	// side. Both Vert choices present it upright through the framebuffer;
	// "Vert 90" is the MAME-correct direction here (the NMK16 sets are ROT270
	// and want the other one), and "Vert 270" exists because a cabinet's
	// monitor can be mounted either way round. Hidden (H0) under direct
	// video, where the framebuffer path is unavailable.
	"H0O[9:8],Orientation,Horz,Vert 90,Vert 270;",
	// Flip screen: a 180-degree turn for an inverted monitor, done inside the
	// core by mirroring its own readback coordinates, so it reaches the analog
	// I/O board and direct video as well as the HDMI scaler.
	"O[17],Flip screen,Off,On;",
	"P3,CRT Adjust;",
	"P3O[101],CRT Adjust,Off,On;",
	"P3O[100:96],CRT H-Size,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"P3O[85:79],CRT H-Position,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,+21,+22,+23,+24,+25,+26,+27,+28,+29,+30,+31,+32,+33,+34,+35,+36,+37,+38,+39,+40,+41,+42,+43,+44,+45,+46,+47,+48,-48,-47,-46,-45,-44,-43,-42,-41,-40,-39,-38,-37,-36,-35,-34,-33,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"P3O[78:74],CRT V-Shift,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"P3O[107:104],CRT V-Size,0,+1,+2,+3,+4,-4,-3,-2,-1;",
	"P3O[108],CRT V-Size Mode,PVM,Cabinet;",
	// Autofire on the shot button, clocked by the game's own vblank. While a
	// player has it on, that player's button 3 is a plain shot. Hidden (h1)
	// unless the loaded .mra's <switches> third byte sets bit 6 -- the
	// autofire_releases/ mirror is the tree that does.
	"h1O[12:10],P1 Autofire,Off,10Hz,12Hz,15Hz,20Hz,30Hz;",
	"h1O[15:13],P2 Autofire,Off,10Hz,12Hz,15Hz,20Hz,30Hz;",
	"-;",
	// Where MiSTer inserts the DIP submenu it builds from the .mra's own
	// <switches>/<dip> entries. Changes arrive on ioctl index 254.
	"DIP;",
	"-;",
	"O[29],Pause,Off,On;",
	"P1,Scores;",
	"P1O[39],High Scores,Off,On;",
	"P1-;",
	"dAP1R[30],Save Scores;",
	"dAP1R[31],Reset Scores;",
	"P4,Savestates;",
	"P4O[41:40],Slot,1,2,3,4;",
	"P4-;",
	"P4R[42],Save state (Alt+F1-F4);",
	"P4R[43],Load state (F1-F4);",
	"P2,Cheats;",
	"P2-;",
	"h3P2O[32],Infinite Credits,Off,On;",
	"h4P2O[33],P1 Invincibility,Off,On;",
	"h5P2O[34],P2 Invincibility,Off,On;",
	"h6P2O[35],P1 Infinite Lives,Off,On;",
	"h7P2O[36],P2 Infinite Lives,Off,On;",
	"h8P2O[37],P1 Infinite Bombs,Off,On;",
	"h9P2O[38],P2 Infinite Bombs,Off,On;",
	"-;",
	"R[0],Reset;",
	// Five entries, positionally matched against each .mra's own <buttons>
	// list. Sand Scorpion has two buttons per player; Button 3 exists here
	// only as the plain-shot escape while autofire is on.
	"J1,Shot,Bomb,Button 3,Start,Coin;",
	"I,",
	"Slot=F1-F4|Save=Alt+F1-F4,",
	"Active Slot 1,",
	"Active Slot 2,",
	"Active Slot 3,",
	"Active Slot 4,",
	"State 1 saved,",
	"State 2 saved,",
	"State 3 saved,",
	"State 4 saved,",
	"State 1 loaded,",
	"State 2 loaded,",
	"State 3 loaded,",
	"State 4 loaded,",
	"Savestate failed,",
	"Slot empty;",
	"V,v",`BUILD_DATE
};

wire         forced_scandoubler;
wire         direct_video;
wire         autofire_unlock;
wire   [1:0] buttons;
wire [127:0] status;
wire  [10:0] ps2_key;
wire  [31:0] joystick_0, joystick_1;

wire         ioctl_download;
wire         ioctl_wr;
wire  [26:0] ioctl_addr_full;
wire   [7:0] ioctl_dout;
wire         ioctl_wait;
wire         ioctl_upload, ioctl_upload_req, ioctl_rd;
wire   [7:0] ioctl_din;
wire  [15:0] ioctl_index;

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(vm_gamma_bus),

	.forced_scandoubler(forced_scandoubler),
	.direct_video(direct_video),

	.buttons(buttons),
	.status(status),
	// [11] hides Aspect ratio and Scandoubler Fx under direct video; [10] greys
	// Save/Reset Scores while High Scores is Off; [9:3] hide the cheat slots
	// this .mra has no entry for; [1] shows the Autofire menu only when the
	// .mra sets the hidden unlock bit; [0] hides Orientation under direct video.
	.status_menumask({4'd0, direct_video, hs_enable, ch_avail, 1'b0, autofire_unlock, direct_video}),
	.status_in({status[127:42], ss_slot, status[39:0]}),
	.status_set(ss_status_update),
	.info_req(ss_info_req),
	.info(ss_info),

	.joystick_0(joystick_0),
	.joystick_1(joystick_1),

	.ioctl_download(ioctl_download),
	.ioctl_wr(ioctl_wr),
	.ioctl_upload(ioctl_upload),
	.ioctl_upload_req(ioctl_upload_req),
	.ioctl_upload_index(8'd4),
	.ioctl_din(ioctl_din),
	.ioctl_rd(ioctl_rd),
	.ioctl_addr(ioctl_addr_full),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(ioctl_wait),
	.ioctl_index(ioctl_index),

	.ps2_key(ps2_key)
);
wire [24:0] ioctl_addr = ioctl_addr_full[24:0];

///////////////////////   CLOCKS   ///////////////////////////////

wire clk_sys;     // 48 MHz — see this file's header
wire clk_ram;     // 96 MHz, the SDRAM controller's own clock
wire pll_locked;
pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),
	.outclk_1(clk_ram),
	.locked(pll_locked)
);

// "Reset Scores" needs two different hold times from one counter: the core
// only needs a normal reset pulse, but the hiscore module has to stay in reset
// right through the game's boot, or it restores the saved dump again and
// nothing has been reset.
reg [28:0] hs_rst_cnt = 29'd0;
always @(posedge clk_sys) begin
	if (status[31])       hs_rst_cnt <= 29'd288000000;   // ~6 s at 48 MHz
	else if (|hs_rst_cnt) hs_rst_cnt <= hs_rst_cnt - 1'b1;
end
wire hs_hold     = |hs_rst_cnt;
wire hs_core_rst = (hs_rst_cnt > 29'd283000000);         // core reset, first ~0.1 s

wire reset = RESET | status[0] | buttons[1] | ioctl_download | ~pll_locked | hs_core_rst;

// ------------------------------------------------------------------
// Keyboard: MAME's own default bindings, always live, ORed with the pads.
//   P1: arrows, Left Ctrl = shot, Left Alt = bomb, Space = button 3
//   P2: R/F/D/G, A = shot, S = bomb, Q = button 3
//   Coin 1 = 5, Coin 2 = 6, Service = 9, Start 1/2 = 1/2
//   F2 toggles Service Mode, which on this board is DSW2 bit 7
//   (PORT_SERVICE_DIPLOC "SW2:8", active low) rather than a DSW1 bit.
// ------------------------------------------------------------------
reg [6:0] kb_p1 = 7'd0, kb_p2 = 7'd0;   // [0]=R [1]=L [2]=D [3]=U [4]=B1 [5]=B2 [6]=B3
reg kb_start1 = 1'b0, kb_start2 = 1'b0, kb_coin1 = 1'b0, kb_coin2 = 1'b0, kb_service = 1'b0;
reg kb_test_mode = 1'b0, kb_f2_held = 1'b0, kb_toggle_d = 1'b0;
always @(posedge clk_sys) begin
	kb_toggle_d <= ps2_key[10];
	if (kb_toggle_d != ps2_key[10]) begin
		case (ps2_key[8:0])
			9'h175: kb_p1[3] <= ps2_key[9];
			9'h172: kb_p1[2] <= ps2_key[9];
			9'h16B: kb_p1[1] <= ps2_key[9];
			9'h174: kb_p1[0] <= ps2_key[9];
			9'h014: kb_p1[4] <= ps2_key[9];
			9'h011: kb_p1[5] <= ps2_key[9];
			9'h029: kb_p1[6] <= ps2_key[9];
			9'h02D: kb_p2[3] <= ps2_key[9];
			9'h02B: kb_p2[2] <= ps2_key[9];
			9'h023: kb_p2[1] <= ps2_key[9];
			9'h034: kb_p2[0] <= ps2_key[9];
			9'h01C: kb_p2[4] <= ps2_key[9];
			9'h01B: kb_p2[5] <= ps2_key[9];
			9'h015: kb_p2[6] <= ps2_key[9];
			9'h016: kb_start1  <= ps2_key[9];
			9'h01E: kb_start2  <= ps2_key[9];
			9'h02E: kb_coin1   <= ps2_key[9];
			9'h036: kb_coin2   <= ps2_key[9];
			9'h046: kb_service <= ps2_key[9];
			9'h006: begin
				if (ps2_key[9] && !kb_f2_held) kb_test_mode <= ~kb_test_mode;
				kb_f2_held <= ps2_key[9];
			end
			default: ;
		endcase
	end
end

// ------------------------------------------------------------------
// Autofire. The pattern advances once per game frame and restarts on each
// press, so a tap always fires on its first frame. With it on, the shot
// output is (held & pattern) | button 3, and button 3 itself stops reaching
// the game -- it is the plain-fire escape hatch.
// ------------------------------------------------------------------
wire       hblank_core, vblank_core;
wire [6:0] p1_raw = joystick_0[6:0] | kb_p1;
wire [6:0] p2_raw = joystick_1[6:0] | kb_p2;
reg  vbl_d = 1'b0;
wire frame_tick = vblank_core & ~vbl_d;
always @(posedge clk_sys) vbl_d <= vblank_core;

function automatic [3:0] af_on(input [2:0] m);
	case (m) 3'd1: af_on = 4'd3; 3'd2: af_on = 4'd2; 3'd3: af_on = 4'd2; 3'd4: af_on = 4'd1; 3'd5: af_on = 4'd1; default: af_on = 4'd0; endcase
endfunction
function automatic [3:0] af_len(input [2:0] m);
	case (m) 3'd1: af_len = 4'd6; 3'd2: af_len = 4'd5; 3'd3: af_len = 4'd4; 3'd4: af_len = 4'd3; 3'd5: af_len = 4'd2; default: af_len = 4'd1; endcase
endfunction

reg  [3:0] af1_phase = 4'd0, af2_phase = 4'd0;
reg        af1_held_d = 1'b0, af2_held_d = 1'b0;
wire [2:0] af1_mode = status[12:10];
wire [2:0] af2_mode = status[15:13];
always @(posedge clk_sys) begin
	af1_held_d <= p1_raw[4];
	af2_held_d <= p2_raw[4];
	if (p1_raw[4] & ~af1_held_d) af1_phase <= 4'd0;
	else if (frame_tick) af1_phase <= (af1_phase + 4'd1 >= af_len(af1_mode)) ? 4'd0 : af1_phase + 4'd1;
	if (p2_raw[4] & ~af2_held_d) af2_phase <= 4'd0;
	else if (frame_tick) af2_phase <= (af2_phase + 4'd1 >= af_len(af2_mode)) ? 4'd0 : af2_phase + 4'd1;
end
wire af1_en = (af1_mode != 3'd0);
wire af2_en = (af2_mode != 3'd0);
wire p1_b1 = af1_en ? ((p1_raw[4] & (af1_phase < af_on(af1_mode))) | p1_raw[6]) : p1_raw[4];
wire p2_b1 = af2_en ? ((p2_raw[4] & (af2_phase < af_on(af2_mode))) | p2_raw[6]) : p2_raw[4];

// The core's port bytes, active low, exactly as INPUT_PORTS_START(sandscrp)
// lays them out: P1/P2 bit 0 up, 1 down, 2 left, 3 right, 4 shot, 5 bomb;
// SYSTEM bit 0 start 1, 1 start 2, 2 coin 1, 3 coin 2, 4 tilt, 6 service.
// The pad's own bit order is right/left/down/up, so the four directions are
// reversed into the board's order here.
wire [7:0] p1_i = ~{2'b00, p1_raw[5], p1_b1, p1_raw[0], p1_raw[1], p1_raw[2], p1_raw[3]};
wire [7:0] p2_i = ~{2'b00, p2_raw[5], p2_b1, p2_raw[0], p2_raw[1], p2_raw[2], p2_raw[3]};
// Start is J1 entry 4 (pad bit 7) and Coin entry 5 (bit 8); the J1 list has no
// sixth entry, so Service is the keyboard's 9 key only, as on the NMK16 cores.
wire [7:0] sys_i = ~{1'b0, kb_service, 1'b0, 1'b0,
                     joystick_1[8] | kb_coin2, joystick_0[8] | kb_coin1,
                     joystick_1[7] | kb_start2, joystick_0[7] | kb_start1};

// ------------------------------------------------------------------
// The .mra <switches> block, ioctl index 254: byte 0 = DSW1 (SW1), byte 1 =
// DSW2 (SW2), byte 2 bit 6 = the hidden Autofire unlock. These go to the
// core's YM2203 port inputs, because on this board the Z80 is the only thing
// that can read the dip switches and it reads them through the sound chip.
// Defaults are all-ones until the loader sends the block, matching an idle
// switch bank.
// ------------------------------------------------------------------
reg [7:0] dip_sw [0:7];
integer dip_i;
initial for (dip_i = 0; dip_i < 8; dip_i = dip_i + 1) dip_sw[dip_i] = 8'hFF;
always @(posedge clk_sys) begin
	if (ioctl_download && ioctl_wr && (ioctl_index == 16'd254) && !ioctl_addr[24:3])
		dip_sw[ioctl_addr[2:0]] <= ioctl_dout;
end
// F2 toggles Service Mode on top of whatever the OSD has set. On this board
// that is DSW2 bit 7, not a DSW1 bit.
wire [7:0] dsw1_i = dip_sw[0];
wire [7:0] dsw2_i = dip_sw[1] ^ {kb_test_mode, 7'd0};
assign autofire_unlock = dip_sw[2][6];

// ------------------------------------------------------------------
// SDRAM: one controller on its own 96 MHz clock, four ports, fed by
// rtl/sandscrp/sandscrp_rom_hw.sv (caches, arbiters and the download).
// ------------------------------------------------------------------
wire [24:1] sd0_addr, sd1_addr, sd2_addr, sd3_addr;
wire        sd0_wrl, sd0_wrh;
wire [15:0] sd0_din;
wire [15:0] sd0_dout, sd1_dout, sd2_dout, sd3_dout;
wire [31:0] sd0_pair, sd1_pair, sd2_pair, sd3_pair;
wire        sd0_req, sd1_req, sd2_req, sd3_req, sd0_ack, sd1_ack, sd2_ack, sd3_ack;
wire        sdram_ready;

// REFRESH_CYCLES at 96 MHz: 740 cycles is ~7.7 us, inside the 7.8125 us the
// MT48LC16M16 wants. rtl/sdram.sv's own default (850) is unsafe here and was
// measured producing real read-back corruption on silicon in the NMK16 work.
sdram #(.REFRESH_CYCLES(10'd740)) sdram_inst
(
	.SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
	.SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS),
	.SDRAM_nCAS(SDRAM_nCAS), .SDRAM_CLK(SDRAM_CLK), .SDRAM_CKE(SDRAM_CKE), .ready(sdram_ready),
	.init(~pll_locked), .clk(clk_ram), .prio_mode(2'd0),
	.addr0(sd0_addr), .wrl0(sd0_wrl), .wrh0(sd0_wrh), .din0(sd0_din), .dout0(sd0_dout), .dout0_pair(sd0_pair), .req0(sd0_req), .ack0(sd0_ack),
	.addr1(sd1_addr), .wrl1(1'b0), .wrh1(1'b0), .din1('0), .dout1(sd1_dout), .dout1_pair(sd1_pair), .req1(sd1_req), .ack1(sd1_ack),
	.addr2(sd2_addr), .wrl2(1'b0), .wrh2(1'b0), .din2('0), .dout2(sd2_dout), .dout2_pair(sd2_pair), .req2(sd2_req), .ack2(sd2_ack),
	.addr3(sd3_addr), .wrl3(1'b0), .wrh3(1'b0), .din3('0), .dout3(sd3_dout), .dout3_pair(sd3_pair), .req3(sd3_req), .ack3(sd3_ack)
);

wire [22:0] prog_word_addr; wire [15:0] prog_word_data; wire prog_ready;
wire [16:0] z80rom_addr;    wire  [7:0] z80rom_data;    wire z80rom_ready;
wire [23:0] roms_addr, rom0_addr, rom1_addr, okirom_addr;
wire  [7:0] roms_data, rom0_data, rom1_data, okirom_data;
wire        roms_ready, rom0_ready, rom1_ready, okirom_stall;

sandscrp_rom_hw rom_hw (
	.clk(clk_sys), .reset(reset),
	.ioctl_download(ioctl_download), .ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout), .ioctl_index(ioctl_index), .ioctl_wait(ioctl_wait),
	.prog_word_addr(prog_word_addr), .prog_word_data(prog_word_data), .prog_ready(prog_ready),
	.z80rom_addr(z80rom_addr), .z80rom_data(z80rom_data), .z80rom_ready(z80rom_ready),
	.roms_addr(roms_addr), .roms_data(roms_data), .roms_ready(roms_ready),
	.rom0_addr(rom0_addr), .rom1_addr(rom1_addr), .rom0_data(rom0_data), .rom1_data(rom1_data),
	.rom0_ready(rom0_ready), .rom1_ready(rom1_ready),
	.okirom_addr(okirom_addr), .okirom_data(okirom_data), .okirom_stall(okirom_stall),
	.sd_addr0(sd0_addr), .sd_addr1(sd1_addr), .sd_addr2(sd2_addr), .sd_addr3(sd3_addr),
	.sd_wrl0(sd0_wrl), .sd_wrh0(sd0_wrh), .sd_din0(sd0_din),
	.sd_req0(sd0_req), .sd_req1(sd1_req), .sd_req2(sd2_req), .sd_req3(sd3_req),
	.sd_ack0(sd0_ack), .sd_ack1(sd1_ack), .sd_ack2(sd2_ack), .sd_ack3(sd3_ack),
	.sd_dout0(sd0_dout), .sd_dout1(sd1_dout), .sd_dout2(sd2_dout), .sd_dout3(sd3_dout),
	.sd_dout0_pair(sd0_pair), .sd_dout1_pair(sd1_pair), .sd_dout2_pair(sd2_pair), .sd_dout3_pair(sd3_pair),
	.audit_en(1'b0), .audit_sel(3'd0), .audit_addr(24'd0), .audit_data(), .audit_ready(),
	.dbg_sel(5'd0), .dbg_cnt(), .dbg_oki_unserved()
);

// ---------------------------------------------------------------------------
// High scores (rtl/third_party/hiscore) and cheats (rtl/cheats.sv) share one
// work-RAM port in the core, which they only drive while they have the CPU
// paused. hiscore wins if they ever collide: it runs on OSD open, cheats on
// vblank, so in practice they do not.
// ---------------------------------------------------------------------------
wire [23:0] hs_addr;
wire  [7:0] hs_din, hs_dout;
wire        hs_write, hs_access, hs_configured;
wire [23:0] hi_addr;
wire  [7:0] hi_din;
wire        hi_write;
wire        hs_pause_raw, hs_upload_req_raw;
wire        hs_enable = status[39];
wire        hs_active = hs_enable & ~hs_hold;
wire        hs_pause  = hs_pause_raw & hs_active;
// "Save Scores" has no native path in the module: it only extracts on a RISING
// edge of OSD_STATUS, so the request drives that input low and lets it go.
reg  [23:0] hs_save_cnt = 24'd0;
always @(posedge clk_sys) begin
	if (status[30])          hs_save_cnt <= 24'd4800000;   // ~100 ms at 48 MHz
	else if (|hs_save_cnt)   hs_save_cnt <= hs_save_cnt - 1'b1;
end
wire hs_saving = |hs_save_cnt;
wire hs_osd = OSD_STATUS & ~hs_saving & hs_active;
assign ioctl_upload_req = hs_upload_req_raw & hs_active;

hiscore #(
	.HS_ADDRESSWIDTH(24),
	.HS_SCOREWIDTH(8),       // 84 bytes, the whole table for this game
	.CFG_ADDRESSWIDTH(4),
	.CFG_LENGTHWIDTH(2)
) hi (
	.clk(clk_sys),
	.reset(reset | hs_hold | ~hs_enable),
	.paused(hs_pause_raw),
	.autosave(1'b1),
	.OSD_STATUS(hs_osd),
	.ioctl_upload(ioctl_upload),
	.ioctl_upload_req(hs_upload_req_raw),
	.ioctl_download(ioctl_download),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_index(ioctl_index[7:0]),
	.data_from_hps(ioctl_dout),
	.data_to_hps(ioctl_din),
	.data_from_ram(hs_dout),
	.data_to_ram(hi_din),
	.ram_address(hi_addr),
	.ram_write(hi_write),
	.ram_intent_read(),
	.ram_intent_write(),
	.pause_cpu(hs_pause_raw),
	.configured(hs_configured)
);

wire [23:0] ch_addr;
wire  [7:0] ch_din;
wire        ch_write, ch_access, ch_pause;
wire  [6:0] ch_avail;

cheats ch (
	.clk(clk_sys),
	.reset(reset),
	.ioctl_download(ioctl_download), .ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr), .ioctl_index(ioctl_index), .ioctl_dout(ioctl_dout),
	.enable(status[38:32]),
	.available(ch_avail),
	.vblank(vblank_core),
	.ram_addr(ch_addr), .ram_din(ch_din), .ram_write(ch_write),
	.ram_access(ch_access), .pause_cpu(ch_pause)
);

assign hs_addr   = hs_pause ? hi_addr  : ch_addr;
assign hs_din    = hs_pause ? hi_din   : ch_din;
assign hs_write  = hs_pause ? hi_write : ch_write;
assign hs_access = hs_pause ? 1'b1     : ch_access;

// ---------------------------------------------------------------------------
// Savestates. The engine parks both CPUs, streams the core's image to a slot
// in DDR3 and back. Its DDR side shares the DDRAM port with screen_rotate and
// fills the gaps; the core's pause is masked while an operation runs, because
// the CPUs have to execute in order to park.
// ---------------------------------------------------------------------------
wire  [1:0] ss_slot;
wire  [7:0] ss_info;
wire        ss_save, ss_load, ss_info_req, ss_status_update;
wire        ss_busy, ss_done_ok, ss_done_fail, ss_was_load;
wire  [1:0] ss_fail_code;
wire        ss_freeze, ss_frozen, ss_parked, ss_resume, ss_active, ss_wr, ss_replay, ss_replay_done;
wire [19:0] ss_addr;
wire [15:0] ss_rdata, ss_wdata;
wire        eng_we, eng_rd;
wire [28:0] eng_addr;
wire [63:0] eng_din;

savestate_ui savestate_ui (
	.clk(clk_sys), .ps2_key(ps2_key), .allow_ss(~reset),
	.status_slot(status[41:40]), .OSD_saveload(status[43:42]),
	.done_ok(ss_done_ok), .done_fail(ss_done_fail), .fail_code(ss_fail_code), .was_load(ss_was_load),
	.ss_save(ss_save), .ss_load(ss_load), .ss_info_req(ss_info_req), .ss_info(ss_info),
	.statusUpdate(ss_status_update), .selected_slot(ss_slot)
);

savestate #(.SS_WORDS(20'h0E180), .DDR_BASE(29'h07C00000), .SLOT_STRIDE(29'h00008000)) savestate (
	.clk(clk_sys), .reset(reset),
	.save_req(ss_save), .load_req(ss_load), .slot(ss_slot), .vblank(vblank_core), .allow(~ioctl_download),
	.ss_freeze(ss_freeze), .ss_frozen(ss_frozen), .ss_parked(ss_parked), .ss_resume(ss_resume), .ss_active(ss_active),
	.ss_addr(ss_addr), .ss_rdata(ss_rdata), .ss_wr(ss_wr), .ss_wdata(ss_wdata),
	.ss_replay(ss_replay), .ss_replay_done(ss_replay_done),
	.busy(ss_busy), .done_ok(ss_done_ok), .done_fail(ss_done_fail), .fail_code(ss_fail_code), .was_load(ss_was_load),
	.clk_ddr(CLK_VIDEO), .ddr_busy(DDRAM_BUSY), .rot_we(rot_we),
	.ddr_we(eng_we), .ddr_rd(eng_rd), .ddr_addr(eng_addr), .ddr_din(eng_din),
	.ddr_dout(DDRAM_DOUT), .ddr_dout_ready(DDRAM_DOUT_READY)
);

// ------------------------------------------------------------------
// The board
// ------------------------------------------------------------------
wire [23:0] rd_rgb;
wire        ce_pix_core;
wire  [8:0] hcount_core, vcount_core;
wire signed [15:0] snd;

sandscrp_core #(.HW_ROMS(1)) core (
	.clk_sys(clk_sys),
	// The CPUs are held in reset for the whole download and until the SDRAM
	// controller is up, so no cache can be asked for a byte that is not there.
	.reset(reset | ~sdram_ready),
	.pause((status[29] | hs_pause | ch_pause) & ~ss_busy),
	.p1_i(p1_i), .p2_i(p2_i), .sys_i(sys_i), .dsw1_i(dsw1_i), .dsw2_i(dsw2_i),
	.osd_flip(status[17]),
	.hs_addr(hs_addr), .hs_din(hs_din), .hs_dout(hs_dout), .hs_write(hs_write), .hs_access(hs_access),
	.ce_pix(ce_pix_core), .hcount(hcount_core), .vcount(vcount_core),
	.hblank(hblank_core), .vblank(vblank_core), .vbl_start(), .rd_rgb(rd_rgb), .snd(snd),
	.rom0_addr(rom0_addr), .rom1_addr(rom1_addr), .roms_addr(roms_addr), .okirom_addr(okirom_addr),
	.rom0_data(rom0_data), .rom1_data(rom1_data), .roms_data(roms_data), .okirom_data(okirom_data),
	.rom0_ready(rom0_ready), .rom1_ready(rom1_ready), .roms_ready(roms_ready),
	.prog_word_addr(prog_word_addr), .prog_word_data(prog_word_data), .prog_ready(prog_ready),
	.z80rom_addr(z80rom_addr), .z80rom_data(z80rom_data), .z80rom_ready(z80rom_ready),
	.okirom_stall(okirom_stall),
	.ss_freeze(ss_freeze), .ss_resume(ss_resume), .ss_active(ss_active),
	.ss_frozen(ss_frozen), .ss_parked(ss_parked),
	.ss_addr(ss_addr), .ss_rdata(ss_rdata), .ss_wr(ss_wr), .ss_wdata(ss_wdata),
	.ss_replay(ss_replay), .ss_replay_done(ss_replay_done),
	.dbg_m68k_pc_addr(), .dbg_ym_writes(), .dbg_oki_writes(),
	.dbg_spr_pass_cycles(), .dbg_spr_late_swaps(), .dbg_wdog_resets(),
	.dbg_ym_snd(), .dbg_oki_snd(), .dbg_ram70(),
	.dbg_reads_rom(), .dbg_reads_ram(), .dbg_writes_ram(), .dbg_acc_other(), .dbg_last_other()
);

// One mono channel on this board, sent to both outputs.
assign AUDIO_L = snd;
assign AUDIO_R = snd;

// ------------------------------------------------------------------
// Video. The core renders in real time on clk_sys; video_retime moves that
// raster onto the 96 MHz video clock, crt_chain applies the analog geometry
// controls, and video_mixer drives VGA_*.
//
// The raster is 384 x 262 at 6 MHz (clk_sys / 8). LINE_CLKS is the video-clock
// count of one line: 96 MHz / (6 MHz / 384) = 6144. DIV is the video clocks
// per pixel, 96 / 6 = 16. See docs/known-issues.md SS-1 -- these follow from
// the timing parameters, and those are a documented unknown.
// ------------------------------------------------------------------
// The video clock is clk_ram, the SDRAM controller's 96 MHz, not a PLL of its
// own. A second 96 MHz altpll from the same 50 MHz reference was written first
// and the fitter simply merged its output into this one -- identical frequency,
// identical reference -- so the separate instance bought nothing and is gone.
// Both sides of the core-to-video crossing are unchanged either way:
// video_retime carries it with its own synchronisers. (The NMK16 cores do run
// a second PLL, but at 112 MHz, which cannot merge.)
wire clk_vid = clk_ram;

wire        rt_ce, rt_hs, rt_vs, rt_hb, rt_vb, rt_vb_hs;
wire [23:0] rt_rgb;
video_retime #(
	// The board's own numbers, in its own pixel units: active columns
	// 0..255 of a 384-pixel line, 262 lines. HSync is placed nominally in
	// the blanking (front porch 32 px, sync 28 px = 4.7 us, back porch 68
	// px); CRT Adjust H-Position trims it downstream. Only mode 0 is used,
	// so mode 1 is given the same geometry rather than a second set.
	.M0_X0(10'd0), .M0_HT(10'd384), .M0_HS(10'd288), .M0_HW(10'd28), .M0_AW(10'd256), .M0_DIV(5'd16),
	.M1_X0(10'd0), .M1_HT(10'd384), .M1_HS(10'd288), .M1_HW(10'd28), .M1_AW(10'd256), .M1_DIV(5'd16),
	.LINE_CLKS(6144), .VTOTAL_P(262)
) video_retime (
	.clk_w(clk_sys), .reset_w(reset), .ce_w(ce_pix_core),
	.hcount_w({1'b0, hcount_core}), .vcount_w({1'b0, vcount_core}), .rgb_w(rd_rgb),
	.mode1(1'b0), .tall240(1'b0),
	.clk_r(clk_vid),
	.ce_r(rt_ce), .rgb_r(rt_rgb), .hs_r(rt_hs), .vs_r(rt_vs), .de_r(),
	.hb_r(rt_hb), .vb_r(rt_vb), .vb_hs_r(rt_vb_hs)
);
assign CLK_VIDEO = clk_vid;

// NMK-28: the scandoubler must be off whenever the rotation framebuffer is
// active. screen_rotate has no backpressure -- it writes on every CE_PIXEL &
// VGA_DE and never looks at DDRAM_BUSY -- so at the doubled pixel rate its
// writes are dropped and the picture comes out cut off. The framework disables
// scanlines in framebuffer mode anyway.
wire       fb_rotating = ~((status[9:8] == 2'd0) | direct_video);
wire [2:0] fx = direct_video ? 3'd0 : status[3:1];
wire       scandoubler_en = ((fx != 3'd0) || forced_scandoubler) && ~fb_rotating;
wire [1:0] sl = fx[2:1];
assign VGA_SL = sl;

wire        vm_ce_pix, vm_hs, vm_vs, vm_hb, vm_vb;
wire [23:0] retimed_rgb;
wire [21:0] vm_gamma_bus;
wire        crt_on = status[101] & ~scandoubler_en & ~fb_rotating;
crt_chain #(
	.HTOTAL0(10'd384), .HTOTAL1(10'd384), .DIV0(5'd16), .DIV1(5'd16),
	.VTOTAL(262), .LINE_PX(272), .VSIZE_MAX(4)
) crt_chain (
	.clk(clk_vid), .ce_in(rt_ce), .rgb_in(rt_rgb),
	.hs_in(rt_hs), .vs_in(rt_vs), .hb_in(rt_hb), .vb_in(rt_vb), .vb_hs_in(rt_vb_hs),
	.mode1(1'b0), .enable(crt_on),
	.hsize($signed(status[100:96])), .hpos_raw(status[85:79]),
	.vshift($signed(status[78:74])), .vsize_code(status[107:104]),
	.vsize_mode(status[108]),
	.ce_out(vm_ce_pix), .rgb_out(retimed_rgb),
	.hs_out(vm_hs), .vs_out(vm_vs), .hb_out(vm_hb), .vb_out(vm_vb)
);

video_mixer #(.LINE_LENGTH(272), .HALF_DEPTH(0), .GAMMA(0)) video_mixer (
	.CLK_VIDEO(CLK_VIDEO),
	.ce_pix(vm_ce_pix),
	.CE_PIXEL(CE_PIXEL),
	.scandoubler(scandoubler_en),
	.hq2x(fx == 3'd1),
	.gamma_bus(vm_gamma_bus),
	.R(retimed_rgb[23:16]), .G(retimed_rgb[15:8]), .B(retimed_rgb[7:0]),
	.HSync(vm_hs), .VSync(vm_vs), .HBlank(vm_hb), .VBlank(vm_vb),
	.HDMI_FREEZE(1'b0), .freeze_sync(),
	.VGA_R(VGA_R), .VGA_G(VGA_G), .VGA_B(VGA_B),
	.VGA_VS(VGA_VS), .VGA_HS(VGA_HS), .VGA_DE(VGA_DE)
);

// ------------------------------------------------------------------
// Orientation. Sand Scorpion is ROT90 in MAME, so the image has to be turned
// CLOCKWISE to stand upright, which is screen_rotate's rotate_ccw = 0 case --
// the opposite of the NMK16 sets, which are ROT270. "Vert 90" is therefore
// the MAME-correct choice here and is offered first; "Vert 270" is for a
// cabinet whose monitor is mounted the other way round. Flip screen does not
// go through here: it is the core's own readback mirror, which reaches the
// analog output and direct video too.
// ------------------------------------------------------------------
wire  [1:0] orientation = status[9:8];
wire        video_rotated;
wire        no_rotate = (orientation == 2'd0) | direct_video;
wire        rotate_ccw = (orientation == 2'd2);
wire        rot_we;
wire [28:0] rot_addr;
wire [63:0] rot_din;
wire  [7:0] rot_be;
screen_rotate screen_rotate (
	.CLK_VIDEO(CLK_VIDEO), .CE_PIXEL(CE_PIXEL),
	.VGA_R(VGA_R), .VGA_G(VGA_G), .VGA_B(VGA_B), .VGA_HS(VGA_HS), .VGA_VS(VGA_VS), .VGA_DE(VGA_DE),
	.rotate_ccw(rotate_ccw), .no_rotate(no_rotate), .flip(1'b0), .video_rotated(video_rotated),
	.FB_EN(FB_EN), .FB_FORMAT(FB_FORMAT), .FB_WIDTH(FB_WIDTH), .FB_HEIGHT(FB_HEIGHT),
	.FB_BASE(FB_BASE), .FB_STRIDE(FB_STRIDE), .FB_VBL(FB_VBL), .FB_LL(FB_LL),
	.DDRAM_CLK(DDRAM_CLK), .DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(), .DDRAM_ADDR(rot_addr),
	.DDRAM_DIN(rot_din), .DDRAM_BE(rot_be), .DDRAM_WE(rot_we), .DDRAM_RD()
);
// screen_rotate's write wins any cycle it appears on; the savestate engine
// fills the gaps. Both run on CLK_VIDEO.
assign DDRAM_BURSTCNT = 8'd1;
assign DDRAM_ADDR     = rot_we ? rot_addr : eng_addr;
assign DDRAM_DIN      = rot_we ? rot_din  : eng_din;
assign DDRAM_BE       = rot_we ? rot_be   : 8'hFF;
assign DDRAM_WE       = rot_we | eng_we;
assign DDRAM_RD       = eng_rd;
assign FB_FORCE_BLANK = 1'b0;

reg [26:0] act_cnt;
always @(posedge clk_sys) act_cnt <= act_cnt + 1'd1;
assign LED_USER = act_cnt[26] ? act_cnt[25:18] > act_cnt[7:0] : act_cnt[25:18] <= act_cnt[7:0];

endmodule
