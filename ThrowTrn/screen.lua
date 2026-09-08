-- ThrowTrainer shared app surface: the main readout page, the log page, the
-- soft-key row and the key handling. The full-screen System Tool has been
-- removed (widget-only now) -- this still takes host options for the one
-- remaining distinction that matters on a model-screen widget: forms can't
-- be opened from its own key row, so a destructive undo confirms with a
-- second key press instead of a dialog.
--
--   dialogs -- true if the host may build forms/open modal dialogs.
--   keys    -- the soft-key row this host shows. The widget uses
--              CHANGE/UNDO/LOG/CONFIG, one key per physical FS switch (see
--              main.lua for the crash history behind re-adding CONFIG here
--              and what still needs re-verifying on real hardware).

local core, draw, config = ...
local screen = {}

local MAIN, LOG = 1, 4

-- Touch support (X20RS and other touch-capable radios): tap a key directly
-- instead of rotating focus onto it first. Same heuristic already confirmed
-- working in the DLGPoker project -- system.getVersion().board, excluding
-- "X14" specifically, since there is no confirmed "has touchscreen" field
-- to check directly. Computed once, not every frame -- the board is not
-- going to change mid-session.
local touchCapable = nil
local function isTouchCapable()
  if touchCapable ~= nil then return touchCapable end
  local ok, v = pcall(system.getVersion)
  local board = (ok and v and v.board) or ""
  touchCapable = not string.find(tostring(board), "X14")
  return touchCapable
end

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
    -- Hit-test rectangles for the current key row, rebuilt every paint --
    -- keyed by the SAME index activate() already uses for rotary+enter, so
    -- a tap and a rotary-select land on exactly the same action.
    keyRects = {},
    -- True between a tap's press and its still-pending release call --
    -- see self.event's touch-pairing comment.
    touchConsuming = false,
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

  -- Throw Trainer is only offered at two sizes, both chosen at the pilot's
  -- request (2026-09) so the numbers stay legible and the strip has room to
  -- be read at a glance -- anything smaller falls back to draw.widget's
  -- plain "needs Full or Half" message.
  --   full -- the rich, interactive layout: key row, LAST LAUNCH + COMPARE
  --           panels, then the strip.
  --   half -- a wide-but-shorter slot (the "super wide" one full-width
  --           half-height placements make). Deliberately passive-only, by
  --           the pilot's explicit request: no keys, no settings, no
  --           marking a change -- just the bar strip, each bar labeled
  --           with its own value, filling essentially the whole slot.
  -- Width, not the tier label alone, is what actually distinguishes "half"
  -- from a narrow-but-tallish cell that happens to clear the same height --
  -- a half-width column is not what this shape means.
  local function layoutKind(w, h)
    local m = draw.metrics(w, h)
    if m.tier == "A" and h >= 12 * m.th then return "full" end
    -- The real bottom-half X14 slot measured out to ~6.5x th -- 7x
    -- rejected it outright (confirmed on-device, 2026-09).
    if w >= 20 * m.th and h >= 6 * m.th then return "half" end
    return nil
  end

  -- Whether this instance currently accepts input at all. Half is passive
  -- history only (see layoutKind above) -- no keys, nothing to focus -- so
  -- only Full reports true here. main.lua's widgetEvent/widgetWakeup use
  -- this to decide whether rotary, tap, or hardware FS should reach this
  -- instance at all.
  local function fits(w, h)
    return layoutKind(w, h) == "full"
  end

  self.fits = fits

  -- Soft-key identifiers stay the same internally (activate() switches on
  -- them, and switch-assignment mirrors the CHANGE key) -- only the printed
  -- label changed, so relabelling is purely cosmetic and touches nothing
  -- else.
  local KEY_LABEL = { CHANGE = "MARK", UNDO = "UNDO", LOG = "LOG", CONFIG = "CFG" }

  -- Shared by both layouts -- whatever's worth saying (an error, a stale-
  -- telemetry warning) matters the same regardless of which one is showing.
  local function drawStatus(pad, sy, w, p)
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
  end

  local function paintMain(w, h)
    local kind = layoutKind(w, h)
    if not kind then
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

    if kind == "half" then
      -- Pure passive history, filling the entire slot: no key row, no
      -- title bar, no hero number, no delta, and (2026-09) no "current
      -- set"/"previous set" captions either -- this size is read-only by
      -- design, so labelling which bars belong to which set implies a
      -- kind of analysis this view isn't meant to offer. Marking a change
      -- happens on the Full layout; this is just the bars, each one
      -- labeled with its own value.
      local stripH = h - pad * 2
      if stripH < m.th * 2 then stripH = m.th * 2 end
      draw.strip(pad, pad, w - pad * 2, stripH, core.strip(m.bars), m, p)
      return
    end

    -- Key row first, pinned to the very top of the canvas. Physical
    -- FS1-FS4 sit ABOVE the screen on the X14 (same layout the DLGPoker
    -- project uses), so the on-screen labels sit as close to those buttons
    -- as the canvas allows -- directly under them -- rather than at the
    -- bottom, which used to force a top-to-bottom mental jump on every
    -- press. Four keys (CHANGE, UNDO, LOG, CONFIG) line up 1:1 with
    -- FS1-FS4, so there's no leftover key needing a special-cased spot.
    --
    -- On a widget these are only live once it has focus, so they're dimmed
    -- until then to show that plainly. The focused key gets a solid fill
    -- rather than a thin border -- a thin-vs-thick distinction was too
    -- subtle to track while turning the wheel.
    local live = (not opts.needsFocus) or (lcd.hasFocus and lcd.hasFocus())
    local keyRowH = line + m.pad * 2
    local kw = math.floor(w / #V.keys)
    V.keyRects = {}
    for i = 1, #V.keys do
      local kx = (i - 1) * kw
      local id = V.keys[i]
      local label = KEY_LABEL[id] or id
      local armedKey = (id == "CHANGE" and st.armed)
      if armedKey then label = "CANCEL" end

      local bx, by, bw2, bh2 = kx + 2, 0, kw - 4, keyRowH - m.pad
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
      draw.textAt(kx + math.floor((kw - tw) / 2), m.pad, label, kw - 6)

      -- Tap targets only exist once the row is actually live, matching the
      -- visual affordance -- a dimmed, unfocused key can't be woken up by a
      -- stray tap any more than it could by a stray rotary press.
      if live and isTouchCapable() then
        V.keyRects[i] = { x = kx, y = 0, w = kw, h = keyRowH }
      end
    end

    -- Title bar: which glider, and the unit everything below is in -- read
    -- once here rather than repeated on every figure. Sets are no longer
    -- numbered (there's only ever "current" and "previous" -- see the strip
    -- captions below), so there's nothing else to show here. Full only --
    -- Half skips this entirely, see above.
    local y = keyRowH + pad
    lcd.color(p.text)
    draw.textAt(pad, y, core.S.name, w * 0.75)
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
    else suffix = "vs previous set" end
    local _, bh = draw.deltaBadge(pad, y, st, suffix, colW, p)
    y = y + bh + m.pad

    lcd.font(FONT_S)
    lcd.color(p.dim)
    -- No set number and no throw count here -- the strip right below shows
    -- exactly these throws as bars, so a count would just repeat what's
    -- already countable on screen.
    if st.afterN > 0 then
      draw.textAt(pad, y, "CURRENT SET", colW)
      y = y + line
      draw.textAt(pad, y, string.format("avg %s  best %s",
        draw.fmt1(st.afterAvg), draw.fmt(st.afterBest)), colW)
    else
      draw.textAt(pad, y, "CURRENT SET . no throws yet", colW)
    end

    -- Right column: how this set stacks up against everything else on
    -- record, cheapest comparison first.
    local ry = colTop
    lcd.color(p.dim)
    draw.textAt(rightX, ry, "COMPARE", w - rightX - pad)
    ry = ry + line + 2

    -- "Last N" keeps its number -- that's a configured window size, not a
    -- throw count, and it's not visible anywhere else on screen. Lifetime
    -- and Previous set drop theirs: Previous set's throws are exactly the
    -- "previous set" bars in the strip below (countable there), and
    -- Lifetime's count is churn that doesn't change what to do next.
    --
    -- Always "Previous set", even in the st.fallback case (no CHANGE marked
    -- yet, so this row is really a recent-vs-earlier split of one ongoing
    -- set rather than two real sets) -- matching the wording used
    -- everywhere else (the title bar, the strip captions) beat being
    -- technically precise about a distinction the pilot has no way to see
    -- on screen anyway.
    local rows = {
      { label = "Previous set",
        value = draw.fmt1(st.cmpBeforeAvg), color = p.text },
      { label = string.format("Last %d", st.windowTarget or 20),
        value = draw.fmt1(st.windowAvg), color = p.text },
      { label = "Lifetime",
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

    -- The strip fills whatever's left below the two panels, minus one
    -- reserved line for the status row underneath. A fixed 30%-of-h cap
    -- used to sit here instead of an actual reservation; on the X14 it was
    -- close enough to invisible, but on a bigger screen like the X20RS it
    -- left a large dead patch of background between the strip and the
    -- status line (confirmed on-device, 2026-09). statusH is reserved
    -- unconditionally (whether or not there's a message to show right
    -- now), so the bars don't visibly resize every time a status message
    -- comes and goes.
    local statusH = line
    local top = math.max(y, ry) + m.pad * 2
    local avail = h - top - pad - statusH
    local wantCaption = avail > (m.th * 3)
    local capH = wantCaption and (m.th + 2) or 0
    local stripH = avail - capH
    if stripH < m.th * 2 then stripH = m.th * 2 end

    draw.strip(pad, top, w - pad * 2, stripH, core.strip(m.bars), m, p)
    if wantCaption then
      draw.stripCaptions(pad, top + stripH + 2, w - pad * 2, core.strip(m.bars), p)
    end

    drawStatus(pad, top + stripH + capH + 2, w, p)
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

  -- Public entry point for hardware FS1-FS4 -- see main.lua's widgetWakeup,
  -- which only calls this once it's already confirmed this instance is the
  -- visible, focused one. Mirrors what a tap or a rotary+ENTER on the same
  -- key index would do.
  function self.pressKey(i)
    if V.inForm or V.screen ~= MAIN or not V.keys[i] then return end
    V.focus = i
    activate(i)
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

  function self.event(value, x, y, category)
    -- Touch phase pairing. Confirmed on X20RS (2026-09): Ethos calls this
    -- TWICE per tap -- once on press, once on release -- and there's no
    -- reliable value/category signal to tell them apart (both calls came
    -- back with the same category and near-identical, non-enum-looking
    -- values -- an internal counter/timestamp, not a phase flag). Rather
    -- than guess at an undocumented meaning, treat every OTHER touch call
    -- as the closing half of the same gesture and swallow it outright.
    --
    -- This has to run before the V.inForm/V.screen gates below, not inside
    -- them -- a key like LOG or CONFIG changes V.screen/V.inForm as its
    -- own action, so the release half of THAT tap would arrive with
    -- different gate state than the press half and could otherwise slip
    -- past unswallowed (or, worse, get treated as a fresh press on
    -- whatever's now underneath it).
    if V.touchConsuming and isTouchCapable() and x and y and x > 0 and y > 0 then
      V.touchConsuming = false
      return true
    end

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

    -- Touch: hit-test against the rectangles paintMain recorded this same
    -- frame.
    if V.screen == MAIN and isTouchCapable() and x and y and x > 0 and y > 0 then
      for i, r in pairs(V.keyRects) do
        if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
          V.focus = i
          activate(i)
          V.touchConsuming = true
          return true
        end
      end
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
