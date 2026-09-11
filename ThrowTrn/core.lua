-- ThrowTrainer core: identity, persistence, capture, grouping, statistics.
-- Loaded once by main.lua and shared by the widget and the tool, so there is
-- exactly one in-memory state and one set of files.

local core = {}

core.VERSION = "2.0.1"

-- ---------------------------------------------------------------- constants

local LOG_CAP       = 5000           -- rolling record cap
local STATUS_SEC    = 3              -- status line dwell, wall-clock seconds
-- The telemetry freshness gate is S.cfg.stale (seconds, 0 = off), see
-- defaults() -- no longer a constant here.

core.STATUS_SEC = STATUS_SEC

-- DLG template flight-mode numbering (CATEGORY_FLIGHT member 0's value),
-- confirmed in reference_category_flight.md. Setup marks are only watched
-- for and only confirmed while in one of these two.
local FM_LAUNCH = 2
local FM_ZOOM   = 3
-- Exposed so screen.lua can name a flight mode without hardcoding the DLG
-- template's numbering a second time.
core.FM_LAUNCH = FM_LAUNCH
core.FM_ZOOM   = FM_ZOOM

-- ---------------------------------------------------------------- state

local S = {
  ready      = false,
  gid        = nil,
  modelId    = "",
  name       = "",
  unit       = "",              -- whatever the sensor reports; never converted
  launches   = {},              -- active glider only, oldest first
  events     = {},              -- active glider only, oldest first
  sessionLaunches = 0,          -- appended during this power-on
  sessionEvents   = 0,
  seq        = 0,               -- append order within this power-on
  dir        = nil,             -- resolved Files/ path, nil = no persistence
  ioError    = nil,
  status     = nil,
  statusAt   = 0,
  altSrc     = nil,
  callSrc    = nil,
  launchSrc  = nil,
  -- Raw FS1-FS4 sources. What each ACTUALLY does is whatever screen.lua's
  -- V.keys currently holds at that index (all 4 slots filled as of 2.0 --
  -- CHANGE/LOG/CONFIG/SETUP) -- core.pollFS below only does edge-detection
  -- and returns an index, it doesn't hardcode an action per FS.
  fs1        = nil,
  fs2        = nil,
  fs3        = nil,
  fs4        = nil,
  -- All four only act once Throw Trainer's widget is the visible, focused
  -- thing on screen -- see main.lua's widgetWakeup and core.pollFS below.
  prevCall   = -100,
  prevChange = -100,
  prevUndo   = -100,
  prevFS1    = -100,
  prevFS2    = -100,
  prevFS3    = -100,
  prevFS4    = -100,
  lastChangeAt = 0,
  undoArmed    = false,
  cfg        = {},

  -- ---- 2.0: auto-detected setup marks (camber/reflex, elevator, rudder
  -- offset) -- see project memory project_throwtrainer_2.0_marks.md for
  -- the full spec and the probe results these read mechanisms rest on.
  camberSrc  = nil,   -- CATEGORY_TRIM member 2 ("Trim Throttle")
  elevSrc    = nil,   -- CATEGORY_TRIM member 1 ("Trim Elevator")
  rudSrc     = nil,   -- VAR "V_RudOffset", no category
  fmSrc      = nil,   -- CATEGORY_FLIGHT member 0 ("Current F.M.")
  -- Camber/elev baselines are PER FLIGHT MODE (keyed by FM_LAUNCH/FM_ZOOM)
  -- -- confirmed via TrimProbe that a trim's value() only ever reflects
  -- whichever mode is CURRENTLY active, so there is no way to read
  -- Launch's camber while sitting in Zoom. Each mode's baseline is
  -- captured lazily, the first time that mode is actually visited after a
  -- reset -- see core.pollSetupChange. rud has no such split: V_RudOffset
  -- is a Variable, not a trim, readable at any time regardless of flight
  -- mode (only its EFFECT on the rudder channel is Launch-only).
  baseCamberByFM = {},
  baseElevByFM   = {},
  baseRud    = nil,
  rudBaselineAt = 0,  -- os.time() after which baseRud may be read, see
                      -- RUD_SETTLE_SEC / core.captureSetupBaseline
  -- Marks with grp > this count toward "since baseline", and the set just
  -- before the first of them is what COMPARE's top row averages (see
  -- core.baselineGroup). Never persisted directly -- derived from the log
  -- on every load as the group of the most recent "revert" or "accept"
  -- event (see deriveBaselineGrp), which is what makes it survive a power
  -- cycle at all (an earlier version only ever set it in memory, so a
  -- completed revert's baseline silently evaporated on reboot).
  baselineGrp = 0,
  -- pendingByFM[FM_LAUNCH] / pendingByFM[FM_ZOOM] = {camber=, elev=}
  -- deltas, independently -- both can be live at once (the pilot adjusted
  -- something in each mode before ever throwing), matching the approved
  -- Setup Change Detected mockup showing both cards simultaneously.
  pendingByFM = {},
  pendingRud  = nil,  -- rud delta, watched only while fm == FM_LAUNCH
  -- Edge-triggered, not level: true for exactly one paint after
  -- hasPendingSetup() flips false->true, then consumed (see
  -- core.consumeSetupJustDetected). screen.lua uses this to auto-switch to
  -- the Setup Change Detected screen ONCE per newly-detected change, not on
  -- every paint while a change sits pending -- otherwise a pilot who
  -- deliberately backs out to LOG or CFG while a change is still
  -- unconfirmed would get yanked back to it on the very next frame.
  setupJustDetected = false,
  -- Edge, same pattern: true for one paint after core.recordLaunch logs a
  -- throw, consumed by screen.lua to drop back to Main from wherever it
  -- was (see core.consumeLaunchRecorded).
  launchJustRecorded = false,
  -- Set only while the Reverting-to-Mark screen is live: { grp, ts, axes =
  -- { {fm, axis, label, current, target}, ... }, rud = {label,current,target}
  -- or nil }. Targets are snapshotted ONCE by core.beginRevert and never
  -- recomputed from a moving "current" afterward -- see its own comment.
  -- nil the rest of the time.
  revertTarget = nil,
}

core.S = S

-- ---------------------------------------------------------------- config

-- Shipping defaults. (Dropped to 0/0 during 2026-09-09/10 simulator
-- testing so telemetry-less sim throws still registered; restored for
-- the field test. For sim work, lower "Minimum height" in CFG instead --
-- it's a per-glider setting -- rather than editing this again.)
local DEFAULTS_FT = { floor = 25 }
local DEFAULTS_M  = { floor = 8  }

local function defaults()
  local d = {
    floor        = DEFAULTS_FT.floor,
    timeout      = 15,          -- capture window cap, seconds
    stale        = 2,           -- telemetry freshness gate, seconds; 0 = off
                                 -- (2026-09-10: a CFG setting rather than a
                                 -- code constant so simulator testing, where
                                 -- injected frames don't keep the sensor's
                                 -- age fresh reliably, can switch it off
                                 -- without a must-revert-before-shipping edit)
    bars         = 0,           -- 0 = auto
    window       = 20,          -- rolling comparison window
    theme        = 2,           -- 1 Night, 2 Day -- day/outdoor use is the
                                 -- common case, so that's the default now
    changeSwitch = nil,
    undoSwitch   = nil,
  }
  return d
end

core.defaults = defaults

-- Swap the floor default for metres rather than converting 25 ft into an
-- awkward 7.6 m. Only applied while the value is still the default.
local function applyUnitDefaults()
  if S.unit ~= "m" then return end
  if S.cfg.floor == DEFAULTS_FT.floor then S.cfg.floor = DEFAULTS_M.floor end
end

function core.activeGid()
  return S.gid
end

function core.configGid()
  return S.gid
end

-- ---------------------------------------------------------------- files

local function tryDir(dir)
  local path = dir .. "probe.tmp"
  local f = io.open(path, "w")
  if not f then return false end
  f:write("x")
  f:close()
  if os.remove then pcall(os.remove, path) end
  return true
end

-- Ethos resolves relative paths against the script folder, but that is not
-- guaranteed for every build, so probe the candidates once and remember which
-- one actually accepted a write.
local function resolveDir()
  local candidates = {
    "Files/",
    "/scripts/ThrowTrn/Files/",
    "SCRIPTS:/ThrowTrn/Files/",
  }
  for i = 1, #candidates do
    local ok, works = pcall(tryDir, candidates[i])
    if ok and works then return candidates[i] end
  end
  return nil
end

local function fileName(base)
  return base .. ".csv"
end

local function path(base)
  if not S.dir then return nil end
  return S.dir .. fileName(base)
end

local function splitLine(line)
  local out = {}
  for field in string.gmatch(line .. ",", "([^,]*),") do
    out[#out + 1] = field
  end
  return out
end

-- Reads the whole file in fixed-size chunks using the numeric byte-count
-- form of read(), rather than any string format specifier, and rather than
-- the standard-Lua idiom `for line in f:lines() do`. Confirmed on hardware,
-- the hard way, across three attempts: Ethos's file handles reject
-- :lines() outright ("method 'lines' is not callable"), and reject *both*
-- the legacy Lua 5.1 format string ("*a") and the modern Lua 5.2+ one ("a")
-- as an argument to read() ("bad argument #1 to 'read'" either way -- Lua's
-- method-call error numbering blames the visible argument, not self, so
-- that #1 is genuinely the format string, not the file handle). The
-- numeric form is the one read mode with no string specifier to reject, so
-- it's the last fallback that doesn't depend on a guess about which
-- spelling this particular Lua build accepts.
--
-- Wrapped in pcall and made to fail soft (empty rows + a status message)
-- rather than propagating: this function runs inside core.init(), and an
-- uncaught error there is exactly what's caused every "data looks like it
-- vanished" symptom so far, repeatedly, across a completely different
-- reboot each time. A failure to read one file should degrade gracefully,
-- not take the whole app down again.
local function readAll(f)
  local chunks = {}
  while true do
    local chunk = f:read(2048)
    if not chunk or chunk == "" then break end
    chunks[#chunks + 1] = chunk
    if #chunk < 2048 then break end   -- short read = end of file
  end
  return table.concat(chunks)
end

local function readRows(base)
  local p = path(base)
  if not p then return {} end
  local f = io.open(p, "r")
  if not f then return {} end

  local ok, content = pcall(readAll, f)
  pcall(function() f:close() end)
  if not ok then
    core.setStatus("read error (" .. base .. "): " .. tostring(content))
    return {}
  end

  local rows = {}
  for line in (content or ""):gmatch("[^\r\n]+") do
    if line ~= "" and string.sub(line, 1, 1) ~= "#" then
      rows[#rows + 1] = splitLine(line)
    end
  end
  return rows
end

local function appendRow(base, fields)
  local p = path(base)
  if not p then return false end
  local f = io.open(p, "a")
  if not f then
    S.ioError = "append " .. base
    return false
  end
  f:write(table.concat(fields, ",") .. "\n")
  f:close()
  return true
end

-- Whole-file rewrite. Used by undo and erase, both of which must drop rows
-- belonging to the active glider while preserving every other glider's.
local function rewrite(base, keptRows)
  local p = path(base)
  if not p then return false end
  local f = io.open(p, "w")
  if not f then
    S.ioError = "rewrite " .. base
    return false
  end
  for i = 1, #keptRows do
    f:write(table.concat(keptRows[i], ",") .. "\n")
  end
  f:close()
  return true
end

core.readRows = readRows
core.rewrite  = rewrite

-- ---------------------------------------------------------------- identity

local function modelIdString()
  local ok, ids = pcall(model.id)
  if not ok or type(ids) ~= "table" then return "?" end
  local parts = {}
  for i = 1, #ids do parts[#parts + 1] = tostring(ids[i]) end
  if #parts == 0 then
    -- Some builds return a keyed table rather than an array.
    for k, v in pairs(ids) do parts[#parts + 1] = tostring(k) .. "=" .. tostring(v) end
    table.sort(parts)
  end
  return table.concat(parts, "|")
end

local function modelName()
  local ok, n = pcall(model.name)
  if ok and type(n) == "string" and n ~= "" then return n end
  return "model"
end

-- Identity is derived from gliders.csv keyed on model.id(), not from widget
-- storage. Storage travels with a cloned model and so cannot distinguish a
-- clone from its original; a clone receives a fresh receiver number, so it
-- simply will not be found here and is minted a new id automatically.
-- Returns true when this glider has never been seen before (a fresh mint,
-- not a rename of an existing one) -- the caller uses that to decide
-- whether to seed demo data, see loadIdentityData below.
local function bindIdentity()
  S.modelId = modelIdString()
  S.name    = modelName()

  local rows = readRows("gliders")
  local byBoth, byId, changed = nil, nil, false

  for i = 1, #rows do
    local r = rows[i]
    if r[2] == S.modelId then
      byId = byId or r
      if r[3] == S.name then byBoth = r end
    end
  end

  local hit = byBoth or byId
  local fresh = not hit
  if hit then
    S.gid = hit[1]
    if hit[3] ~= S.name then       -- renamed: refresh the readable name only
      hit[3] = S.name
      changed = true
    end
  else
    S.gid = "G" .. tostring(os.time()) .. "-" .. string.gsub(S.modelId, "|", "_")
    rows[#rows + 1] = { S.gid, S.modelId, S.name }
    changed = true
  end

  if changed then rewrite("gliders", rows) end
  return fresh
end

-- ---------------------------------------------------------------- sources

local function getSensor(name)
  local ok, src = pcall(system.getSource,
    { category = CATEGORY_TELEMETRY_SENSOR, name = name })
  if ok then return src end
  return nil
end

local function getLogic(name)
  local ok, src = pcall(system.getSource,
    { category = CATEGORY_LOGIC_SWITCH, name = name })
  if ok then return src end
  return nil
end

-- Direct flight-mode read, confirmed working -- see project memory
-- reference_category_flight.md. system.getFlightMode() does not exist on
-- this firmware; CATEGORY_FLIGHT member 0 ("Current F.M.") is the real
-- source, its :value() a live numeric index matching the DLG template's
-- own numbering: 0=Cruise, 1=CAL, 2=Launch, 3=Zoom, 4=Landing, 5=Speed,
-- 6=Therm2, 7=Therm1.
local function getFlightModeSrc()
  local ok, src = pcall(system.getSource, { category = CATEGORY_FLIGHT, member = 0 })
  if ok then return src end
  return nil
end

-- Function Switches (FS1-FS4) are not logic switches and have no
-- documented CATEGORY_* constant -- confirmed via the DLGPoker project's
-- own hardware sweep (its spec S11): asking a manually-picked FS1 source
-- what it is returned raw category number 12, member 0, with FS2-FS4 as
-- members 1-3 of that same numeric category. Ethos 26.x names it
-- CATEGORY_FUNCTION_SWITCH (confirmed equal to 12 by the Dial In probe);
-- the literal stays as the fallback for firmware without the constant.
local FS_CATEGORY_NUMERIC = rawget(_G, "CATEGORY_FUNCTION_SWITCH") or 12

local function getFS(member)
  local ok, src = pcall(system.getSource,
    { category = FS_CATEGORY_NUMERIC, member = member })
  if ok then return src end
  return nil
end

-- Camber/reflex and Elevator are genuine Ethos trims (independent per
-- flight mode natively -- confirmed live-tracking AND per-FM scoping via
-- a throwaway TrimProbe tool, 2026-09-08). CATEGORY_TRIM member indices
-- are NOT the standard AETR order on this template -- confirmed by name
-- in the probe sweep: 0=Rudder, 1=Elevator, 2=Throttle, 3=Aileron. Throttle
-- is repurposed for camber/reflex (the DLG template's own convention --
-- see dlg_ethos_220_SettingsRef.xlsx's "Controls and FMs" sheet: "Throttle
-- trim -- Camber/reflex adjustment, per flight mode"). These are
-- READ-ONLY from Lua -- confirmed both empirically (a value() write is a
-- silent no-op) and against FrSky's own Ethos Lua reference docs (Source
-- class's value() write capability is documented as scoped to "Lua
-- sources / Vars / Telemetry sensors" -- trims aren't in that list, and
-- no model.setTrim or equivalent exists). Do not add write code for these.
local function getTrimMember(member)
  local ok, src = pcall(system.getSource, { category = CATEGORY_TRIM, member = member })
  if ok then return src end
  return nil
end

-- V_RudOffset is an Ethos model Variable (Ethos 1.5+'s own named-variable
-- feature), not a trim -- resolves via a bare name lookup, no category,
-- and unlike the trims above IS writable via src:value(x) (confirmed by
-- CurveVarProbe). Only takes effect in Launch mode per the DLG template's
-- own Mixers sheet (the "RudderOffset" mixer line is Launch-only).
local function getVar(name)
  local ok, src = pcall(system.getSource, { name = name })
  if ok then return src end
  return nil
end

local function resolveSources()
  S.altSrc    = getSensor("Altitude")
  S.callSrc   = getLogic("ALT_CALL")
  S.launchSrc = getLogic("MOM_LAUNCH")
  S.fs1 = getFS(0)
  S.fs2 = getFS(1)
  S.fs3 = getFS(2)
  S.fs4 = getFS(3)
  S.camberSrc = getTrimMember(2)
  S.elevSrc   = getTrimMember(1)
  S.rudSrc    = getVar("V_RudOffset")
  S.fmSrc     = getFlightModeSrc()
  if S.altSrc then
    local ok, u = pcall(function() return S.altSrc:stringUnit() end)
    if ok and type(u) == "string" and u ~= "" then S.unit = u end
  end
  if S.unit == "" then S.unit = "ft" end
end

core.resolveSources = resolveSources

-- ---------------------------------------------------------------- config io

local function loadConfig()
  S.cfg = defaults()
  local gid = core.configGid()
  local rows = readRows("config")
  for i = 1, #rows do
    local r = rows[i]
    if r[1] == gid then
      local key, raw = r[2], r[3]
      local num = tonumber(raw)
      if num then S.cfg[key] = num
      elseif raw == "" then S.cfg[key] = nil
      else S.cfg[key] = raw end
    end
  end
  applyUnitDefaults()
end

function core.saveConfig()
  local gid = core.configGid()
  local rows = readRows("config")
  local kept = {}
  for i = 1, #rows do
    if rows[i][1] ~= gid then kept[#kept + 1] = rows[i] end
  end
  local d = defaults()
  for k, v in pairs(S.cfg) do
    -- Only persist genuine departures from the defaults, so a later default
    -- change is picked up rather than frozen by an old write.
    if v ~= nil and v ~= d[k] and type(v) ~= "table" then
      kept[#kept + 1] = { gid, k, tostring(v) }
    end
  end
  rewrite("config", kept)
end

core.loadConfig = loadConfig

-- ---------------------------------------------------------------- log io

-- S.baselineGrp is a pure function of the log: the group of the latest
-- "revert" or "accept" event, 0 if there's never been one. Re-derived
-- after anything that changes S.events (load, undo, erase, seed purge)
-- rather than persisted as its own value -- one source of truth, and it
-- can't drift from the log it describes.
local function deriveBaselineGrp()
  local g = 0
  for i = 1, #S.events do
    local e = S.events[i]
    if (e.type == "revert" or e.type == "accept") and e.grp > g then g = e.grp end
  end
  S.baselineGrp = g
end

local function loadLog()
  S.launches, S.events = {}, {}
  local gid = core.activeGid()

  local rows = readRows("launches")
  for i = 1, #rows do
    local r = rows[i]
    if r[2] == gid then
      S.launches[#S.launches + 1] = {
        ts  = tonumber(r[1]) or 0,
        h   = tonumber(r[3]) or 0,
        u   = r[4] or S.unit,
        grp = tonumber(r[5]) or 1,
        st  = r[6] or "ok",
        seed = (r[7] == "1"),   -- sample data, see core.seedDemo; absent on
                                 -- older rows, tonumber-free so a blank or
                                 -- missing field just reads as false
      }
    end
  end

  rows = readRows("events")
  for i = 1, #rows do
    local r = rows[i]
    if r[2] == gid then
      S.events[#S.events + 1] = {
        ts   = tonumber(r[1]) or 0,
        type = r[3] or "change",
        grp  = tonumber(r[4]) or 1,
        -- Trailing columns, "setup"-type events only (2.0). Absent/blank
        -- on every pre-2.0 row and on manual "change"/"power" rows alike --
        -- tonumber(nil-or-"") is nil either way, so this reads back exactly
        -- as "no delta on this axis" with no special-casing needed. Five
        -- columns, not three -- Launch and Zoom camber/elev are tracked
        -- independently (see core.confirmPendingSetup), so one mark event
        -- can carry deltas for both modes plus rud all at once. Column 10,
        -- "revertToGrp", is "type"=="revert" rows only -- which mark's own
        -- group this row reverted back to (see core.finishRevert).
        launchCamber = tonumber(r[5]),
        launchElev   = tonumber(r[6]),
        rud          = tonumber(r[7]),
        zoomCamber   = tonumber(r[8]),
        zoomElev     = tonumber(r[9]),
        revertToGrp  = tonumber(r[10]),
      }
    end
  end

  S.sessionLaunches = 0
  S.sessionEvents   = 0
  deriveBaselineGrp()
end

-- ---------------------------------------------------------------- grouping

function core.currentGroup()
  local g = 1
  for i = 1, #S.launches do
    if S.launches[i].grp > g then g = S.launches[i].grp end
  end
  for i = 1, #S.events do
    if S.events[i].grp > g then g = S.events[i].grp end
  end
  return g
end

local function countIn(grp)
  local n = 0
  for i = 1, #S.launches do
    if S.launches[i].grp == grp then n = n + 1 end
  end
  return n
end

function core.lastEvent()
  if #S.events == 0 then return nil end
  return S.events[#S.events]
end

-- Armed is derived, never stored: the current group is empty and the boundary
-- that opened it was a change rather than a power cycle.
function core.isArmed()
  local cur = core.currentGroup()
  if countIn(cur) > 0 then return false end
  local e = core.lastEvent()
  return e ~= nil and e.type == "change" and e.grp == cur
end

-- Every event kind that opens a real current/previous-set boundary --
-- everything except "power". "setup" (auto-detected), "revert" and
-- "accept" count exactly like a manual "change" here, so the delta
-- badge's fallback-to-recent-window logic (core.stats) must not fire just
-- because the only boundary so far wasn't key-pressed.
local function isMark(e)
  local t = e.type
  return t == "change" or t == "setup" or t == "revert" or t == "accept"
end

function core.hasChange()
  for i = 1, #S.events do
    if isMark(S.events[i]) then return true end
  end
  return false
end

-- ---------------------------------------------------------------- statistics

local function mean(list)
  if #list == 0 then return nil end
  local sum = 0
  for i = 1, #list do sum = sum + list[i] end
  return sum / #list
end

-- Flagged records are excluded from every average, per S7.
local function valid(rec) return rec.st == "ok" end

local function heightsIn(grp)
  local out = {}
  for i = 1, #S.launches do
    local r = S.launches[i]
    if r.grp == grp and valid(r) then out[#out + 1] = r.h end
  end
  return out
end

-- Average height of one specific group, flagged records excluded --
-- exposed for Review Log's per-mark delta (this group's average vs the one
-- right before it), which needs an arbitrary group's figure, not just the
-- current/before pair core.stats already computes.
function core.groupAvg(grp)
  return mean(heightsIn(grp))
end

-- The most recent closed group that actually holds data. A group emptied by
-- undo is skipped rather than reported as an empty Before.
function core.beforeGroup()
  local cur = core.currentGroup()
  for g = cur - 1, 1, -1 do
    if #heightsIn(g) > 0 then return g end
  end
  return nil
end

-- The set COMPARE's top row averages: the last set with throws BEFORE the
-- first mark since baseline -- i.e. how the glider flew before any of the
-- changes still being compared against were made. With exactly one mark
-- since baseline this is the same set core.beforeGroup returns (hence the
-- "Previous set" label in that case); with two or more it reaches back
-- past all of them, which is the whole point of the "Original baseline"
-- label. An earlier version only ever changed the LABEL and kept showing
-- the previous set's figure underneath it regardless -- fixed 2026-09-10
-- while building accept-as-baseline, which would otherwise have been a
-- numeric no-op. nil when there's no mark since baseline at all (callers
-- fall back to the previous-set / recent-window comparison as before).
function core.baselineGroup()
  local firstMark
  for i = 1, #S.events do
    local e = S.events[i]
    if isMark(e) and e.grp > (S.baselineGrp or 0) then
      if not firstMark or e.grp < firstMark then firstMark = e.grp end
    end
  end
  if not firstMark then return nil end
  for g = firstMark - 1, 1, -1 do
    if #heightsIn(g) > 0 then return g end
  end
  return nil
end

local function tail(list, n)
  local out = {}
  local from = #list - n + 1
  if from < 1 then from = 1 end
  for i = from, #list do out[#out + 1] = list[i] end
  return out
end

local function validHeights()
  local out = {}
  for i = 1, #S.launches do
    if valid(S.launches[i]) then out[#out + 1] = S.launches[i].h end
  end
  return out
end

-- Everything the views need, computed in one place so the widget and the tool
-- can never disagree about a figure.
function core.stats(barCount)
  local cur = core.currentGroup()
  local bg  = core.beforeGroup()
  local after  = heightsIn(cur)
  local before = bg and heightsIn(bg) or {}
  local all    = validHeights()

  local marksSinceBaseline = 0
  for i = 1, #S.events do
    local e = S.events[i]
    if isMark(e) and e.grp > (S.baselineGrp or 0) then
      marksSinceBaseline = marksSinceBaseline + 1
    end
  end
  local blg = core.baselineGroup()
  local baseline = blg and heightsIn(blg) or nil

  local st = {
    unit      = S.unit,
    armed     = core.isArmed(),
    hasChange = core.hasChange(),
    group     = cur,
    -- COMPARE panel label rule (2.0): exactly one mark since baseline ->
    -- "Previous set" is accurate (it IS the one set right before this
    -- one); two or more -> "Original baseline", since the comparison is
    -- however many marks back to the actual baseline, not to "the set
    -- right before this one." screen.lua reads this to pick the label.
    marksSinceBaseline = marksSinceBaseline,
    -- Always the TRUE current/previous set, never overwritten below. The
    -- "SET n . n=" panel reads these, so they must reflect every throw
    -- actually in the set regardless of what the delta comparison ends up
    -- using.
    afterN    = #after,
    beforeN   = #before,
    afterAvg  = mean(after),
    beforeAvg = mean(before),
    allN      = #all,
    allAvg    = mean(all),
    last      = S.launches[#S.launches],
    fallback  = false,
  }

  st.best = nil
  for i = 1, #all do
    if not st.best or all[i] > st.best then st.best = all[i] end
  end

  -- Best within the current (open) set, for the "avg .. best .." context
  -- line under the hero number -- distinct from the lifetime best above.
  st.afterBest = nil
  for i = 1, #after do
    if not st.afterBest or after[i] > st.afterBest then st.afterBest = after[i] end
  end

  local wn = S.cfg.window or 20
  st.windowAvg    = mean(tail(all, wn))
  st.windowN      = math.min(wn, #all)
  st.windowTarget = wn        -- the configured size, for the "Last 20" label

  -- The comparison figures (delta badge + COMPARE panel's "prev" row) are
  -- kept separate from afterN/beforeN above on purpose. With no change ever
  -- recorded there's no real previous set to compare against, so this
  -- substitutes a recent-vs-previous window split -- but overwriting
  -- afterN/beforeN directly (as this used to) made the "SET n . n=" panel
  -- show only the window size instead of the true throw count: 5 real
  -- throws in Set 1 would show as "n=2" because the fallback window only
  -- fit 2 a side, and the badge could never clear n>=3 no matter how many
  -- throws actually landed. cmp* keeps the substitution scoped to just the
  -- comparison.
  st.cmpAfterN, st.cmpAfterAvg   = st.afterN, st.afterAvg
  st.cmpBeforeN, st.cmpBeforeAvg = st.beforeN, st.beforeAvg

  -- With no change ever recorded there is nothing to compare, so fall back to
  -- recent-vs-previous over the same span the bar strip is showing. The span
  -- also has to shrink to half the available throws, or a fresh log would show
  -- nothing at all until it held twice the bar count.
  if not st.hasChange then
    local n = barCount or 12
    local half = math.floor(#all / 2)
    if half < n then n = half end
    if #all >= 2 and n >= 1 then
      local recent = tail(all, n)
      local prevEnd = #all - #recent
      local prev = {}
      local from = prevEnd - n + 1
      if from < 1 then from = 1 end
      for i = from, prevEnd do prev[#prev + 1] = all[i] end
      st.cmpAfterAvg, st.cmpAfterN   = mean(recent), #recent
      st.cmpBeforeAvg, st.cmpBeforeN = mean(prev), #prev
      st.fallback = true
    end
  end

  if st.cmpAfterAvg and st.cmpBeforeAvg then
    st.delta = st.cmpAfterAvg - st.cmpBeforeAvg
    st.confident = (st.cmpAfterN >= 3 and st.cmpBeforeN >= 3)
  end

  -- COMPARE's top row: the genuine baseline set when there is one (see
  -- core.baselineGroup), otherwise whatever the comparison above settled
  -- on -- identical to cmpBeforeAvg with exactly one mark since baseline,
  -- and with none at all. The delta badge deliberately keeps using
  -- cmpBeforeAvg ("vs previous set") either way, matching the mockup.
  if baseline and #baseline > 0 then
    st.baselineAvg, st.baselineN = mean(baseline), #baseline
  else
    st.baselineAvg, st.baselineN = st.cmpBeforeAvg, st.cmpBeforeN
  end

  return st
end

-- Bars for the strip, newest last, tagged with how they should be coloured.
function core.strip(n)
  local cur = core.currentGroup()
  local bg  = core.beforeGroup()
  local out = {}
  local from = #S.launches - n + 1
  if from < 1 then from = 1 end
  for i = from, #S.launches do
    local r = S.launches[i]
    local band = "old"
    if r.grp == cur then band = "after"
    elseif bg and r.grp == bg then band = "before" end
    out[#out + 1] = { h = r.h, st = r.st, band = band, grp = r.grp }
  end
  return out
end

-- Boundaries falling inside the visible strip, as bar-gap indices.
function core.stripBoundaries(bars)
  local marks = {}
  for i = 2, #bars do
    if bars[i].grp ~= bars[i - 1].grp then
      local kind = "change"
      for j = 1, #S.events do
        if S.events[j].grp == bars[i].grp then kind = S.events[j].type end
      end
      marks[#marks + 1] = { at = i, kind = kind }
    end
  end
  return marks
end

-- ---------------------------------------------------------------- status

-- Dwell is measured against os.time, not os.clock: os.clock reports CPU time
-- consumed by the script, which advances far slower than real time, so a
-- message timed with it would linger long past its usefulness.
function core.setStatus(text)
  S.status = text
  S.statusAt = os.time()
end

function core.status()
  if not S.status then return nil end
  if os.time() - (S.statusAt or 0) > STATUS_SEC then
    S.status = nil
    return nil
  end
  return S.status
end

-- ---------------------------------------------------------------- haptic

-- Degrade to silence where there is no vibration motor rather than erroring.
local function haptic(pattern)
  if system.playHaptic then pcall(system.playHaptic, pattern) end
end

core.haptic = haptic

-- ---------------------------------------------------------------- writes

local function trim()
  if #S.launches <= LOG_CAP then return end
  local drop = #S.launches - LOG_CAP
  local rows = readRows("launches")
  local gid = core.activeGid()
  local kept, seen = {}, 0
  for i = 1, #rows do
    if rows[i][2] == gid then
      seen = seen + 1
      if seen > drop then kept[#kept + 1] = rows[i] end
    else
      kept[#kept + 1] = rows[i]
    end
  end
  rewrite("launches", kept)
  for _ = 1, drop do table.remove(S.launches, 1) end
end

-- If the only data on file is the seed sample (see core.seedDemo), the
-- first genuine capture wipes it before doing anything else, so a 50ft
-- demo throw can never end up averaged in with a real flight.
local function purgeSeedIfPresent()
  local hasSeed = false
  for i = 1, #S.launches do
    if S.launches[i].seed then hasSeed = true break end
  end
  if not hasSeed then return end

  local gid = S.gid
  for _, base in ipairs({ "launches", "events" }) do
    local rows = readRows(base)
    local kept = {}
    for i = 1, #rows do
      if rows[i][2] ~= gid then kept[#kept + 1] = rows[i] end
    end
    rewrite(base, kept)
  end
  S.launches, S.events = {}, {}
  S.sessionLaunches, S.sessionEvents = 0, 0
  deriveBaselineGrp()
  core.setStatus("sample data cleared - tracking real throws")
end

-- THE INJECTION SEAM. The real capture path calls this and only this.
function core.recordLaunch(height, unit, ts)
  if not height then return nil end
  purgeSeedIfPresent()
  height = math.floor(height + 0.5)
  ts = ts or os.time()
  unit = unit or S.unit

  if height < (S.cfg.floor or 25) then
    -- Discarded, armed state intact -- but not silently any more (2026-09-09):
    -- a throw genuinely clearing the floor was hard to tell apart from
    -- one that didn't while debugging a separate capture issue, since
    -- neither one said anything on screen. A quick status line costs
    -- nothing and makes "did that count?" answerable at a glance.
    core.setStatus(string.format("%d %s - below floor, not recorded", height, unit))
    return "low"
  end

  -- No ceiling/ "high" flag on new throws any more -- removed at the pilot's
  -- request (S.cfg.ceiling no longer exists). A "high" status can still show
  -- up on log/strip rows written by an older version of the app before this
  -- removal; draw.lua and screen.lua still render that legacy status
  -- correctly rather than silently reinterpreting old data.
  local st = "ok"

  -- A throw that clears the floor is, per the pilot's spec, exactly the
  -- moment a pending auto-detected setup change gets confirmed into a
  -- real mark -- BEFORE grp is read below, so this throw becomes the new
  -- group's first throw (no separate "armed and waiting" gap the way a
  -- manual MARK leaves one). A discarded "low" throw above never reaches
  -- here, so it can't spuriously confirm a change that hasn't really been
  -- test-flown yet.
  core.confirmPendingSetup()

  local grp = core.currentGroup()
  S.seq = S.seq + 1
  local rec = { ts = ts, h = height, u = unit, grp = grp, st = st, seq = S.seq,
                seed = false }
  S.launches[#S.launches + 1] = rec
  S.sessionLaunches = S.sessionLaunches + 1
  S.launchJustRecorded = true

  appendRow("launches", { tostring(ts), core.activeGid(), tostring(height),
                          unit, tostring(grp), st, "" })
  trim()
  return st
end

-- Pre-loads a set of sample throws so the UI has something to show before
-- the first real flight -- split across two sets with a marker between
-- them (2026-09, pilot's request), so the demo actually exercises the
-- current/previous-set comparison and the strip captions, instead of one
-- flat, uncomparable blob of bars. Not counted toward this session (so
-- UNDO can't pick a seed row apart one at a time -- Erase or a real throw
-- are the only ways out), and refuses to run over an existing real log
-- rather than silently discarding it. The marker event needs no seed flag
-- of its own -- purgeSeedIfPresent already wipes every event for this
-- glider the moment any seeded launch is found, which is safe here since
-- a fresh/all-seed log can't have a real event to lose yet.
function core.seedDemo(n, minHeight, maxHeight)
  if #S.launches > 0 then
    core.setStatus("erase real data first")
    return false
  end
  n = n or 10
  minHeight = minHeight or 60
  maxHeight = maxHeight or 95
  local gid = S.gid
  local base = os.time()
  local firstN = math.max(1, math.floor(n / 2))

  for i = 1, n do
    if i == firstN + 1 then
      S.seq = S.seq + 1
      local markTs = base - (n - i)
      S.events[#S.events + 1] = { ts = markTs, type = "change", grp = 2, seq = S.seq }
      appendRow("events", { tostring(markTs), gid, "change", "2" })
    end

    local grp = (i <= firstN) and 1 or 2
    S.seq = S.seq + 1
    local ts = base - (n - i)
    local height = math.random(minHeight, maxHeight)
    S.launches[#S.launches + 1] = {
      ts = ts, h = height, u = S.unit, grp = grp, st = "ok",
      seed = true, seq = S.seq,
    }
    appendRow("launches", { tostring(ts), gid, tostring(height), S.unit,
                            tostring(grp), "ok", "1" })
  end
  core.setStatus(string.format("seeded %d sample throws from %d-%d %s",
    n, minHeight, maxHeight, S.unit))
  return true
end

-- extra (optional) carries either a "setup" mark's trim/VAR deltas --
-- {launchCamber=, launchElev=, rud=, zoomCamber=, zoomElev=}, any of which
-- may be nil (that axis untouched); five separate fields, not three, since
-- Launch and Zoom camber/elev are tracked independently (see
-- core.confirmPendingSetup) -- or a "revert" row's {revertToGrp=}, which
-- mark's own group this reverted back to (see core.finishRevert). Every
-- other kind ("change", "power") passes no extra, so those rows' trailing
-- columns just come out blank, same as every pre-2.0 row already on disk.
local function addEvent(kind, extra)
  local grp = core.currentGroup() + 1
  local ts = os.time()
  S.seq = S.seq + 1
  local e = { ts = ts, type = kind, grp = grp, seq = S.seq }
  if extra then
    e.launchCamber = extra.launchCamber
    e.launchElev   = extra.launchElev
    e.rud          = extra.rud
    e.zoomCamber   = extra.zoomCamber
    e.zoomElev     = extra.zoomElev
    e.revertToGrp  = extra.revertToGrp
  end
  S.events[#S.events + 1] = e
  S.sessionEvents = S.sessionEvents + 1
  appendRow("events", { tostring(ts), core.activeGid(), kind, tostring(grp),
    (extra and extra.launchCamber) and tostring(extra.launchCamber) or "",
    (extra and extra.launchElev)   and tostring(extra.launchElev)   or "",
    (extra and extra.rud)          and tostring(extra.rud)          or "",
    (extra and extra.zoomCamber)   and tostring(extra.zoomCamber)   or "",
    (extra and extra.zoomElev)     and tostring(extra.zoomElev)     or "",
    (extra and extra.revertToGrp)  and tostring(extra.revertToGrp)  or "" })
  return e
end

-- ---------------------------------------------------------------- change

-- One entry point for the key and the switch, so behaviour cannot depend on
-- how CHANGE was triggered.
function core.change()
  if core.isArmed() then
    -- Second press while armed cancels: a change with no throws under it
    -- carries no information, so nothing is lost.
    local e = S.events[#S.events]
    table.remove(S.events)
    if S.sessionEvents > 0 then S.sessionEvents = S.sessionEvents - 1 end
    local rows = readRows("events")
    for i = #rows, 1, -1 do
      if rows[i][2] == core.activeGid() and tonumber(rows[i][4]) == e.grp then
        table.remove(rows, i)
        break
      end
    end
    rewrite("events", rows)
    haptic(". .")
    core.setStatus("change cancelled")
    return "cancelled"
  end

  addEvent("change")
  haptic(60)
  core.setStatus("change recorded")
  return "armed"
end

-- ---------------------------------------------------------------- undo

-- Most recent event of any kind, limited to this power-on session. Covers
-- "setup" (auto-detected) marks as well as manual "change" ones as of 2.0 --
-- Review Log surfaces both kinds the same way, so a pilot who fat-fingers a
-- setup change into an accidental early confirmation needs to be able to
-- remove it too, not just a manual MARK.
function core.undoTarget()
  local lastL = S.launches[#S.launches]
  local lastE = S.events[#S.events]
  local haveL = S.sessionLaunches > 0 and lastL
  local haveE = S.sessionEvents > 0 and lastE
    and (lastE.type == "change" or lastE.type == "setup" or lastE.type == "accept")

  if haveL and haveE then
    -- Ordered by append sequence, not timestamp: os.time() has one-second
    -- resolution, so a throw and a CHANGE in the same second would tie and
    -- undo would remove the wrong one.
    if (lastL.seq or 0) >= (lastE.seq or 0) then
      return { kind = "launch", rec = lastL }
    end
    return { kind = "change", rec = lastE }
  elseif haveL then
    return { kind = "launch", rec = lastL }
  elseif haveE then
    return { kind = "change", rec = lastE }
  end
  return nil
end

function core.undo()
  local t = core.undoTarget()
  if not t then return false end
  local gid = core.activeGid()

  if t.kind == "launch" then
    table.remove(S.launches)
    S.sessionLaunches = S.sessionLaunches - 1
    local rows = readRows("launches")
    for i = #rows, 1, -1 do
      if rows[i][2] == gid then table.remove(rows, i) break end
    end
    rewrite("launches", rows)
    core.setStatus("throw removed")
  else
    local g = t.rec.grp
    table.remove(S.events)
    S.sessionEvents = S.sessionEvents - 1
    -- Merging adjacent groups requires renumbering everything above.
    for i = 1, #S.launches do
      if S.launches[i].grp >= g then S.launches[i].grp = S.launches[i].grp - 1 end
    end
    for i = 1, #S.events do
      if S.events[i].grp > g then S.events[i].grp = S.events[i].grp - 1 end
    end

    local rows = readRows("events")
    for i = #rows, 1, -1 do
      if rows[i][2] == gid and tonumber(rows[i][4]) == g then
        table.remove(rows, i)
        break
      end
    end
    for i = 1, #rows do
      if rows[i][2] == gid then
        local rg = tonumber(rows[i][4]) or 1
        if rg > g then rows[i][4] = tostring(rg - 1) end
      end
    end
    rewrite("events", rows)

    rows = readRows("launches")
    for i = 1, #rows do
      if rows[i][2] == gid then
        local rg = tonumber(rows[i][5]) or 1
        if rg >= g then rows[i][5] = tostring(rg - 1) end
      end
    end
    rewrite("launches", rows)
    deriveBaselineGrp()
    core.setStatus("change removed")
  end
  return true
end

-- ---------------------------------------------------------------- erase

function core.counts()
  local changes = 0
  for i = 1, #S.events do
    if S.events[i].type == "change" then changes = changes + 1 end
  end
  return #S.launches, changes
end

-- Filtered delete, not a file deletion: every other glider's history survives,
-- and the gliders.csv row stays so name, id and settings persist.
function core.erase()
  local gid = core.activeGid()
  for _, base in ipairs({ "launches", "events" }) do
    local rows = readRows(base)
    local kept = {}
    for i = 1, #rows do
      if rows[i][2] ~= gid then kept[#kept + 1] = rows[i] end
    end
    rewrite(base, kept)
  end
  S.launches, S.events = {}, {}
  S.sessionLaunches, S.sessionEvents = 0, 0
  deriveBaselineGrp()
  if system.playHaptic then pcall(system.playHaptic, 200) end
  core.setStatus("data erased")
end

-- ---------------------------------------------------------------- capture

local function srcValue(src, opts)
  if not src then return nil end
  local ok, v
  if opts then
    ok, v = pcall(function() return src:value(opts) end)
  else
    ok, v = pcall(function() return src:value() end)
  end
  if ok then return v end
  return nil
end

local function srcAge(src)
  if not src then return -1 end
  local ok, v = pcall(function() return src:age() end)
  if ok and type(v) == "number" then return v end
  return -1
end

function core.telemetryLive()
  local limit = S.cfg.stale
  if limit == nil then limit = 2 end
  if limit <= 0 then return true end      -- gate switched off (CFG), see defaults()
  local age = srcAge(S.altSrc)
  return age >= 0 and age < limit * 1000
end

-- The on-screen "no telemetry" warning, debounced: true only once the
-- feed has been stale for TELEM_WARN_SEC continuously. realCapture keeps
-- using the strict per-read telemetryLive() above for the record gate --
-- that's where strictness matters. This one only decides what the
-- bottom line of Main shows, and a feed hovering right at the 2 s edge
-- (pilot, 2026-09-10, simulator) made that line flicker between the set
-- captions and the warning every frame. Same os.time-based dwell idea as
-- core.status.
local TELEM_WARN_SEC = 3
function core.telemetryWarning()
  if core.telemetryLive() then
    S.staleSince = nil
    return false
  end
  S.staleSince = S.staleSince or os.time()
  return os.time() - S.staleSince >= TELEM_WARN_SEC
end

-- ---------------------------------------------------------------- setup marks (2.0)

-- Two DIFFERENT things share the word "baseline" here, and confusing them
-- was a real bug (found by the pilot, 2026-09-09): the TRIM/VAR values
-- below (baseCamber/baseElev/baseRud) are what a new setup change gets
-- DETECTED against, and the pilot's own spec is explicit that these
-- reset fresh every power-on ("the settings as they stood when the
-- transmitter powered on"). S.baselineGrp is a completely different
-- thing -- how far back the COMPARE panel's label counts marks (see
-- core.stats' marksSinceBaseline) -- and must NOT reset on every boot:
-- a mark made two power-cycles ago is still exactly one mark ago for
-- that purpose. So this function only ever touches the trim/VAR values;
-- S.baselineGrp is derived from the log (see deriveBaselineGrp) and only
-- moves forward when an "accept" (core.acceptBaseline) or a completed
-- revert (core.finishRevert) logs its event. Getting this right matters:
-- the first version of
-- this function bumped baselineGrp here too, which meant a single reboot
-- made a real, still-relevant mark stop counting -- exactly the "shows
-- Original baseline for what's really just one mark" bug.
-- Seconds after a (re)baseline before the rudder-offset baseline is
-- actually read. Same settling window identityStillCurrent documents for
-- model.id(): right after power-on, sources can briefly read unsettled
-- values. Pilot-reported 2026-09-10: after a restart with V_RudOffset
-- genuinely sitting at +5, the app showed a phantom "+5 pending" -- an
-- eager init-time read had captured 0 as the baseline. Camber/elev never
-- hit this because their baselines are captured lazily on the first
-- Launch visit; this gives rud an equivalent delay (core.wakeup does the
-- deferred read).
local RUD_SETTLE_SEC = 2

function core.captureSetupBaseline()
  S.baseCamberByFM = {}
  S.baseElevByFM   = {}
  -- rud is readable any time (a Variable, not a trim -- see the state
  -- table comment), so it doesn't wait for a flight mode -- but it does
  -- wait for the radio to settle, see RUD_SETTLE_SEC above.
  S.baseRud = nil
  S.rudBaselineAt = os.time() + RUD_SETTLE_SEC
  S.pendingByFM = {}
  S.pendingRud  = nil
end

function core.currentFlightMode()
  local v = srcValue(S.fmSrc)
  if type(v) ~= "number" then return nil end
  return v
end

function core.hasPendingSetup()
  return S.pendingByFM[FM_LAUNCH] ~= nil or S.pendingByFM[FM_ZOOM] ~= nil or S.pendingRud ~= nil
end

-- Confirmed drift THIS SESSION: every "setup" mark's deltas since the
-- last power-on, summed per axis, plus how many such marks there were.
-- This is what the CHANGES screen shows under/behind any pending delta.
-- Pilot's call, 2026-09-10, after two rounds: pending-only read "+0
-- everywhere" right after a confirmed change, and "since the COMPARE
-- baseline" (the first replacement) surprised them by still showing
-- yesterday's drift after a reload -- the power-on baseline is the
-- reference the pilot actually thinks in, and it's the same reference
-- the pending (blue) part already uses. Session boundary = the latest
-- "power" event (core.init logs one whenever there's history); with no
-- power event on record every mark is this session's. Pending,
-- unconfirmed deltas are deliberately NOT included -- callers stack
-- those on top so the two stay visually distinct. The COMPARE baseline
-- (S.baselineGrp, ACCEPT/revert) is a separate question and untouched.
function core.driftThisSession()
  -- Since the latest power-on, accept OR revert -- after either of the
  -- last two the setup is the baseline again (see core.sessionBaselineGrp).
  local since = core.sessionBaselineGrp()
  local d = { launchCamber = 0, launchElev = 0, rud = 0, zoomCamber = 0, zoomElev = 0 }
  local n = 0
  for i = 1, #S.events do
    local e = S.events[i]
    if e.type == "setup" and e.grp > since then
      n = n + 1
      for k in pairs(d) do
        if e[k] then d[k] = d[k] + e[k] end
      end
    end
  end
  return d, n
end

-- Reads and clears the "a change just became pending" edge in one step, so
-- two callers can never both see it true. screen.lua calls this from its
-- own paint(); nothing else should touch S.setupJustDetected directly.
function core.consumeSetupJustDetected()
  local v = S.setupJustDetected
  S.setupJustDetected = false
  return v
end

-- Same read-and-clear shape for "a throw was just recorded" -- screen.lua
-- uses it to return to Main after any throw (pilot's call 2026-09-10).
function core.consumeLaunchRecorded()
  local v = S.launchJustRecorded
  S.launchJustRecorded = false
  return v
end

-- Called every wakeup. Camber/elev are watched per-FM: whichever mode is
-- CURRENTLY active gets its baseline captured lazily (the first tick it's
-- ever seen active after a reset) and its own delta computed -- the OTHER
-- mode's already-detected pending delta (if any) is left untouched, so
-- both can show as pending at once, matching the approved Setup Change
-- Detected mockup's two independent Launch/Zoom cards. rud is only
-- watched while in Launch specifically (it only ever takes effect there
-- -- see the Mixers sheet), even though it could technically be READ from
-- any mode. Outside Launch/Zoom entirely, this does nothing at all --
-- whatever's already pending just sits there, since the underlying trim/
-- VAR values don't revert just because flight mode changed.
function core.pollSetupChange()
  if not S.ready then return end
  local fm = core.currentFlightMode()
  if fm ~= FM_LAUNCH and fm ~= FM_ZOOM then return end

  local hadPending = core.hasPendingSetup()

  local camber = srcValue(S.camberSrc)
  local elev   = srcValue(S.elevSrc)

  if S.baseCamberByFM[fm] == nil then S.baseCamberByFM[fm] = camber end
  if S.baseElevByFM[fm]   == nil then S.baseElevByFM[fm]   = elev   end

  local baseCamber, baseElev = S.baseCamberByFM[fm], S.baseElevByFM[fm]
  local dCamber = (type(camber) == "number" and type(baseCamber) == "number" and camber - baseCamber ~= 0) and (camber - baseCamber) or nil
  local dElev   = (type(elev)   == "number" and type(baseElev)   == "number" and elev   - baseElev   ~= 0) and (elev   - baseElev)   or nil

  S.pendingByFM[fm] = (dCamber or dElev) and { camber = dCamber, elev = dElev } or nil

  if fm == FM_LAUNCH then
    local rud = srcValue(S.rudSrc)
    local dRud = (type(rud) == "number" and type(S.baseRud) == "number" and rud - S.baseRud ~= 0) and (rud - S.baseRud) or nil
    S.pendingRud = dRud
  end

  if core.hasPendingSetup() and not hadPending then
    S.setupJustDetected = true
  end
end

-- Called from core.recordLaunch, right before that throw is grouped --
-- see the call site for why this specific injection point makes the
-- confirming throw itself the new group's first throw, with no separate
-- "armed and waiting" gap the way a manual MARK has. Gathers whatever's
-- pending across BOTH flight modes plus rud into ONE mark event -- a
-- single confirming throw closes out everything detected so far, not just
-- whichever mode happened to be active at that exact moment. Re-baselines
-- every axis that had a pending delta to the value it was detected at, so
-- a further, unrelated drift after this throw is measured from here, not
-- from the pre-mark baseline. An axis with nothing pending keeps its
-- existing baseline untouched.
function core.confirmPendingSetup()
  if not core.hasPendingSetup() then return end
  local pLaunch = S.pendingByFM[FM_LAUNCH]
  local pZoom   = S.pendingByFM[FM_ZOOM]

  addEvent("setup", {
    launchCamber = pLaunch and pLaunch.camber,
    launchElev   = pLaunch and pLaunch.elev,
    rud          = S.pendingRud,
    zoomCamber   = pZoom and pZoom.camber,
    zoomElev     = pZoom and pZoom.elev,
  })

  -- Re-baseline each confirmed axis to the value it was detected AT
  -- (baseline + delta), NOT a live trim read gated on being in that mode:
  -- the confirming throw always arrives after the model has already left
  -- Launch/Zoom (ALT_CALL only fires once it has -- see the template's
  -- own LSW24), so a mode-gated live read never ran, the old baseline
  -- stayed put, and the very next visit to that mode re-detected the same
  -- delta as a brand-new change -- a duplicate mark on every following
  -- throw. Caught by the execution harness 2026-09-10. Rud below never had
  -- this problem (a VAR, readable any time) and is unchanged.
  for _, fm in ipairs({ FM_LAUNCH, FM_ZOOM }) do
    local pend = S.pendingByFM[fm]
    if pend then
      if pend.camber and S.baseCamberByFM[fm] then
        S.baseCamberByFM[fm] = S.baseCamberByFM[fm] + pend.camber
      end
      if pend.elev and S.baseElevByFM[fm] then
        S.baseElevByFM[fm] = S.baseElevByFM[fm] + pend.elev
      end
      S.pendingByFM[fm] = nil
    end
  end
  if S.pendingRud then
    S.baseRud = srcValue(S.rudSrc) or S.baseRud
    S.pendingRud = nil
  end
  haptic(60)
end

-- "Accept current setup as baseline" (2026-09-10, the last item from the
-- original 2.0 spec): nothing about the trims/VAR changes -- this only
-- moves the COMPARE baseline forward to right now, so the marks made so
-- far stop counting as "changes still under evaluation" and the next
-- mark compares against THIS setup's flying, not the original one.
-- Logged as its own "accept" event: that's what persists it (see
-- deriveBaselineGrp), gives it a Review Log row, and opens a fresh set
-- boundary like every other mark so post-accept throws read as their own
-- set. Refuses while a setup change is still pending unconfirmed -- that
-- would quietly bless a change no throw has tested yet, exactly what the
-- throw-confirms rule exists to prevent -- and while a manual MARK is
-- armed with no throws under it, which would just orphan an empty set.
-- Returns true on success; the caller shows the status either way.
function core.acceptBaseline()
  if core.hasPendingSetup() then
    core.setStatus("throw to confirm the pending change first")
    return false
  end
  if core.isArmed() then
    core.setStatus("cancel or fly the pending MARK first")
    return false
  end
  local e = addEvent("accept")
  S.baselineGrp = e.grp
  haptic(60)
  core.setStatus("current setup accepted as baseline")
  return true
end

-- ---------------------------------------------------------------- revert (2.0)

-- The "last known" value for a per-flight-mode trim axis, whether or not
-- that mode is the one currently active -- a trim's :value() only ever
-- reflects whichever mode is live right now (TrimProbe-confirmed scoping,
-- see project memory), so the OTHER mode's card on the Reverting screen has
-- to fall back to whatever was last captured for it (baseline + any still-
-- pending delta) rather than a fresh read. Equals a genuinely live read
-- whenever fm IS the active mode, since core.pollSetupChange keeps that
-- mode's baseline/pending current on every wakeup regardless of which
-- screen is showing.
function core.currentAxisValue(fm, axis)
  local base = (axis == "camber") and S.baseCamberByFM[fm] or S.baseElevByFM[fm]
  if base == nil then return nil end
  local pending = S.pendingByFM[fm]
  local pendingDelta = pending and pending[axis]
  return base + (pendingDelta or 0)
end

-- Rudder offset is the one axis this app can actually edit directly --
-- confirmed read-write via CurveVarProbe, unlike the two trims (read-only
-- from Lua, see the Write path section above). Exposed for the Setup
-- Change Detected screen's own rotary handling (2026-09-09, pilot's own
-- request: a manual CHANGES key plus in-app editing, rather than needing
-- the radio's separate VARs config page). This is a genuine live edit,
-- not a revert -- core.pollSetupChange picks up the resulting difference
-- from baseline on its own next poll exactly like an external edit would,
-- and it still needs a throw to confirm it into an official mark, same as
-- always. No baseline touched here -- letting the ordinary detection path
-- see the change is the whole point, not bypassing it.
function core.nudgeRud(delta)
  if not S.rudSrc then return end
  local cur = srcValue(S.rudSrc)
  if type(cur) ~= "number" then return end
  pcall(function() S.rudSrc:value(cur + delta) end)
end

-- What reverting to `mark` (a "setup" event) would mean for each axis, right
-- now: core.lua only ever stores each mark's own DELTA, never an absolute
-- snapshot, so the target has to be reconstructed as "current known value,
-- minus every later mark's delta for that same axis" -- which only needs
-- data already on hand (no historical baseline lookup), because a trim/VAR's
-- real value persists across power cycles even though S.baseCamberByFM
-- itself gets re-captured fresh every boot (see core.captureSetupBaseline).
-- Deliberately checks ALL FOUR camber/elev slots, not just the ones `mark`
-- itself touched -- if a LATER mark also changed an axis this one never
-- did, reverting to this point in history has to undo that later change
-- too, not just replay this mark's own recorded fields. An axis with no
-- net change since `mark` (sumAfter == 0) is omitted -- nothing to revert.
local function revertTargetsSince(sinceGrp, includePending)
  local specs = {
    { field = "launchCamber", fm = FM_LAUNCH, axis = "camber", label = "Camber" },
    { field = "launchElev",   fm = FM_LAUNCH, axis = "elev",   label = "Elevator" },
    { field = "zoomCamber",   fm = FM_ZOOM,   axis = "camber", label = "Camber" },
    { field = "zoomElev",     fm = FM_ZOOM,   axis = "elev",   label = "Elevator" },
  }
  local function differs(a, b) return math.floor(a + 0.5) ~= math.floor(b + 0.5) end
  local out = {}
  for i = 1, #specs do
    local s = specs[i]
    local sumAfter = 0
    for j = 1, #S.events do
      local e = S.events[j]
      if e.type == "setup" and e.grp > sinceGrp and e[s.field] then
        sumAfter = sumAfter + e[s.field]
      end
    end
    local current = core.currentAxisValue(s.fm, s.axis)
    if current ~= nil then
      local pend = S.pendingByFM[s.fm]
      local pd = (includePending and pend and pend[s.axis]) or 0
      local target = current - sumAfter - pd
      if differs(target, current) then
        out[#out + 1] = { fm = s.fm, axis = s.axis, label = s.label,
                           current = current, target = target }
      end
    end
  end

  -- Rudder offset has no per-FM split (a Variable, readable any time) and
  -- is writable, so its target isn't gated on a flight mode being visited.
  local rudSumAfter = 0
  for j = 1, #S.events do
    local e = S.events[j]
    if e.type == "setup" and e.grp > sinceGrp and e.rud then
      rudSumAfter = rudSumAfter + e.rud
    end
  end
  local current = srcValue(S.rudSrc)
  if current ~= nil then
    local pd = (includePending and S.pendingRud) or 0
    local target = current - rudSumAfter - pd
    if differs(target, current) then
      out[#out + 1] = { fm = FM_LAUNCH, axis = "rud", label = "Rudder offset",
                         current = current, target = target }
    end
  end
  return out
end

-- Revert to a specific confirmed mark: undo every LATER confirmed mark.
-- A still-pending delta is left alone -- it hasn't been confirmed into
-- anything yet, and the next throw will handle it either way.
function core.revertTargetsFor(mark)
  return revertTargetsSince(mark.grp, false)
end

-- The group the CHANGES screen measures "since baseline" from: the latest
-- power-on, accept or revert event (0 if none). Power-on because the
-- pilot thinks in "what did I change today"; accept/revert because after
-- either the setup IS the baseline again, whatever happened earlier in
-- the session. Both core.driftThisSession and revertTargetsToBaseline
-- key off this so the pills and REVERT can never disagree.
function core.sessionBaselineGrp()
  local g = 0
  for i = 1, #S.events do
    local e = S.events[i]
    local t = e.type
    if (t == "power" or t == "accept" or t == "revert") and e.grp > g then g = e.grp end
  end
  return g
end

-- Revert to baseline (the CHANGES screen's REVERT key, pilot's request
-- 2026-09-10): undo everything since sessionBaselineGrp -- confirmed marks
-- AND any still-pending delta, since the pilot's intent is "put it all
-- back", not "put back only what a throw has blessed".
function core.revertTargetsToBaseline()
  return revertTargetsSince(core.sessionBaselineGrp(), true)
end

-- Snapshots revertTargetsFor(mark) ONCE into S.revertTarget -- the fixed
-- reference the Reverting screen compares against -- and, for rudder
-- offset specifically, writes the target immediately (confirmed
-- read-write via CurveVarProbe; trims are not, see project memory), since
-- that's the one axis this app can actually finish on the pilot's behalf.
-- Re-baselines rud right away too, so core.pollSetupChange doesn't see its
-- own write as a brand-new pending change on the very next wakeup.
-- Idempotent -- calling this again (e.g. re-entering Revert Confirm for
-- the same mark after backing out) just recomputes and overwrites.
function core.beginRevert(mark)
  local targets = mark.toBaseline and core.revertTargetsToBaseline() or core.revertTargetsFor(mark)
  local axes, rud = {}, nil
  for i = 1, #targets do
    local t = targets[i]
    if t.axis == "rud" then rud = t else axes[#axes + 1] = t end
  end
  S.revertTarget = { grp = mark.grp, ts = mark.ts, axes = axes, rud = rud,
                     toBaseline = mark.toBaseline or false }
  if rud then
    local ok = pcall(function() S.rudSrc:value(rud.target) end)
    if ok then S.baseRud = rud.target end
  end
end

-- Live per-axis current-vs-target, read fresh every call (unlike the fixed
-- targets themselves) so the Reverting screen can show real-time progress
-- as the pilot's own trim taps close the gap. Matching is compared as
-- whole numbers -- every value this feature deals with is already a
-- whole-number trim/VAR reading (see the mockup's own "+2"/"+4"-style
-- figures), so this avoids a false non-match from float noise.
function core.revertProgress()
  if not S.revertTarget then return nil end
  local function roundEq(a, b)
    return a ~= nil and b ~= nil and math.floor(a + 0.5) == math.floor(b + 0.5)
  end
  local out = { axes = {} }
  for i = 1, #S.revertTarget.axes do
    local a = S.revertTarget.axes[i]
    local current = core.currentAxisValue(a.fm, a.axis)
    out.axes[#out.axes + 1] = { fm = a.fm, axis = a.axis, label = a.label,
      current = current, target = a.target, matched = roundEq(current, a.target) }
  end
  if S.revertTarget.rud then
    local r = S.revertTarget.rud
    local current = srcValue(S.rudSrc)
    out.rud = { label = r.label, current = current, target = r.target,
                matched = roundEq(current, r.target) }
  end
  return out
end

-- True once every trim axis in the current revert reads its target --
-- screen.lua polls this to decide when to auto-close back to Main. Rud
-- isn't checked here: it was already written (and re-baselined) the
-- instant core.beginRevert ran, so it can only ever fail to match if the
-- write itself silently failed, in which case there is nothing further
-- for the pilot to physically do about it anyway.
function core.revertAllMatched()
  local p = core.revertProgress()
  if not p then return false end
  for i = 1, #p.axes do
    if not p.axes[i].matched then return false end
  end
  return true
end

-- Called once core.revertAllMatched() goes true. Logs a "revert" mark (a
-- real group boundary, same as any other mark -- pilot's own call,
-- 2026-09-09: post-revert throws should read as their own set, not get
-- lumped in with the throws taken under the since-corrected settings) and
-- moves S.baselineGrp forward to it, so COMPARE's "how many marks back"
-- label counts fresh from here (the dialog's own "this starts a new
-- baseline from here"). Also re-baselines every axis THIS revert actually
-- touched to its final (now-matching) value and clears any leftover
-- pending delta for just those flight modes -- otherwise the very next
-- throw would immediately re-confirm the same physical change a second
-- time as a brand-new "setup" mark. Deliberately scoped to only the FMs
-- this revert touched, not both unconditionally: an unrelated pending
-- change already sitting in the OTHER mode (nothing to do with this
-- revert) must survive, not get silently discarded here.
function core.finishRevert()
  if not S.revertTarget then return end
  local finals, touchedFMs = {}, {}
  for i = 1, #S.revertTarget.axes do
    local a = S.revertTarget.axes[i]
    finals[#finals + 1] = { fm = a.fm, axis = a.axis, value = core.currentAxisValue(a.fm, a.axis) }
    touchedFMs[a.fm] = true
  end

  local e = addEvent("revert", { revertToGrp = S.revertTarget.grp })
  S.baselineGrp = e.grp

  for i = 1, #finals do
    local f = finals[i]
    if f.value ~= nil then
      if f.axis == "camber" then S.baseCamberByFM[f.fm] = f.value
      else S.baseElevByFM[f.fm] = f.value end
    end
  end
  for fm in pairs(touchedFMs) do S.pendingByFM[fm] = nil end

  S.revertTarget = nil
  -- Discard any edge the revert's own trim-matching adjustments raised --
  -- see core.consumeSetupJustDetected's own comment; without this, backing
  -- out to Main right after a completed revert could immediately bounce
  -- straight into Setup Change Detected for what's actually already-
  -- resolved, stale state from mid-revert, not a genuine new change.
  core.consumeSetupJustDetected()
  haptic(60)
end

-- Launch height is the sensor's running peak read on the ALT_CALL rising
-- edge. The template resets that peak on the launch edge, so the value
-- belongs to the throw that just finished.
local function realCapture()
  local call = srcValue(S.callSrc)
  if type(call) ~= "number" then return end
  local rising = (S.prevCall <= 0 and call > 0)
  S.prevCall = call
  if not rising then return end

  if not core.telemetryLive() then
    core.setStatus("stale telemetry - not recorded")
    return
  end

  local peak = srcValue(S.altSrc, { options = OPTION_SENSOR_MAX })
  if type(peak) ~= "number" then
    core.setStatus("no altitude reading")
    return
  end
  core.recordLaunch(peak, S.unit, os.time())
end

-- Rising-edge detection shared by both assignable switches: level is ignored,
-- so a toggle left ON cannot re-trigger.
local function switchRose(src, prevKey)
  if not src then return false end
  local v = srcValue(src)
  if type(v) ~= "number" then return false end
  local prev = S[prevKey]
  S[prevKey] = v
  return prev <= 0 and v > 0
end

-- switchRose already requires a genuine low-to-high transition, so this only
-- has to stop a contact bouncing within the same second.
local function fireChange()
  if os.time() ~= S.lastChangeAt then
    S.lastChangeAt = os.time()
    S.undoArmed = false
    core.change()
  end
end

-- Destructive with no screen on this path, so it needs two activations.
-- Armed state rather than a stopwatch: os.clock measures CPU time, which
-- starts near zero and advances far slower than real time, so a timed
-- window would have treated the very first flick as a confirmation.
local function fireUndoFlick()
  if S.undoArmed then
    S.undoArmed = false
    if core.undoTarget() then core.undo() else core.setStatus("nothing to undo") end
  elseif core.undoTarget() then
    S.undoArmed = true
    core.setStatus("flick UNDO again to remove")
  else
    core.setStatus("nothing to undo")
  end
end

-- Pilot-assignable CHANGE/UNDO switches only -- these fire regardless of
-- which widget/screen currently has focus, by design (a dedicated switch
-- is a deliberate assignment, not a stray input). Hardware FS1-FS4 are
-- handled separately by core.pollFS below: at the pilot's explicit request
-- (2026-09) NONE of the four act until Throw Trainer's widget is actually
-- the visible, focused thing on screen -- see main.lua's widgetWakeup for
-- where that gate lives.
local function pollSwitches()
  local cs = S.cfg.changeSwitch
  if cs and switchRose(cs, "prevChange") then fireChange() end

  local us = S.cfg.undoSwitch
  if us and switchRose(us, "prevUndo") then fireUndoFlick() end
end

-- Hardware FS1-FS4, matching the on-screen key row 1:1 -- whatever that
-- row currently holds (all 4 slots filled as of 2.0). This only does the
-- edge-detection and reports which one (if any) rose this tick -- the
-- focus/visibility gate and the actual dispatch live in main.lua's
-- widgetWakeup, which is the layer that actually knows about screen.lua
-- and can check whether this widget instance is the one currently on
-- screen.
function core.pollFS()
  if switchRose(S.fs1, "prevFS1") then return 1 end
  if switchRose(S.fs2, "prevFS2") then return 2 end
  if switchRose(S.fs3, "prevFS3") then return 3 end
  if switchRose(S.fs4, "prevFS4") then return 4 end
  return nil
end

-- ---------------------------------------------------------------- lifecycle

-- Re-checked on every wakeup rather than trusted forever from the single
-- read at init. model.id() can apparently return a not-yet-settled value in
-- the first moment or two after power-on, before the RF module finishes
-- initializing -- previously that one bad read at create() time would
-- permanently bind the wrong (almost certainly empty) glider identity for
-- the rest of the session, so real throws already on disk under the correct
-- id would never show up until the next reboot got lucky. This also
-- incidentally covers a genuine model switch mid-session, which a
-- bind-once guard would otherwise never notice. The check itself is just a
-- string compare; the expensive part (re-reading gliders/launches/events)
-- only runs on an actual mismatch, which should be rare once settled.
local function identityStillCurrent()
  return modelIdString() == S.modelId
end

-- Shared by core.init and the mid-session re-bind in core.wakeup below --
-- same load, same fresh-glider check either way. A never-before-seen
-- glider gets seeded with demo data out of the box (2026-09, pilot's
-- request) instead of starting on a blank "waiting for a throw" screen --
-- the exact same core.seedDemo the Config -> Data "Seed sample data"
-- button uses, marker included, purged automatically the moment a real
-- throw comes in (core.recordLaunch's purgeSeedIfPresent), exactly like a
-- manually-seeded set already is.
local function loadIdentityData(fresh)
  loadConfig()
  loadLog()
  if fresh then core.seedDemo() end
end

function core.init()
  if S.ready then return end
  S.dir = resolveDir()
  if not S.dir then S.ioError = "no writable Files/ folder" end
  resolveSources()
  local fresh = bindIdentity()
  loadIdentityData(fresh)
  -- A power cycle closes the open group without arming CHANGE.
  if #S.launches > 0 and not core.isArmed() then
    addEvent("power")
  end
  -- Fresh trim/VAR baseline every boot, per the pilot's own spec -- see
  -- core.captureSetupBaseline's comment for why this does NOT also touch
  -- S.baselineGrp (the COMPARE label's mark count, which must survive a
  -- reboot untouched).
  core.captureSetupBaseline()
  S.ready = true
end

function core.wakeup()
  if not S.ready then
    -- init() failed at create() time (or hasn't been attempted yet).
    -- Retrying here rather than staying permanently bailed-out means a
    -- transient boot-time failure gets another chance every wakeup instead
    -- of silently disabling the whole widget for the rest of the session.
    local ok, err = pcall(core.init)
    if not ok then core.setStatus("init error: " .. tostring(err)) end
    return
  end
  if not identityStillCurrent() then
    local fresh = bindIdentity()
    loadIdentityData(fresh)
    core.captureSetupBaseline()
  end

  -- Defensive re-resolution for EVERY source resolveSources() sets, not
  -- just the four 2.0 ones -- mirrors identityStillCurrent's own
  -- established reasoning just above (model.id() can return a
  -- not-yet-settled value in the first moment or two after power-on): a
  -- source that failed to resolve at core.init() time never got a second
  -- chance before this fix, since resolveSources() used to only ever run
  -- once. Confirmed as a real bug 2026-09-09, twice over: first for
  -- rudder offset specifically (resolved via a bare getVar name lookup,
  -- while camber/elev resolve via CATEGORY_TRIM + member index -- a
  -- different code path that happened to work), then -- after the first
  -- fix only widened this to the four 2.0 sources -- for altSrc/callSrc
  -- too: an entire test session's real throws silently never got
  -- captured at all (every row in Review Log turned out to be original
  -- seed data, not a single real capture since boot), consistent with
  -- ALT_CALL (S.callSrc) having failed that same one-shot resolution and
  -- realCapture's own `if type(call) ~= "number" then return end` guard
  -- silently discarding every throw for the rest of the session as a
  -- result. Widened to cover every 1.4.0 AND 2.0 source resolveSources()
  -- touches, not just the newest ones -- the failure mode isn't specific
  -- to any one source, so the fix shouldn't be either. Cheap once
  -- everything's actually resolved (eight already-true boolean checks),
  -- and backfills rud's OWN baseline the moment it newly resolves rather
  -- than a full captureSetupBaseline() call, which would also wipe out
  -- any OTHER axis's already-legitimate pending delta. Camber/elev need
  -- no equivalent backfill even if THEY were the ones that failed to
  -- resolve -- their baselines are captured lazily inside
  -- core.pollSetupChange itself the next time that flight mode is
  -- visited, not eagerly the way rud's is. altSrc/callSrc/launchSrc need
  -- no backfill of any kind -- realCapture just starts working the very
  -- next tick once they're no longer nil.
  if not (S.camberSrc and S.elevSrc and S.rudSrc and S.fmSrc
          and S.altSrc and S.callSrc and S.launchSrc
          and S.fs1 and S.fs2 and S.fs3 and S.fs4) then
    resolveSources()
  end

  -- Deferred rudder-offset baseline (see RUD_SETTLE_SEC): read once the
  -- settling window after the last captureSetupBaseline has passed. Also
  -- naturally covers a rudSrc that only resolved on a retry above -- it
  -- just gets read whenever it first exists after the window.
  if S.baseRud == nil and S.rudSrc and os.time() >= (S.rudBaselineAt or 0) then
    S.baseRud = srcValue(S.rudSrc)
  end

  realCapture()
  pollSwitches()
  core.pollSetupChange()
end

return core
