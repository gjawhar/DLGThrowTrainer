-- ThrowTrainer shared app surface: the main readout page, the log page, the
-- soft-key row and the key handling. The full-screen System Tool has been
-- removed (widget-only now) -- this still takes host options for the one
-- remaining distinction that matters on a model-screen widget: forms can't
-- be opened from its own key row, so a destructive undo confirms with a
-- second key press instead of a dialog.
--
--   dialogs -- true if the host may build forms/open modal dialogs.
--   keys    -- the soft-key row this host shows. The widget uses
--              CHANGE/UNDO/LOG; CONFIG is intentionally absent, since
--              settings are reached through the widget's own configure()
--              route (see main.lua), not through this key row.

local core, draw, config = ...
local screen = {}

local MAIN, LOG = 1, 4

-- Safe button first, so the default action is never destructive. Doesn't
-- depend on any per-instance state, so it's exposed at module level and
-- usable directly from main.lua's widgetConfigure (the widget's settings
-- page), not just from inside a screen.new() instance's own CONFIG key.
local function confirmErase()
  local nL, nC = core.counts()
  form.openDialog({
    title = "Erase all data",
    message = string.format(
      "Delete %d throws and %d change markers for %s? This cannot be undone.",
      nL, nC, core.S.name),
    width = 500,
    buttons = {
      { label = "Keep data", action = function() return true end },
      { label = "Erase",     action = function() core.erase() lcd.invalidate() return true end },
    },
  })
end

screen.confirmErase = confirmErase

-- ---------------------------------------------------------------- instance

-- Each host gets its own view state, so scrolling the log in the widget does
-- not move the cursor in another instance.
function screen.new(opts)
  local V = {
    screen  = MAIN,
    focus   = 1,
    logTop  = 1,
    logSel  = 1,
    inForm  = false,
    -- Set by a first UNDO press when no dialog is available, cleared by any
    -- other action. Deliberately not time-based: os.clock is CPU time, not
    -- wall time, so a timed window would expire unpredictably on the radio.
    undoArmed = false,
    seenN     = 0,
    keys    = opts.keys,
    dialogs = opts.dialogs,
  }

  local self = { V = V }

  -- ------------------------------------------------------------ dialogs

  local function confirmUndo()
    local t = core.undoTarget()
    if not t then
      core.setStatus("nothing to undo")
      return
    end

    if not V.dialogs then
      -- No forms on a model screen, so the confirmation is a second UNDO
      -- press. Any other action clears it, so a forgotten first press cannot
      -- turn into an accidental delete later.
      if V.undoArmed then
        V.undoArmed = false
        core.undo()
      else
        V.undoArmed = true
        if t.kind == "launch" then
          core.setStatus("press UNDO again to remove " .. draw.fmt(t.rec.h, t.rec.u))
        else
          core.setStatus("press UNDO again to remove the change")
        end
      end
      return
    end

    local msg
    if t.kind == "launch" then
      msg = string.format("Remove the last throw (%s)?", draw.fmt(t.rec.h, t.rec.u))
    else
      msg = "Remove the last change marker? The groups either side will merge."
    end
    form.openDialog({
      title = "Undo",
      message = msg,
      width = 460,
      buttons = {
        { label = "Keep",   action = function() return true end },
        { label = "Remove", action = function() core.undo() lcd.invalidate() return true end },
      },
    })
  end

  self.confirmErase = confirmErase

  -- ------------------------------------------------------------ main page

  -- The full surface needs the header block, a usable strip and the soft-key
  -- row. Below that it degrades to the compact read-out rather than drawing
  -- off the bottom edge. A tool is always given a full screen, so this only
  -- fires for unexpected geometry.
  local function fits(w, h)
    local m = draw.metrics(w, h)
    return m.tier == "A" and h >= 12 * m.th
  end

  self.fits = fits

  -- Soft-key identifiers stay the same internally (activate() switches on
  -- them, and switch-assignment mirrors the CHANGE key) -- only the printed
  -- label changed, so relabelling is purely cosmetic and touches nothing
  -- else.
  local KEY_LABEL = { CHANGE = "MARK", UNDO = "UNDO", LOG = "LOG", CONFIG = "CFG" }

  local function paintMain(w, h)
    if not fits(w, h) then
      draw.widget(w, h)
      return
    end

    local m = draw.metrics(w, h)
    local p = draw.palette()
    local st = core.stats(m.bars)
    local pad = m.pad * 2
    local line = m.th + 4

    draw.clear(w, h, p)
    lcd.font(FONT_S)

    -- Title bar: which glider, which set, and the unit everything below is
    -- in -- read once here rather than repeated on every figure.
    local y = pad
    lcd.color(p.text)
    draw.textAt(pad, y, string.format("%s . Set %d", core.S.name, st.group), w * 0.75)
    lcd.color(p.dim)
    local uw = lcd.getTextSize(st.unit)
    draw.textAt(w - pad - uw, y, st.unit)
    y = y + line
    lcd.color(p.line)
    lcd.pen(SOLID)
    lcd.drawLine(pad, y, w - pad, y)
    y = y + m.pad

    local colW   = math.floor(w * 0.46)
    local rightX = math.floor(w * 0.52)
    local colTop = y

    -- Left column: the throw that just happened, and how it compares.
    lcd.color(p.dim)
    draw.textAt(pad, y, "LAST LAUNCH", colW)
    y = y + line
    local _, heroH = draw.hero(pad, y, st.last and st.last.h, st.unit, p.text, FONT_XL, FONT_M)
    -- heroH is FONT_XL's height, not m.th (which is measured from FONT_S) --
    -- using m.th here was the bug behind the badge overlapping the number.
    y = y + heroH + 10

    local suffix
    if st.armed then suffix = nil
    elseif st.fallback then suffix = "vs previous"
    else suffix = "vs prev set" end
    local _, bh = draw.deltaBadge(pad, y, st, suffix, colW, p)
    y = y + bh + m.pad

    lcd.font(FONT_S)
    lcd.color(p.dim)
    if st.afterN > 0 then
      draw.textAt(pad, y, string.format("SET %d . n=%d", st.group, st.afterN), colW)
      y = y + line
      draw.textAt(pad, y, string.format("avg %s  best %s",
        draw.fmt1(st.afterAvg), draw.fmt(st.afterBest)), colW)
    else
      draw.textAt(pad, y, string.format("SET %d . no throws yet", st.group), colW)
    end

    -- Right column: how this set stacks up against everything else on
    -- record, cheapest comparison first.
    local ry = colTop
    lcd.color(p.dim)
    draw.textAt(rightX, ry, "COMPARE", w - rightX - pad)
    ry = ry + line + 2

    local rows = {
      { label = st.fallback and "Previous" or string.format("Prev set . n=%d", st.cmpBeforeN),
        value = draw.fmt1(st.cmpBeforeAvg), color = p.text },
      { label = string.format("Last %d", st.windowTarget or 20),
        value = draw.fmt1(st.windowAvg), color = p.text },
      { label = string.format("Lifetime . n=%d", st.allN),
        value = draw.fmt1(st.allAvg), color = p.text },
      { label = "Best ever",
        value = draw.fmt(st.best), color = p.accent },
    }
    local labelW = math.floor((w - rightX - pad) * 0.62)
    for i = 1, #rows do
      lcd.font(FONT_S)
      lcd.color(p.dim)
      draw.textAt(rightX, ry, rows[i].label, labelW)
      lcd.font(FONT_M)
      lcd.color(rows[i].color)
      local vw = lcd.getTextSize(rows[i].value)
      draw.textAt(w - pad - vw, ry - 2, rows[i].value)
      ry = ry + line
    end

    -- The strip. Capped well below "fill whatever's left", so it doesn't
    -- crowd out the numbers above it or the two panels above that -- room
    -- for a "marker" caption under a change boundary only when there's
    -- genuinely space for a third text line below it.
    local softH = line + m.pad * 2
    local top = math.max(y, ry) + m.pad * 2
    local avail = h - top - softH - pad
    local wantCaption = avail > (m.th * 3)
    local capH = wantCaption and (m.th + 2) or 0
    local maxStrip = math.floor(h * 0.30)
    local stripH = math.min(avail - capH, maxStrip)
    if stripH < m.th * 2 then stripH = m.th * 2 end

    draw.strip(pad, top, w - pad * 2, stripH, core.strip(m.bars), m, p)
    if wantCaption then
      draw.stripCaptions(pad, top + stripH + 2, w - pad * 2, core.strip(m.bars), p)
    end

    -- Status line, when there's something worth saying and room to say it.
    local sy = top + stripH + capH + 2
    local status = core.status()
    lcd.font(FONT_S)
    if status then
      lcd.color(p.armed)
      draw.textAt(pad, sy, status, w - pad * 2)
    elseif core.S.ioError then
      lcd.color(p.bad)
      draw.textAt(pad, sy, "storage: " .. core.S.ioError, w - pad * 2)
    elseif not core.telemetryLive() then
      lcd.color(p.bad)
      draw.textAt(pad, sy, "no telemetry", w - pad * 2)
    end

    -- Soft keys. On a widget these are only live once the widget has focus,
    -- so they are dimmed until then to show that plainly. The focused key
    -- gets a solid fill rather than a thin border -- the previous
    -- thin-border-vs-thick-border distinction was too subtle to track while
    -- turning the wheel, and MARK's accent border was drawn unconditionally
    -- regardless of focus, which made it look permanently "selected" and
    -- masked whichever key actually had focus.
    local live = (not opts.needsFocus) or (lcd.hasFocus and lcd.hasFocus())
    local kw = math.floor((w - pad * 2) / #V.keys)
    local ky = h - softH
    lcd.font(FONT_S)
    for i = 1, #V.keys do
      local kx = pad + (i - 1) * kw
      local id = V.keys[i]
      local label = KEY_LABEL[id] or id
      local armedKey = (id == "CHANGE" and st.armed)
      if armedKey then label = "CANCEL" end

      local bx, by, bw2, bh2 = kx + 2, ky, kw - 4, softH - m.pad
      local focused = live and V.focus == i

      if not live then
        lcd.color(p.line)
        lcd.drawRectangle(bx, by, bw2, bh2, 1)
        lcd.color(p.line)
      elseif focused then
        lcd.color(armedKey and p.armed or p.text)
        lcd.drawFilledRectangle(bx, by, bw2, bh2)
        lcd.color(p.bg)
      else
        lcd.color(armedKey and p.armed or p.line)
        lcd.drawRectangle(bx, by, bw2, bh2, 1)
        lcd.color(armedKey and p.armed or p.dim)
      end

      local tw = lcd.getTextSize(label)
      draw.textAt(kx + math.floor((kw - tw) / 2), ky + m.pad, label, kw - 6)
    end
  end

  -- ------------------------------------------------------------ log page

  local function paintLog(w, h)
    local m = draw.metrics(w, h)
    local p = draw.palette()
    local pad = m.pad * 2
    local line = m.th + 2
    local rows = math.floor((h - pad * 2 - line) / line)
    if rows < 1 then rows = 1 end

    draw.clear(w, h, p)
    lcd.font(FONT_S)
    lcd.color(p.dim)
    draw.textAt(pad, pad, "LOG - newest first", w - pad * 2)

    local L = core.S.launches
    local total = #L
    if total == 0 then
      lcd.color(p.dim)
      draw.textAt(pad, pad + line * 2, "no throws recorded", w - pad * 2)
      return
    end

    if V.logSel < 1 then V.logSel = 1 end
    if V.logSel > total then V.logSel = total end
    if V.logSel < V.logTop then V.logTop = V.logSel end
    if V.logSel >= V.logTop + rows then V.logTop = V.logSel - rows + 1 end

    local y = pad + line
    for i = V.logTop, math.min(V.logTop + rows - 1, total) do
      local rec = L[total - i + 1]                   -- newest first
      if i == V.logSel then
        lcd.color(lcd.GREY(60))
        lcd.drawFilledRectangle(pad, y, w - pad * 2, line)
      end

      lcd.color(rec.st == "ok" and p.text or (rec.st == "low" and p.bad or p.high))
      draw.textAt(pad + 4, y, string.format("%3d.", total - i + 1), w * 0.12)
      draw.textAt(pad + math.floor(w * 0.12), y, draw.fmt(rec.h, rec.u), w * 0.2)
      lcd.color(p.dim)
      draw.textAt(pad + math.floor(w * 0.34), y, os.date("%H:%M:%S", rec.ts), w * 0.24)
      draw.textAt(pad + math.floor(w * 0.60), y, "set " .. tostring(rec.grp), w * 0.16)
      if rec.st ~= "ok" then
        draw.textAt(pad + math.floor(w * 0.78), y,
          rec.st == "low" and "low" or "high", w * 0.18)
      end
      y = y + line
    end
  end

  -- ------------------------------------------------------------ actions

  local function activate(i)
    local key = V.keys[i]
    if key ~= "UNDO" then V.undoArmed = false end
    if key == "CHANGE" then
      core.change()
    elseif key == "UNDO" then
      confirmUndo()
    elseif key == "LOG" then
      V.screen = LOG
      V.logSel, V.logTop = 1, 1
    elseif key == "CONFIG" then
      V.screen = 5
      -- paintMain stops running the instant V.inForm is set, so its own
      -- top-of-frame clear (above) never gets a chance to run for this
      -- transition -- without this, the last custom-drawn frame stays on
      -- screen underneath the form fields (this was the settings/main
      -- overlap bug). clearAll rather than clear: this runs from an event
      -- handler, not paint, so lcd.getWindowSize() isn't safe to call here.
      draw.clearAll(draw.palette())
      form.clear()
      V.inForm = true
      config.build(confirmErase)
    end
    lcd.invalidate()
  end

  -- Direction is in the key constant; x is a detent magnitude, so using it
  -- lets a fast spin move more than one step.
  local function step(value, x)
    local n = math.abs(tonumber(x) or 1)
    if n < 1 then n = 1 end
    if value == KEY_ROTARY_RIGHT then return n end
    if value == KEY_ROTARY_LEFT then return -n end
    return 0
  end

  -- ------------------------------------------------------------ events

  function self.event(value, x)
    -- A form owns its own keys; only RTN needs intercepting to get back.
    if V.inForm then
      if value == KEY_RTN_FIRST or value == 99 then
        form.clear()
        V.inForm = false
        V.screen = MAIN
        -- Mirror the entry-side clear: wipe whatever the form left behind
        -- so there's no one-frame flash of stale form content before
        -- paintMain's own clear runs on the next paint. Same reasoning as
        -- above -- not inside paint(), so use clearAll, not clear.
        draw.clearAll(draw.palette())
        lcd.invalidate()
        return true
      end
      return false
    end

    if value == KEY_ROTARY_RIGHT or value == KEY_ROTARY_LEFT then
      local d = step(value, x)
      if V.screen == MAIN then
        -- Moving the cursor is a change of intent, so a pending undo lapses.
        V.undoArmed = false
        -- Wrap modularly, so a fast spin overshooting by 2 lands on the
        -- second key rather than collapsing onto the first.
        V.focus = ((V.focus - 1 + d) % #V.keys) + 1
      elseif V.screen == LOG then
        V.logSel = V.logSel + d
      end
      lcd.invalidate()
      return true
    end

    -- Act on BREAK, not FIRST: BREAK also fires after a long press, and there
    -- is no separate long-press constant to distinguish them on FIRST.
    if value == KEY_ENTER_BREAK then
      if V.screen == MAIN then activate(V.focus) end
      return true
    end

    if value == KEY_RTN_FIRST or value == KEY_EXIT_FIRST or value == 99 then
      if V.screen ~= MAIN then
        V.screen = MAIN
        lcd.invalidate()
        return true
      end
      -- Unhandled on the main page: lets a tool close, and lets a widget pass
      -- the key back to the model screen.
      return false
    end

    return false
  end

  function self.paint(w, h)
    if V.inForm then return end
    -- A throw landing while an undo is pending changes what would be removed,
    -- so the pending confirmation lapses rather than deleting the new throw.
    local n = #core.S.launches
    if n ~= V.seenN then
      if V.undoArmed then
        V.undoArmed = false
        core.setStatus(nil)
      end
      V.seenN = n
    end
    if V.screen == LOG and fits(w, h) then
      paintLog(w, h)
    else
      paintMain(w, h)
    end
  end

  function self.reset()
    V.screen = MAIN
    V.focus = 1
    V.inForm = false
    V.undoArmed = false
  end

  function self.leaveForm()
    if V.inForm then
      form.clear()
      V.inForm = false
      draw.clearAll(draw.palette())
    end
  end

  return self
end

return screen
