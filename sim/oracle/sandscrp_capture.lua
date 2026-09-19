-- Arcade-SandScrp_MiSTer — MAME oracle capture for Sand Scorpion.
--
--   SS_OUT=<dir> SS_FRAMES=<n> [SS_PIX=1] [SS_STATE=1] [SS_TAPS=1] [SS_FLIP=1] \
--     mame sandscrp -rompath mame_roms -video none -sound none -nothrottle \
--          -autoboot_script sim/oracle/sandscrp_capture.lua
--
-- Everything is keyed by the capture's own frame counter F (0 for the first
-- frame_done after boot). MAME ordering (src/emu/screen.cpp vblank_begin):
-- at vblank start the whole frame is rendered (screen_update), then this
-- script's frame_done runs, THEN the VBLANK IRQ is raised and the sprite
-- IRQ + Pandora eof() follow, all at the same emulated instant. Hence:
--   frames/f<F>.raw    the pixels of frame F (256x224 u32 host-endian
--                      xRGB, as screen:pixels() returns them; convert with
--                      tools/ss_frames.py)
--   state/s<F>.bin     VIEW2 VRAM 0x400000-0x403FFF (16 KB, u16 LE), VIEW2
--                      regs 0x300000-0x30001F (32 B), palette
--                      0x600000-0x600FFF (4 KB), Pandora RAM 0x500000-
--                      0x501FFF (8 KB, u16 LE, byte in both lanes), read at
--                      the same instant. The tilemap/palette state is what
--                      frame F shows; the Pandora RAM is what eof(F) draws,
--                      i.e. what frame F+1 shows.
--   taps.log           one line per tapped 68000 access:
--                      <r|w> F vpos addr data mask pc  with vpos derived
--                      from time_until_vblank_start (MAME's 256-line frame,
--                      2500 us vblank at the end of it, so vblank starts at
--                      vpos ~217.6).
--   index.txt          F -> screen:frame_number(), machine time, and the
--                      DSW port values read through the ioport manager.
-- Tap handles are kept in globals: a local goes out of scope, is garbage
-- collected, and the tap silently stops (NMK16 lesson).

-- MAME re-runs the autoboot script after every machine reset (mame.cpp
-- mame_machine_manager::reset re-arms the autoboot timer), and this driver's
-- 3 s watchdog fires once during the cold boot (measured 2026-09-19: soft
-- reset at t=3.000 s, frame 179). A second instance would re-register a
-- second frame_done and truncate every output file, so only the first load
-- does anything; resets are logged as "RESET" lines instead.
if _G.ss_capture_loaded then
	print("[ss] autoboot script re-run after a machine reset: ignored (first instance keeps capturing)")
	return
end
_G.ss_capture_loaded = true

local out      = os.getenv("SS_OUT") or "ss_capture"
local maxf     = tonumber(os.getenv("SS_FRAMES") or "600")
local do_pix   = (os.getenv("SS_PIX") or "1") == "1"
local do_state = (os.getenv("SS_STATE") or "1") == "1"
local do_taps  = (os.getenv("SS_TAPS") or "1") == "1"
local do_flip  = (os.getenv("SS_FLIP") or "0") == "1"
local ram_every = tonumber(os.getenv("SS_RAM_EVERY") or "0")  -- dump 64 KB work RAM every N frames (0 = never)

os.execute("mkdir -p '" .. out .. "/frames' '" .. out .. "/state' '" .. out .. "/ram'")

local machine = manager.machine
local scr     = machine.screens[":screen"]
local cpu     = machine.devices[":maincpu"]
local space   = cpu.spaces["program"]
local ioport  = machine.ioport

local F = 0
local idx  = io.open(out .. "/index.txt", "w")
local taps = do_taps and io.open(out .. "/taps.log", "w") or nil

-- MAME's screen: 256 lines/frame at 60 Hz, vblank = the last 2500 us.
local T_FRAME = scr.frame_period
local T_SCAN  = scr.scan_period
local T_VB    = 2500e-6
local function vpos_now()
	local tv = scr:time_until_vblank_start():as_double()
	local t = ((T_FRAME - T_VB) - tv) % T_FRAME
	return math.floor(t / T_SCAN + 1e-9), tv
end

if do_flip then
	local p = ioport.ports[":DSW2"]
	for name, f in pairs(p.fields) do
		if name == "Flip Screen" then f.user_value = 0; print("[ss] Flip Screen DIP forced On (user_value=0)") end
	end
end

local dumping = false
local function tapline(kind, offset, data, mask)
	if dumping then return end
	local vp, tv = vpos_now()
	taps:write(string.format("%s %d %d %06x %04x %04x %06x\n", kind, F, vp, offset, data, mask, cpu.state["PC"].value))
end

if do_taps then
	-- globals, deliberately
	ss_tap_w_irq   = space:install_write_tap(0x100000, 0x100001, "ss_irqack", function(o, d, m) tapline("w", o, d, m) end)
	ss_tap_r_irq   = space:install_read_tap (0x800000, 0x800001, "ss_irqcause", function(o, d, m) tapline("r", o, d, m) end)
	ss_tap_w_view2 = space:install_write_tap(0x300000, 0x30001f, "ss_view2w", function(o, d, m) tapline("w", o, d, m) end)
	ss_tap_r_view2 = space:install_read_tap (0x300000, 0x30001f, "ss_view2r", function(o, d, m) tapline("r", o, d, m) end)
	ss_tap_w_calc  = space:install_write_tap(0x200000, 0x20001f, "ss_calcw",  function(o, d, m) tapline("w", o, d, m) end)
	ss_tap_r_calc  = space:install_read_tap (0x200000, 0x20001f, "ss_calcr",  function(o, d, m) tapline("r", o, d, m) end)
	ss_tap_w_snd   = space:install_write_tap(0xe00000, 0xe40001, "ss_sndw",   function(o, d, m) tapline("w", o, d, m) end)
	ss_tap_r_snd   = space:install_read_tap (0xe00000, 0xe40001, "ss_sndr",   function(o, d, m) tapline("r", o, d, m) end)
	ss_tap_w_coin  = space:install_write_tap(0xa00000, 0xa00001, "ss_coinw",  function(o, d, m) tapline("w", o, d, m) end)
	ss_tap_r_wdog  = space:install_read_tap (0xec0000, 0xec0001, "ss_wdogr",  function(o, d, m) tapline("r", o, d, m) end)
	-- anything the driver leaves unmapped: 0x100002-0x1FFFFF, 0x200020-0x2FFFFF, ...
	ss_tap_r_unm1  = space:install_read_tap (0x080000, 0x0fffff, "ss_unm1",   function(o, d, m) tapline("u", o, d, m) end)
	ss_tap_r_unm2  = space:install_read_tap (0x100000, 0x1fffff, "ss_unm2",   function(o, d, m) tapline("u", o, d, m) end)
	ss_tap_r_unm3  = space:install_read_tap (0x200020, 0x2fffff, "ss_unm3",   function(o, d, m) tapline("u", o, d, m) end)
	ss_tap_r_unm4  = space:install_read_tap (0x300020, 0x3fffff, "ss_unm4",   function(o, d, m) tapline("u", o, d, m) end)
	ss_tap_r_unm5  = space:install_read_tap (0x404000, 0x4fffff, "ss_unm5",   function(o, d, m) tapline("u", o, d, m) end)
	ss_tap_r_unm6  = space:install_read_tap (0x502000, 0x5fffff, "ss_unm6",   function(o, d, m) tapline("u", o, d, m) end)
	ss_tap_r_unm7  = space:install_read_tap (0x601000, 0x6fffff, "ss_unm7",   function(o, d, m) tapline("u", o, d, m) end)
	ss_tap_r_unm8  = space:install_read_tap (0x710000, 0x7fffff, "ss_unm8",   function(o, d, m) tapline("u", o, d, m) end)
	ss_tap_r_unm9  = space:install_read_tap (0x800002, 0x9fffff, "ss_unm9",   function(o, d, m) tapline("u", o, d, m) end)
	ss_tap_r_unmA  = space:install_read_tap (0xa00000, 0xafffff, "ss_unmA",   function(o, d, m) tapline("u", o, d, m) end)
	ss_tap_r_unmB  = space:install_read_tap (0xb00008, 0xdfffff, "ss_unmB",   function(o, d, m) tapline("u", o, d, m) end)
	ss_tap_r_unmC  = space:install_read_tap (0xe00002, 0xe3ffff, "ss_unmC",   function(o, d, m) tapline("u", o, d, m) end)
	ss_tap_r_unmD  = space:install_read_tap (0xe40002, 0xebffff, "ss_unmD",   function(o, d, m) tapline("u", o, d, m) end)
	ss_tap_r_unmE  = space:install_read_tap (0xec0002, 0xffffff, "ss_unmE",   function(o, d, m) tapline("u", o, d, m) end)
end

ss_reset_notifier = emu.add_machine_reset_notifier(function()
	local vp = vpos_now()
	idx:write(string.format("RESET at F=%d time %.6f frame_number %d\n", F, machine.time:as_double(), scr:frame_number()))
	if taps then taps:write(string.format("RESET %d %d\n", F, vp)) end
	print(string.format("[ss] machine reset at F=%d time %.4f", F, machine.time:as_double()))
end)

ss_frame_done = function()
	if do_pix then
		local pix, w, h = scr:pixels()
		local f = io.open(string.format("%s/frames/f%05d.raw", out, F), "wb")
		f:write(pix); f:close()
	end
	dumping = true
	if do_state then
		local f = io.open(string.format("%s/state/s%05d.bin", out, F), "wb")
		f:write(space:read_range(0x400000, 0x403fff, 16, 2))
		f:write(space:read_range(0x300000, 0x30001f, 16, 2))
		f:write(space:read_range(0x600000, 0x600fff, 16, 2))
		f:write(space:read_range(0x500000, 0x501fff, 16, 2))
		f:close()
	end
	if ram_every > 0 and (F % ram_every) == 0 then
		local f = io.open(string.format("%s/ram/r%05d.bin", out, F), "wb")
		f:write(space:read_range(0x700000, 0x70ffff, 16, 2))
		f:close()
	end
	dumping = false
	idx:write(string.format("%d %d %.6f dsw1=%02x dsw2=%02x\n", F, scr:frame_number(), machine.time:as_double(),
		ioport.ports[":DSW1"]:read() & 0xff, ioport.ports[":DSW2"]:read() & 0xff))
	if taps then taps:write(string.format("F %d\n", F)) end
	F = F + 1
	if F >= maxf then
		idx:close(); if taps then taps:close() end
		print(string.format("[ss] captured %d frames into %s", F, out))
		machine:exit()
	end
end
emu.register_frame_done(ss_frame_done)
print(string.format("[ss] capture to %s: pix=%s state=%s taps=%s frames=%d T_FRAME=%.6f T_SCAN=%.6f",
	out, tostring(do_pix), tostring(do_state), tostring(do_taps), maxf, T_FRAME, T_SCAN))
