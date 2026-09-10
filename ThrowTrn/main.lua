-- ThrowTrainer 1.4.0 -- DLG throw height trainer for FrSky Ethos.
--
-- Widget-only. A full-screen System Tool used to be registered alongside the
-- widget (see project history for why: FrSky's own lazy-loading example
-- registers both from one main.lua, and that pattern worked fine here too),
-- but it's been removed -- the widget is the only surface now, reached from
-- a model screen or its own configure()/menu() routes, never from the
-- System menu. Test mode (the bench-only fabricated-data driver) has also
-- been removed now that real capture is confirmed working end to end --
-- see project history if it's ever needed again for future development.
--
-- loadfile with a relative path resolves against this script's own folder
-- and is the pattern FrSky uses in its shipped scripts.

local core   = assert(loadfile("core.lua"))()
local draw   = assert(loadfile("draw.lua"))(core)
local config = assert(loadfile("config.lua"))(core, draw)
local screen = assert(loadfile("screen.lua"))(core, draw, config)

-- ---------------------------------------------------------------- widget

-- Sized to a full model screen page, the widget shows the full app surface.
-- Sized down into a cell alongside other widgets, it falls back to the
-- compact read-out, because soft keys and a log page cannot be made legible
-- in a quarter cell.
--
-- CONFIG key re-added 2026-09 at the pilot's request (reaching settings by
-- backing out of the widget was too much friction). An earlier attempt at
-- this same thing crashed on a widget-hosted model screen -- form-building
-- from a widget's own event handler, not from its dedicated configure()
-- callback, took wakeup() down with it, which silently stopped real
-- capture too. This needs a from-scratch re-verification on real hardware
-- (not just the simulator) before it ships: press CFG, confirm the form
-- opens and closes cleanly, then confirm a throw still gets recorded
-- afterward -- a capture outage here is invisible until someone notices
-- their throws stopped counting.
-- pcall-wrapped for the same reason wakeup/paint already are: if core.init()
-- throws here, this whole function used to abort before ever reaching the
-- `return`, which meant Ethos never got a proper widget instance back and
-- every later paint fell through to the bare draw.widget() branch with an
-- uninitialized core -- S.launches still {}, S.ready still false forever
-- (wakeup's very first line is "if not S.ready then return end", so nothing
-- downstream, including real capture, ever runs again for that boot). That
-- produces exactly a permanently-empty-looking widget regardless of what's
-- actually on disk. core.wakeup() below also retries init on every wakeup
-- until it succeeds, so a transient failure at boot can still self-heal.
local function widgetCreate()
  local ok, err = pcall(core.init)
  if not ok then core.setStatus("init error: " .. tostring(err)) end
  return {
    app = screen.new({
      -- UNDO removed 2026-09-09 -- MARK's own toggle already cancels a
      -- pending change; "remove the last throw/mark outright" moved into
      -- Review Log instead of staying a dedicated key. That freed FS4,
      -- given back the same day to CHANGES -- a manual way into the Setup
      -- Change Detected screen (see screen.lua's KEY_LABEL and activate())
      -- so a pilot can view/edit current setup deltas without an actual
      -- pending change to trigger it first. All four FS1-FS4 now map to a
      -- real key -- see screen.lua's KEY_SLOTS.
      keys       = { "CHANGE", "LOG", "CONFIG", "SETUP" },
      dialogs    = false,
      needsFocus = true,    -- keys are dimmed until the widget has focus
    }),
  }
end

-- Whether the cell is big enough for the full surface is screen.lua's own
-- judgement, so the widget asks rather than repeating the rule. The surface
-- falls back to the compact read-out by itself when it does not fit.
--
-- Both this and widgetWakeup below are pcall-wrapped: wakeup drives real
-- capture in the background on every screen (see the earlier discussion of
-- Ethos's widget scheduling), so an uncaught error there is the likely
-- cause of both a silent capture outage and a persistent system-wide error
-- icon. Catching it surfaces the actual message instead of guessing.
local function widgetPaint(widget)
  local w, h = lcd.getWindowSize()
  local ok, err = pcall(function()
    if widget and widget.app then
      widget.app.paint(w, h)
    else
      draw.widget(w, h)
    end
  end)
  if not ok then
    lcd.color(lcd.RGB(30, 10, 10))
    lcd.drawFilledRectangle(0, 0, w, h)
    lcd.color(lcd.RGB(240, 90, 70))
    lcd.drawText(4, 4, "Throw Trainer error (paint):")
    lcd.drawText(4, 22, tostring(err))
  end
end

local function widgetWakeup(widget)
  local ok, err = pcall(core.wakeup)
  if not ok then core.setStatus("wakeup error: " .. tostring(err)) end

  -- Hardware FS1-FS4, mirroring the on-screen key row 1:1. None of them
  -- act until THIS widget instance is confirmed to be the visible, focused
  -- one on screen (pilot's explicit request, 2026-09) -- otherwise bumping
  -- any of FS1-4 anywhere else in the radio would quietly act on Throw
  -- Trainer even when nobody's looking at it. Polled every wakeup
  -- regardless (core.pollFS does its own edge-detection so state doesn't go
  -- stale while unfocused), but only acted on here.
  local ok2, fs = pcall(core.pollFS)
  if ok2 and fs and widget and widget.app and lcd.hasFocus and lcd.hasFocus()
     and widget.app.fits(lcd.getWindowSize()) then
    local ok3, err3 = pcall(widget.app.pressKey, fs)
    if not ok3 then core.setStatus("FS error: " .. tostring(err3)) end
  end

  lcd.invalidate()
end

-- Input is accepted only when the widget holds focus, which the pilot grants
-- deliberately and Ethos releases again after ten idle seconds. That is what
-- makes an interactive widget safe: recording cannot be altered by a stray
-- touch, because an unfocused widget consumes nothing.
--
-- Swipes are passed straight through, so paging between model screens still
-- works while the widget is focused.
local function widgetEvent(widget, category, value, x, y)
  if not widget or not widget.app then return false end
  -- Only the full surface has keys to press; a compact cell stays a read-out.
  if not widget.app.fits(lcd.getWindowSize()) then return false end
  if lcd.isSwiping and lcd.isSwiping() then return false end
  if lcd.hasFocus and not lcd.hasFocus() then return false end

  -- pcall-wrapped: this is where the new, least-verified code lives (touch
  -- hit-testing, and CONFIG's form-building -- see the crash history noted
  -- above widgetCreate). An error here should not propagate and silently
  -- take wakeup()/real capture down with it.
  --
  -- category is threaded through (previously dropped), though it turned
  -- out not to be the fix: a tap was firing screen.lua's activate() twice
  -- (confirmed on X20RS, 2026-09 -- MARK went armed then immediately
  -- cancelled from one tap), and the theory was that category/value
  -- distinguish press from release the way KEY_xxx_FIRST/KEY_xxx_BREAK do
  -- for a physical key. A debug readout showed both calls came back with
  -- the same category and near-identical, non-enum-looking values -- an
  -- internal counter/timestamp, not a phase flag -- so screen.lua's fix
  -- instead just pairs up alternating touch calls and swallows every
  -- other one, regardless of value/category. category stays threaded
  -- through since it's harmless and may still be useful later.
  local ok, handled = pcall(widget.app.event, value, x, y, category)
  if not ok then
    core.setStatus("event error: " .. tostring(handled))
    return true
  end
  -- Any key we act on is also activity, so the focus timeout restarts and the
  -- widget does not drop focus mid-interaction.
  if handled and lcd.resetFocusTimeout then pcall(lcd.resetFocusTimeout) end
  return handled
end

-- The standard Ethos place for widget settings, reachable from the screen
-- editor whether or not any throws exist. screen.confirmErase is a module-
-- level function (not tied to any particular screen.new() instance), so
-- this shares exactly the same erase confirmation as the widget's own CFG
-- key (screen.lua's activate()) -- one implementation, not two that can
-- drift.
--
-- pcall-wrapped: this was the one remaining place in the app calling
-- something that can fail without any error protection. If config.build()
-- throws, Ethos was silently falling back to the normal widget view with no
-- indication anything went wrong -- tapping "Throw Trainer settings" and
-- landing right back on "waiting for a throw" with nothing else showing.
-- Now the failure is at least visible: the error goes to the status line,
-- which the next widget paint (including the empty-state screen) displays.
local function widgetConfigure(widget)
  local ok, err = pcall(function()
    core.init()
    config.build(screen.confirmErase)
  end)
  if not ok then
    core.setStatus("config error: " .. tostring(err))
    lcd.invalidate()
  end
end

-- A second route to settings, from the widget's own menu, for pilots who look
-- there first. Same form again.
local function widgetMenu(widget)
  return {
    { "Throw Trainer settings", function() widgetConfigure(widget) end },
  }
end

-- ---------------------------------------------------------------- register

local function init()
  system.registerWidget({
    key       = "thrwtrn",
    name      = "Throw Trainer",
    create    = widgetCreate,
    paint     = widgetPaint,
    wakeup    = widgetWakeup,
    event     = widgetEvent,
    configure = widgetConfigure,
    menu      = widgetMenu,
    title     = false,
  })
end

return { init = init }
