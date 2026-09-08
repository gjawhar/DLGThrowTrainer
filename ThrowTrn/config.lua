-- ThrowTrainer config page (S5). Built with the real form API so switch and
-- source assignment use the radio's own pickers rather than a hand-rolled one.

local core, draw = ...
local config = {}

local function cfg() return core.S.cfg end

local function num(line, min, max, key, suffix, step)
  local f = form.addNumberField(line, nil, min, max,
    function() return cfg()[key] end,
    function(v) cfg()[key] = v core.saveConfig() end)
  if suffix then f:suffix(suffix) end
  if step then f:step(step) end
  return f
end

-- Rejecting MOM_LAUNCH here matters: it fires on every throw, so assigning it
-- to CHANGE would open a new group on each launch and destroy the grouping.
local function sourceField(line, key, reject)
  return form.addSourceField(line, nil,
    function() return cfg()[key] end,
    function(v)
      if reject and v and core.S.launchSrc then
        local a, b = pcall(function() return v:name() end)
        local c, d = pcall(function() return core.S.launchSrc:name() end)
        if a and c and b == d then
          core.setStatus("cannot use MOM_LAUNCH")
          return
        end
      end
      cfg()[key] = v
      core.saveConfig()
    end)
end

function config.build(onErase, onDone)
  local u = core.S.unit
  local maxH = (u == "m") and 200 or 650

  -- Measurement -------------------------------------------------------------
  local panel = form.addExpansionPanel("Measurement")

  local line = panel:addLine("Minimum height")
  num(line, 0, maxH, "floor", u)

  line = panel:addLine("Comparison window")
  num(line, 3, 200, "window", "throws")

  -- Controls ----------------------------------------------------------------
  panel = form.addExpansionPanel("Controls")

  line = panel:addLine("CHANGE switch")
  sourceField(line, "changeSwitch", true)

  line = panel:addLine("UNDO switch")
  sourceField(line, "undoSwitch", true)

  -- Display -----------------------------------------------------------------
  panel = form.addExpansionPanel("Display")
  panel:open(false)

  line = panel:addLine("Bars (0 = auto)")
  num(line, 0, 12, "bars")

  line = panel:addLine("Theme")
  form.addChoiceField(line, nil, { { "Night", 1 }, { "Day", 2 } },
    function() return cfg().theme end,
    function(v)
      cfg().theme = v
      core.saveConfig()
      lcd.invalidate()   -- palette is re-read on the next paint, not live
    end)

  -- Data --------------------------------------------------------------------
  panel = form.addExpansionPanel("Data")
  panel:open(false)

  local nL, nC = core.counts()
  line = panel:addLine("Recorded")
  form.addStaticText(line, nil,
    string.format("%d throws, %d changes", nL, nC))

  line = panel:addLine("Seed sample data")
  form.addButton(line, nil, { text = "Seed 10 @ 60-95", press = function()
    core.seedDemo(10, 60, 95)
  end })

  line = panel:addLine("Erase this glider's data")
  form.addButton(line, nil, { text = "Erase...", press = function()
    if onErase then onErase() end
  end })

  -- About ------------------------------------------------------------------
  panel = form.addExpansionPanel("About")
  panel:open(false)

  line = panel:addLine("Version")
  form.addStaticText(line, nil, core.VERSION)

  line = panel:addLine("Glider")
  form.addStaticText(line, nil, core.S.name)

  line = panel:addLine("Units")
  form.addStaticText(line, nil, core.S.unit .. " (from sensor)")

  line = panel:addLine("Storage")
  form.addStaticText(line, nil, core.S.dir or "unavailable")

  if onDone then onDone() end
end

return config
