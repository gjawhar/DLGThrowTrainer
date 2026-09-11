-- ThrowTrainer execution harness: mocks the Ethos globals, runs the SAME
-- require chain main.lua uses, then drives the app through the 2.0 flows.
-- Run from a scratch dir holding copies of the 5 .lua files + a Files/ dir.

local failures = 0
local function check(cond, msg)
  if cond then print("  ok   " .. msg) else failures = failures + 1; print("  FAIL " .. msg) end
end

-- ---------------------------------------------------------------- mocks

CATEGORY_TELEMETRY_SENSOR, CATEGORY_LOGIC_SWITCH, CATEGORY_FLIGHT, CATEGORY_TRIM = 1, 2, 3, 4
OPTION_SENSOR_MAX = 99
FONT_XS, FONT_S, FONT_M, FONT_L, FONT_XL = 0, 1, 2, 3, 4
SOLID, DOTTED = 0, 1
KEY_ROTARY_RIGHT, KEY_ROTARY_LEFT, KEY_ENTER_BREAK, KEY_RTN_FIRST, KEY_EXIT_FIRST = 11, 12, 13, 14, 15
-- Real 26.1.2 values (Dial In probe): a tap is TOUCH_START then TOUCH_END.
EVT_KEY, EVT_TOUCH = 0, 1
TOUCH_START, TOUCH_END, TOUCH_MOVE, TOUCH_LONG = 16640, 16641, 16642, 16643

-- Controllable source values. rud is writable (a VAR); trims are not.
-- camber/elev are PER FLIGHT MODE, like the real trims (TrimProbe-confirmed):
-- a read returns the active mode's value, so a change made "in Zoom" must
-- not leak into Launch's reading the way a single global would.
SIM = { alt = 0, altPeak = 0, altAge = 100, call = -100, mom = -100,
        fm = 0, camber = { [2] = 0, [3] = 0 }, elev = { [2] = 0, [3] = 0 },
        rud = 0, rudSettleAt = 0, fs = { -100, -100, -100, -100 } }

local function mkSrc(get, set, age, unit)
  local s = {}
  function s:value(opts)
    if opts and opts.options == OPTION_SENSOR_MAX then return SIM.altPeak end
    return get()
  end
  if set then
    local base = s.value
    function s:value(x, ...)
      if type(x) == "number" then set(x) return end
      return base(self, x, ...)
    end
  end
  function s:age() return age and age() or 0 end
  function s:stringUnit() return unit or "" end
  function s:name() return "mock" end
  return s
end

system = {
  getSource = function(spec)
    if spec.category == CATEGORY_TELEMETRY_SENSOR and spec.name == "Altitude" then
      return mkSrc(function() return SIM.alt end, nil, function() return SIM.altAge end, "m")
    elseif spec.category == CATEGORY_LOGIC_SWITCH and spec.name == "ALT_CALL" then
      return mkSrc(function() return SIM.call end)
    elseif spec.category == CATEGORY_LOGIC_SWITCH and spec.name == "MOM_LAUNCH" then
      return mkSrc(function() return SIM.mom end)
    elseif spec.category == CATEGORY_FLIGHT and spec.member == 0 then
      return mkSrc(function() return SIM.fm end)
    elseif spec.category == CATEGORY_TRIM and spec.member == 2 then
      return mkSrc(function() return SIM.camber[SIM.fm] or 0 end)
    elseif spec.category == CATEGORY_TRIM and spec.member == 1 then
      return mkSrc(function() return SIM.elev[SIM.fm] or 0 end)
    elseif spec.category == 12 then
      local m = spec.member
      return mkSrc(function() return SIM.fs[m + 1] end)
    elseif spec.category == nil and spec.name == "V_RudOffset" then
      -- Reads before SIM.rudSettleAt return 0 regardless -- models the
      -- radio reporting an unsettled VAR value for a moment after power-on.
      return mkSrc(function()
        if os.time() < SIM.rudSettleAt then return 0 end
        return SIM.rud
      end, function(x) SIM.rud = x end)
    end
    return nil
  end,
  getVersion = function() return { board = "X20RS" } end,
  playHaptic = function() end,
}

model = { id = function() return { 0, 1 } end, name = function() return "DLG V220X" end }

local drawn = {}
lcd = {
  color = function() end, pen = function() end, font = function() end,
  invalidate = function() end, resetFocusTimeout = function() end,
  hasFocus = function() return true end, isSwiping = function() return false end,
  RGB = function(r, g, b) return { r, g, b } end, GREY = function(v) return { v, v, v } end,
  getWindowSize = function() return 800, 480 end,
  getTextSize = function(t) return #tostring(t) * 8, 18 end,
  drawText = function(x, y, t) assert(type(t) == "string", "drawText got " .. type(t)); drawn[#drawn + 1] = t end,
  drawFilledRectangle = function() end, drawRectangle = function() end, drawLine = function() end,
}
form = { openDialog = function() end, clear = function() end }

-- ---------------------------------------------------------------- require chain (as main.lua)

local core   = assert(loadfile("core.lua"))()
local draw   = assert(loadfile("draw.lua"))(core)
local config = assert(loadfile("config.lua"))(core, draw)
local screen = assert(loadfile("screen.lua"))(core, draw, config)
print("require chain loaded")

local app = screen.new({ keys = { "CHANGE", "LOG", "CONFIG", "SETUP" }, dialogs = false, needsFocus = true })

local function tick() core.wakeup(); drawn = {}; app.paint(800, 480) end
local function sawText(pat) for _, t in ipairs(drawn) do if t:find(pat, 1, true) then return true end end return false end
local function throw(height)
  SIM.fm = 2; tick(); SIM.fm = 3; tick(); SIM.fm = 0
  SIM.altPeak = height; SIM.call = 100; tick(); SIM.call = -100; tick()
end

-- ---------------------------------------------------------------- scenario

-- Clock the app can be fast-forwarded on: core.lua reads the global
-- os.time at call time, so bumping tOff skips settle/dwell windows
-- without real sleeps.
local realTime, tOff = os.time, 0
os.time = function() return realTime() + tOff end

print("\n-- boot + seed (V_RudOffset really at +5, first reads unsettled at 0)")
SIM.rud = 5; SIM.rudSettleAt = os.time() + 2
core.init()
check(core.S.ready, "core.init ready")
tick()
check(app.V.screen == 1, "starts on MAIN")
check(sawText("FS1") and sawText("FS4"), "key row carries FS1..FS4 tags")
check(sawText("CHANGES"), "4th key labelled CHANGES")
check(#core.S.launches == 10, "fresh glider seeded with 10 throws (" .. #core.S.launches .. ")")
check(core.S.baselineGrp == 0, "baselineGrp starts 0")
check(core.S.baseRud == nil, "rud baseline NOT read during the settle window")
tOff = tOff + 3; tick()
check(core.S.baseRud == 5, "rud baseline read after settling (" .. tostring(core.S.baseRud) .. ")")
SIM.fm = 2; tick(); SIM.fm = 0
check(not core.hasPendingSetup(), "no phantom rud pending after boot")
-- back to a clean zero for the rest of the script
SIM.rud = 0; core.captureSetupBaseline(); tOff = tOff + 3; tick()
check(core.S.baseRud == 0, "rud baseline re-captured at 0")

print("\n-- first real throw purges seed")
throw(60)
check(#core.S.launches == 1, "seed purged, 1 real throw (" .. #core.S.launches .. ")")
throw(65); throw(70)
check(#core.S.launches == 3, "3 real throws")

print("\n-- stale gate: refuses at default, records with limit 0")
SIM.altAge = 5000
throw(50)
check(#core.S.launches == 3, "stale throw refused with default 2 s gate")
check(sawText("stale telemetry"), "stale status shown")
core.S.cfg.stale = 0
throw(50)
check(#core.S.launches == 4, "throw recorded with stale gate off")
core.undo()                                   -- keep later averages unchanged
core.S.cfg.stale = 2; SIM.altAge = 100
check(#core.S.launches == 3, "test throw removed again")

print("\n-- rud change in Launch -> Setup Change Detected")
SIM.fm = 2; tick()
SIM.rud = 22; tick()
check(core.hasPendingSetup(), "rud +22 pending")
check(app.V.screen == 2, "auto-switched to SETUP (screen=" .. app.V.screen .. ")")
check(sawText("SETUP CHANGE DETECTED"), "header says detected")
check(sawText("RUDDER OFFSET +22"), "pill shows RUDDER OFFSET +22")

print("\n-- ACCEPT (FS2) refused while pending")
app.pressKey(2); tick()
check(#core.S.events == 0 or core.S.events[#core.S.events].type ~= "accept", "no accept logged while pending")
check(sawText("throw to confirm the pending change first"), "refusal status shown on SETUP screen")

print("\n-- RTN leaves SETUP and stays on MAIN")
app.event(KEY_RTN_FIRST); tick(); tick()
check(app.V.screen == 1, "back on MAIN after RTN (screen=" .. app.V.screen .. ")")

print("\n-- confirming throw logs a setup mark and auto-closes")
app.pressKey(4); tick()
check(app.V.screen == 2, "CHANGES key opens SETUP manually")
throw(80)
check(app.V.screen == 1, "back on MAIN after confirming throw")
local last = core.S.events[#core.S.events]
check(last and last.type == "setup" and last.rud == 22, "setup mark logged with rud=22")
check(not core.hasPendingSetup(), "nothing pending after confirm")
throw(82); throw(84)

print("\n-- COMPARE: one mark -> Previous set, figure = previous set")
local st = core.stats(12)
check(st.marksSinceBaseline == 1, "1 mark since baseline")
check(st.baselineAvg == st.cmpBeforeAvg, "baselineAvg equals previous set with one mark")
tick(); check(sawText("Previous set"), "label Previous set")

print("\n-- second mark (camber in Zoom) -> Original baseline reaches back")
SIM.fm = 3; tick(); SIM.camber[3] = 5; tick()
check(app.V.screen == 2, "auto-switched again")
throw(90); throw(92)
st = core.stats(12)
check(st.marksSinceBaseline == 2, "2 marks since baseline")
check(math.abs(st.baselineAvg - 65) < 0.01, "baselineAvg is original set avg 65 (got " .. tostring(st.baselineAvg) .. ")")
check(math.abs(st.cmpBeforeAvg - 82) < 0.01, "previous set avg 82 (got " .. tostring(st.cmpBeforeAvg) .. ")")
tick(); check(sawText("Original baseline"), "label Original baseline")

print("\n-- manual CHANGES visit with nothing pending stays open, shows drift")
app.pressKey(4); tick(); tick(); tick()
check(app.V.screen == 2, "SETUP stays open with nothing pending")
check(sawText("CURRENT SETUP"), "header says CURRENT SETUP")
check(sawText("RUDDER OFFSET +22"), "confirmed rud drift still shown")
check(sawText("REFLEX +5"), "confirmed zoom camber drift shown as REFLEX +5")
check(sawText("2 changes since baseline"), "footer counts marks since baseline")
local d = core.driftThisSession()
check(d.rud == 22 and d.zoomCamber == 5 and d.launchCamber == 0, "driftThisSession sums confirmed marks")

print("\n-- CHANGES key row: FS tags, blue confirmed pills")
check(sawText("FS1") and sawText("REVERT") and sawText("RUD OFFSET"), "CHANGES has its own FS key row")

print("\n-- REVERT (FS3) undoes everything since baseline")
local tb = core.revertTargetsToBaseline()
check(#tb == 2, "two axes to revert (got " .. #tb .. ")")
app.pressKey(3); tick()
check(app.V.screen == 3 and sawText("Revert to baseline?"), "Revert Confirm for baseline")
app.event(KEY_ROTARY_RIGHT, 1); app.event(KEY_ENTER_BREAK); tick()
check(SIM.rud == 0, "rudder offset written back to 0 (" .. tostring(SIM.rud) .. ")")
check(app.V.screen == 6, "Reverting screen for the trim (screen=" .. app.V.screen .. ")")
SIM.fm = 3; SIM.camber[3] = 0; tick(); tick()
check(app.V.screen == 6 and app.V.revertDone, "stays on Reverting in the done state (screen=" .. app.V.screen .. ")")
check(sawText("REVERT COMPLETE"), "done header shown")
app.event(KEY_RTN_FIRST); tick()
check(app.V.screen == 1, "RTN returns to MAIN from the done state")
last = core.S.events[#core.S.events]
check(last and last.type == "revert", "revert logged")
d = core.driftThisSession()
check(d.rud == 0 and d.zoomCamber == 0, "drift reads zero after revert")
SIM.fm = 0; app.pressKey(4); tick()
check(app.V.screen == 2 and sawText("No changes since baseline"), "CHANGES shows nothing changed")

print("\n-- rudder edit is a deliberate step (FS4)")
local rudBefore = SIM.rud
app.event(KEY_ROTARY_RIGHT, 1); tick()
check(SIM.rud == rudBefore, "wheel alone does not touch rudder offset")
check(app.V.setupFocus == 2 and not app.V.rudEdit, "wheel moved key focus 1 -> 2")
app.event(KEY_ROTARY_RIGHT, 1); app.event(KEY_ROTARY_RIGHT, 1); tick()
check(app.V.setupFocus == 4, "focus on RUD OFFSET")
app.event(KEY_ENTER_BREAK); tick()
check(app.V.rudEdit and sawText("EDITING"), "ENTER on RUD OFFSET enters edit mode")
app.event(KEY_ROTARY_RIGHT, 1); tick()
check(SIM.rud == rudBefore + 1, "wheel nudges rudder offset while editing")
app.event(KEY_ROTARY_LEFT, 1); tick()
check(SIM.rud == rudBefore, "nudged back")
app.event(KEY_RTN_FIRST); tick()
check(not app.V.rudEdit and app.V.screen == 2, "RTN leaves edit mode but stays on the screen")
app.event(KEY_ROTARY_LEFT, 1); app.event(KEY_ROTARY_LEFT, 1); tick()
check(app.V.setupFocus == 2, "wheel moves focus back to ACCEPT")

print("\n-- ACCEPT two-step")
app.event(KEY_ENTER_BREAK); tick()
check(app.V.acceptArmed, "first ENTER arms")
check(sawText("SURE?"), "button reads SURE?")
app.event(KEY_ENTER_BREAK); tick()
last = core.S.events[#core.S.events]
check(last and last.type == "accept", "accept event logged")
check(core.S.baselineGrp == last.grp, "baselineGrp moved to accept grp")
check(app.V.screen == 1, "back on MAIN after accept")
st = core.stats(12)
check(st.marksSinceBaseline == 0, "0 marks since baseline after accept")

print("\n-- Review Log renders accept row")
app.pressKey(2); tick()
check(app.V.screen == 4, "on LOG")
check(sawText("BASELINE ACCEPTED"), "accept row rendered")
check(sawText("MARK"), "mark rows rendered")
check(sawText("current set") and sawText("previous set"), "throw rows say current/previous set")

print("\n-- any throw returns to Main, from any screen")
throw(75)
check(app.V.screen == 1, "throw from Review Log -> MAIN (screen=" .. app.V.screen .. ")")
app.pressKey(4); tick()
check(app.V.screen == 2 and not core.hasPendingSetup(), "on CHANGES with nothing pending")
throw(77)
check(app.V.screen == 1, "throw from CHANGES with nothing pending -> MAIN")

print("\n-- persistence: reload derives baselineGrp from the log")
local core2 = assert(loadfile("core.lua"))()
core2.init()
check(core2.S.baselineGrp == last.grp, "baselineGrp re-derived on reload (" .. tostring(core2.S.baselineGrp) .. ")")
local d2, n2 = core2.driftThisSession()
check(n2 == 0 and d2.rud == 0 and d2.zoomCamber == 0, "drift this session is all zero after a reload")

print("\n-- revert flow paints")
-- select the setup mark row (revertable) in the log and open revert confirm
local rows
app.pressKey(2); tick()
for i = 1, 30 do
  app.V.logSel = i; tick()
  app.event(KEY_ENTER_BREAK); tick()
  if app.V.screen == 3 then break end
  app.V.screen = 4
end
check(app.V.screen == 3, "Revert Confirm reached (screen=" .. app.V.screen .. ")")
check(sawText("Revert to this mark?"), "revert confirm header")
app.event(KEY_ROTARY_RIGHT, 1); app.event(KEY_ENTER_BREAK); tick()
check(app.V.screen == 6 or app.V.screen == 1, "Reverting screen or auto-completed (screen=" .. app.V.screen .. ")")
if app.V.screen == 6 then
  check(sawText("REVERTING TO MARK") or sawText("REVERT COMPLETE"), "reverting header")
  -- Match each outstanding trim to whatever target the revert computed
  -- (none left if it completed on the first paint).
  local pr = core.revertProgress()
  for _, a in ipairs(pr and pr.axes or {}) do
    SIM.fm = a.fm
    if a.axis == "camber" then SIM.camber[a.fm] = a.target else SIM.elev[a.fm] = a.target end
    tick()
  end
  tick()
end
check(app.V.screen == 6 and app.V.revertDone, "Reverting shows done (screen=" .. app.V.screen .. ")")
throw(88)
check(app.V.screen == 1, "a throw returns to MAIN from the done state (screen=" .. app.V.screen .. ")")
last = core.S.events[#core.S.events]
check(last and last.type == "revert", "revert event logged (" .. tostring(last and last.type) .. ")")

print("\n-- touch: only TOUCH_END acts, and a screen-changing key can't see its own tap's other phases")
tick()
local kr = app.V.keyRects[4]
check(kr ~= nil, "CHANGES key rect recorded by paint")
if kr then
  local cx, cy = kr.x + kr.w / 2, kr.y + kr.h / 2
  app.event(TOUCH_START, cx, cy, EVT_TOUCH); tick()
  check(app.V.screen == 1, "press phase alone does nothing (screen=" .. app.V.screen .. ")")
  app.event(TOUCH_END, cx, cy, EVT_TOUCH); tick()
  check(app.V.screen == 2, "release phase opens CHANGES (screen=" .. app.V.screen .. ")")
  app.event(TOUCH_MOVE, cx, cy, EVT_TOUCH); app.event(TOUCH_LONG, cx, cy, EVT_TOUCH); tick()
  check(app.V.screen == 2, "move/long phases landing on the new screen are consumed (screen=" .. app.V.screen .. ")")
  app.event(KEY_RTN_FIRST, nil, nil, EVT_KEY); tick(); tick()
  check(app.V.screen == 1, "RTN (an EVT_KEY event) still works (screen=" .. app.V.screen .. ")")
end

print("\n-- small layout")
drawn = {}; app.paint(640, 360); app.V.screen = 2; app.paint(640, 360); app.V.screen = 4; app.paint(640, 360)
app.V.screen = 1
check(true, "640x360 paints without error")

print(string.format("\n%s (%d failure%s)", failures == 0 and "ALL PASSED" or "FAILED", failures, failures == 1 and "" or "s"))
os.exit(failures == 0 and 0 or 1)
