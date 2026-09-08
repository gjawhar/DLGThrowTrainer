-- ThrowTrainer core: identity, persistence, capture, grouping, statistics.
-- Loaded once by main.lua and shared by the widget and the tool, so there is
-- exactly one in-memory state and one set of files.

local core = {}

core.VERSION = "1.4.0"

-- ---------------------------------------------------------------- constants

local LOG_CAP       = 5000           -- rolling record cap
local STALE_MS      = 2000           -- telemetry freshness gate
local STATUS_SEC    = 3              -- status line dwell, wall-clock seconds

core.STATUS_SEC = STATUS_SEC

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
  fs1        = nil,              -- hardware CHANGE
  fs2        = nil,              -- hardware UNDO
  fs3        = nil,              -- hardware LOG
  fs4        = nil,              -- hardware CONFIG
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
}

core.S = S

-- ---------------------------------------------------------------- config

local DEFAULTS_FT = { floor = 25 }
local DEFAULTS_M  = { floor = 8  }

local function defaults()
  local d = {
    floor        = DEFAULTS_FT.floor,
    timeout      = 15,          -- capture window cap, seconds
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

-- Function Switches (FS1-FS4) are not logic switches and have no
-- documented CATEGORY_* constant -- confirmed via the DLGPoker project's
-- own hardware sweep (its spec S11): asking a manually-picked FS1 source
-- what it is returned raw category number 12, member 0, with FS2-FS4 as
-- members 1-3 of that same numeric category. This literal is inherently
-- fragile -- not from any FrSky documentation, and could differ on
-- another Ethos build or radio family -- but it's the only approach
-- confirmed to actually work.
local FS_CATEGORY_NUMERIC = 12

local function getFS(member)
  local ok, src = pcall(system.getSource,
    { category = FS_CATEGORY_NUMERIC, member = member })
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
      }
    end
  end

  S.sessionLaunches = 0
  S.sessionEvents   = 0
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

function core.hasChange()
  for i = 1, #S.events do
    if S.events[i].type == "change" then return true end
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

-- The most recent closed group that actually holds data. A group emptied by
-- undo is skipped rather than reported as an empty Before.
function core.beforeGroup()
  local cur = core.currentGroup()
  for g = cur - 1, 1, -1 do
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

  local st = {
    unit      = S.unit,
    armed     = core.isArmed(),
    hasChange = core.hasChange(),
    group     = cur,
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
    return "low"                    -- discarded silently, armed state intact
  end

  -- No ceiling/ "high" flag on new throws any more -- removed at the pilot's
  -- request (S.cfg.ceiling no longer exists). A "high" status can still show
  -- up on log/strip rows written by an older version of the app before this
  -- removal; draw.lua and screen.lua still render that legacy status
  -- correctly rather than silently reinterpreting old data.
  local st = "ok"

  local grp = core.currentGroup()
  S.seq = S.seq + 1
  local rec = { ts = ts, h = height, u = unit, grp = grp, st = st, seq = S.seq,
                seed = false }
  S.launches[#S.launches + 1] = rec
  S.sessionLaunches = S.sessionLaunches + 1

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

local function addEvent(kind)
  local grp = core.currentGroup() + 1
  local ts = os.time()
  S.seq = S.seq + 1
  local e = { ts = ts, type = kind, grp = grp, seq = S.seq }
  S.events[#S.events + 1] = e
  S.sessionEvents = S.sessionEvents + 1
  appendRow("events", { tostring(ts), core.activeGid(), kind, tostring(grp) })
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

-- Most recent event of any kind, limited to this power-on session.
function core.undoTarget()
  local lastL = S.launches[#S.launches]
  local lastE = S.events[#S.events]
  local haveL = S.sessionLaunches > 0 and lastL
  local haveE = S.sessionEvents > 0 and lastE and lastE.type == "change"

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
  local age = srcAge(S.altSrc)
  return age >= 0 and age < STALE_MS
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

-- Hardware FS1-FS4, matching the on-screen CHANGE/UNDO/LOG/CONFIG key row
-- 1:1. This only does the edge-detection and reports which one (if any)
-- rose this tick -- the focus/visibility gate and the actual dispatch live
-- in main.lua's widgetWakeup, which is the layer that actually knows about
-- screen.lua and can check whether this widget instance is the one
-- currently on screen.
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
  end
  realCapture()
  pollSwitches()
end

return core
