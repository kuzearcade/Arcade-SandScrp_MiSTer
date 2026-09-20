# Sand Scorpion timing constraints.
#
# sys/sys_top.sdc is the MiSTer framework's own base file: the root 50 MHz
# clock definitions, the HPS/SPI/HDMI-I2C virtual clocks, the exclusive
# clock-group partitioning that keeps unrelated domains from being timed
# against each other, and a long list of false paths for OSD and scaler
# configuration signals. The Template.sdc scaffold never sourced it, which
# left derive_pll_clocks with no properly defined root clocks and made
# Quartus try to relate every domain to every other one. That was the whole
# content of the "Design is not fully constrained" warnings and the bogus
# negative-slack paths seen on the sibling NMK16 project.
source sys/sys_top.sdc

derive_pll_clocks
derive_clock_uncertainty

# ------------------------------------------------------------------
# Core clock groups
# ------------------------------------------------------------------
# The game logic (68000, Z80, YM2203, OKI, video) runs on clk_sys at
# 48 MHz and rtl/sdram.sv on clk_ram at 96 MHz, both outputs of rtl/pll.v.
# That file is a hand-written altpll instance rather than MegaWizard
# altera_pll IP, so its hierarchical clock names do not match the
# (*|pll|pll_inst|altera_pll_i|...) wildcard sys/sys_top.sdc uses, and
# without the loop below neither output lands in any exclusive group.
#
# Each PLL output must be its OWN group, not one shared group. They come
# from a single VCO, so one group would make Quartus time every
# clk_sys/clk_ram path synchronously against the worst-case edge pair of a
# 20.8 ns and 10.4 ns clock, and fail on the address and data paths that
# the toggle-style req/ack protocol in rtl/sdram.sv makes deliberately
# irrelevant: the payload is held from the toggle until ack, and is only
# sampled after a two-flop synchroniser has seen the toggle. The foreach
# gives every matching output its own group, whatever Quartus decides to
# name the counters this compile.
set core_pll_groups {}
foreach_in_collection c [get_clocks {emu|pll*|altpll_component|*PLL_OUTPUT_COUNTER|divclk}] {
	lappend core_pll_groups -group [get_clock_info -name $c]
}
# There is no third PLL: CLK_VIDEO is clk_ram, the same 96 MHz output the SDRAM
# controller uses, so the loop above already covers the video chain.
set_clock_groups -exclusive \
	{*}$core_pll_groups \
	-group [get_clocks {pll_hdmi|pll_hdmi_inst|altera_pll_i|*[0].*|divclk}] \
	-group [get_clocks {pll_audio|pll_audio_inst|altera_pll_i|*[0].*|divclk}] \
	-group [get_clocks {spi_sck}] \
	-group [get_clocks {hdmi_sck}] \
	-group [get_clocks {*|h2f_user0_clk}] \
	-group [get_clocks {FPGA_CLK1_50}] \
	-group [get_clocks {FPGA_CLK2_50}] \
	-group [get_clocks {FPGA_CLK3_50}]

# ------------------------------------------------------------------
# CRT Adjust multicycle
# ------------------------------------------------------------------
# crt_vsize writes o_active_cyc on the second clock of an output line and
# consumes it in the DE-window clamp on the fourth, a 22-bit add and
# compare that is the worst path on the video clock. Two clocks are always
# available between the two, so it is a legitimate two-cycle path. Only
# that source is excepted; the clamp's other inputs can change on any
# clock and stay single-cycle.
set vsz_ac [get_registers {*|crt_chain:crt_chain|crt_vsize:u_vsize|o_active_cyc[*]}]
set vsz_ds [get_registers {*|crt_chain:crt_chain|crt_vsize:u_vsize|o_de_start[*]}]
set_multicycle_path -setup 2 -from $vsz_ac -to $vsz_ds
set_multicycle_path -hold  1 -from $vsz_ac -to $vsz_ds
