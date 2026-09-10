-- ThrowSim -- FrSky Suite simulator macro that fakes a DLG throw's altitude.
--
-- The simulator has no "set sensor value" control; telemetry only exists
-- there as injected raw S.Port frames (simulator.injectSPortFrame, Ethos
-- 26.1+). This streams one altitude frame every 0.2 s for WINDOW seconds:
-- flat at ground level, then a ramp up to PEAK, a short hold, then back
-- down -- so the model's "Altitude" sensor updates continuously (its
-- age() stays well under ThrowTrainer's 2 s stale gate) and its peak/max
-- reads PEAK at the end of the launch. Flip Launch/Zoom/landing mode by
-- hand while it runs; the ramp starts after LEAD seconds so there's time
-- to get into Launch first.
--
-- Run: FrSky Suite toolbar > Run Macro > pick this folder. The debugger
-- pauses on line 1 -- click Resume. If it asks to restart the simulator
-- to load the files, click CANCEL (see project memory: OK can wipe
-- hand-placed script folders).
--
-- SENSOR IDS -- must match the model's own Altitude sensor. Read off the
-- radio's Telemetry sensor page (2026-09-10): "1A 0100 (ISRM Rx0)" =
-- physical ID 0x1A, app ID 0x0100, internal module (ISRM), receiver 0.
-- If the sensor ever shows "---" while this runs, re-check these there.
local PHYS_ID = 0x1A
local APP_ID  = 0x0100

local PEAK   = 4500     -- centimetres (S.Port ALT is cm): 45 m
local LEAD   = 5        -- s of ground-level frames before the climb
local CLIMB  = 3        -- s ramping 0 -> PEAK
local HOLD   = 2        -- s at PEAK
local DESC   = 20       -- s ramping PEAK -> 0 (time to land + wait ALT_CALL)
local TAIL   = 10       -- s of ground-level frames afterwards
local STEP   = 0.2      -- s between frames

local function send(cm)
  simulator.injectSPortFrame({ module = 0, band = 0, rx = 0,
    physId = PHYS_ID, primId = 0x10, appId = APP_ID, value = math.floor(cm) })
end

local function stream(seconds, f)
  local n = math.floor(seconds / STEP)
  for i = 0, n - 1 do
    send(f(i / math.max(n - 1, 1)))
    simulator.sleep(STEP)
  end
end

print("ThrowSim: ground level for " .. LEAD .. "s -- switch to Launch now")
stream(LEAD,  function() return 0 end)
print("ThrowSim: climbing to " .. (PEAK / 100) .. " m")
stream(CLIMB, function(t) return PEAK * t end)
stream(HOLD,  function() return PEAK end)
print("ThrowSim: descending -- exit Zoom, land, wait for the height callout")
stream(DESC,  function(t) return PEAK * (1 - t) end)
stream(TAIL,  function() return 0 end)
print("ThrowSim: done")
