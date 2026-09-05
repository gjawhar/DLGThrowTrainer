-- ThrowTrainer 1.3.0 -- DLG throw height trainer for FrSky Ethos.
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
-- REVERTED: a CONFIG key was tried here briefly, wired to the same
-- form-building code Config uses via widgetConfigure below. This project's
-- own prior history had already flagged that a widget on a model screen may
-- not be able to build form pages, and testing confirmed it: the resulting
-- crash took the widget's wakeup down with it, which also happens to be
-- what drives real capture (core.wakeup), so throws silently stopped being
-- recorded at the same time a global script-error indicator appeared. Do
-- not re-add "CONFIG" here without a from-scratch verification that
-- form.clear() / config.build() actually work from a widget's own event
-- handler, not just from its dedicated configure() callback (which is what's
-- still used below, and is the only route confirmed safe).
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
      keys       = { "CHANGE", "UNDO", "LOG" },
      dialogs    = false,   -- UNDO still double-presses rather than a dialog
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

  local handled = widget.app.event(value, x)
  -- Any key we act on is also activity, so the focus timeout restarts and the
  -- widget does not drop focus mid-interaction.
  if handled and lcd.resetFocusTimeout then pcall(lcd.resetFocusTimeout) end
  return handled
end

-- The standard Ethos place for widget settings, reachable from the screen
-- editor whether or not any throws exist. screen.confirmErase is a module-
-- level function (not tied to any particular screen.new() instance), so
-- this shares exactly the same erase confirmation as the widget's own CFG
-- route would if it existed -- one implementation, not two that can drift.
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
