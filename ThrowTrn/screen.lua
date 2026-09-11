-- ThrowTrainer shared app surface: the main readout page, the log page, the
-- soft-key row and the key handling. The full-screen System Tool has been
-- removed (widget-only now) -- this still takes host options in case that
-- ever changes again.
--
--   dialogs -- true if the host may build forms/open modal dialogs. The
--              widget passes false (forms can't be opened from a
--              model-screen widget's own key row -- see main.lua for the
--              crash history behind CONFIG being the one exception, and
--              what still needs re-verifying on real hardware); Erase
--              still uses a real dialog via screen.confirmErase, reached
--              from CFG's Settings form, not from this key row directly.
--   keys    -- the soft-key row this host shows. The widget uses
--              CHANGE/LOG/CONFIG/SETUP (UNDO removed 2026-09-09 -- see
--              activate()'s own comment; SETUP added the same day, a
--              manual way into the Setup Change Detected screen -- see
--              KEY_LABEL's "CHANGES"), one key per physical FS switch.

local core, draw, config = ...
local screen = {}

local MAIN, SETUP, REVERT_CONFIRM, LOG, CONFIG, REVERTING = 1, 2, 3, 4, 5, 6

-- Always 4, matching FS1-FS4 -- independent of how many real keys V.keys
-- actually holds (all 4 slots filled as of 2.0). See paintMain's key row
-- for how a slot beyond #V.keys renders.
local KEY_SLOTS = 4

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

-- Ethos delivers a tap as two event() calls -- TOUCH_START then TOUCH_END,
-- category EVT_TOUCH -- plus TOUCH_MOVE/TOUCH_LONG for drags and holds
-- (confirmed with the Dial In probe on 26.1.2: 1 / 16640 / 16641 / 16642 /
-- 16643). Fallback literals cover firmware that predates the named globals.
local EVT_TOUCH_CAT = rawget(_G, "EVT_TOUCH") or 1
local TOUCH_END_VAL = rawget(_G, "TOUCH_END") or 16641

-- A caller that threads category through gets an exact answer; one that
-- doesn't falls back to the old "touch radio with real coordinates" guess.
local function isTouchEvent(category, x, y)
  if category ~= nil then return category == EVT_TOUCH_CAT end
  return isTouchCapable() and x ~= nil and y ~= nil and x > 0 and y > 0
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
    -- Two-step arm/confirm for Review Log's "remove" action (same proven
    -- pattern as the old hardware-UNDO flick, see core.lua's fireUndoFlick)
    -- -- only ever true while the row currently selected is the actual
    -- core.undoTarget(); moving the cursor or leaving Review Log disarms it.
    logRemoveArmed = false,
    -- Revert Confirm's own two-button focus (1 = Keep current, 2 =
    -- Revert) and which mark it's confirming -- see activateLogRow and
    -- activateRevertConfirm.
    revertConfirmFocus = 1,
    revertMark = nil,
    revertRects = {},
    -- Reverting screen's "done" state: once every value matches the
    -- revert is logged immediately, but the screen stays up showing the
    -- all-green result until RTN or the next throw (pilot, 2026-09-10:
    -- an instant jump to Main was startling). revertDoneSnap keeps the
    -- final progress table since core clears its own once finished.
    revertDone = false,
    revertDoneSnap = nil,
    -- Setup Change Detected's own explicit touch buttons -- see paintSetup
    -- and self.event's touch dispatch. acceptArmed is the two-step
    -- arm/confirm for ACCEPT (same pattern as Review Log's remove);
    -- self.paint disarms it whenever that screen isn't showing.
    setupRects = {},       -- CHANGES screen's own FS-aligned key row
    setupRudRect = nil,
    acceptArmed = false,
    -- Rotary focus on the CHANGES screen: 1 = ACCEPT, 2 = the rudder
    -- offset pill. rudEdit = the wheel is currently adjusting rudder
    -- offset (entered with ENTER on the pill, left with ENTER or RTN).
    -- Pilot's call (2026-09-10): an always-live wheel quietly edited a
    -- real VAR the moment the screen auto-opened; editing is now a
    -- deliberate step.
    setupFocus = 1,
    rudEdit = false,
    -- Tracks whether SOMETHING has actually been pending at any point
    -- since Setup Change Detected was last entered (auto or manual) --
    -- see self.paint. Lets a manual visit (CHANGES key, nothing pending
    -- yet) stay open indefinitely as a live readout, while still
    -- auto-closing back to Main once a real pending change that WAS seen
    -- resolves (confirmed by a throw, or a transient glitch clearing).
    setupSeenPending = false,
    inForm  = false,
    keys    = opts.keys,
    dialogs = opts.dialogs,
    -- Hit-test rectangles for the current key row, rebuilt every paint --
    -- keyed by the SAME index activate() already uses for rotary+enter, so
    -- a tap and a rotary-select land on exactly the same action.
    keyRects = {},
  }

  local self = { V = V }

  -- ------------------------------------------------------------ dialogs

  -- confirmUndo() (the UNDO key's own double-press/dialog confirmation)
  -- was removed here 2026-09-09 along with the UNDO key itself. Its job
  -- was two things: canceling a still-pending mark (core.change()'s own
  -- toggle already covers that, no key needed) and removing the last
  -- throw or confirmed mark outright (core.undo()/core.undoTarget(),
  -- both still intact in core.lua) -- that second part now lives in
  -- Review Log instead, see activateLogRow below (select the most recent
  -- row, press ENTER twice), using Review Log's own row-selection state
  -- rather than a bare V.undoArmed flag.

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
  -- UNDO removed 2.0 -- pressing MARK again while a mark is still pending
  -- already cancels it (core.change()'s existing toggle), which covers
  -- what pilots actually used UNDO for day to day. "Undo my last throw /
  -- confirmed mark" (the other thing the old UNDO key did) moves into
  -- Review Log -- select the most recent row there and remove it --
  -- rather than staying a dedicated top-row key, per the pilot's own
  -- call (2026-09-09). LOG is relabeled REVIEW LOG to match; the key
  -- identifier stays "LOG" internally, only the printed label changed.
  -- SETUP/"CHANGES" added 2026-09-09, pilot's own request: a manual way
  -- into the Setup Change Detected screen, not just the auto-switch --
  -- reuses the exact same paintSetup used for the auto-detected case, so
  -- it's simply an always-available live readout of every axis's current
  -- delta from baseline, with no separate "empty" rendering to build.
  local KEY_LABEL = { CHANGE = "MARK", LOG = "REVIEW LOG", CONFIG = "CFG", SETUP = "CHANGES" }

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
    elseif core.telemetryWarning() then
      lcd.color(p.bad)
      draw.textAt(pad, sy, "no telemetry", w - pad * 2)
    end
  end

  -- The FS-aligned key row, shared by Main and the CHANGES screen so the
  -- two can't drift apart (pilot, 2026-09-10: "align the top buttons into
  -- quarters like everywhere else and align them to FS buttons"). Always
  -- exactly KEY_SLOTS columns; items[i] = { label=, style="normal"|
  -- "armed"|"disabled", focused=bool } or nil for an empty "--" slot.
  --
  -- On a widget the row is only live once it has focus, so it's dimmed
  -- until then. The focused key gets a solid fill rather than a thin
  -- border -- a thin-vs-thick distinction was too subtle to track while
  -- turning the wheel; a disabled-but-focused key keeps the outline and
  -- just thickens it. Each key carries its physical tag ("FS1".."FS4")
  -- in its left edge, same idea as DLGPoker's "FS1 MIN" -- FONT_XS is
  -- pcall-guarded with FONT_S as fallback, like the FONT_L uses
  -- elsewhere. Returns the tap rects (only while live, on touch radios)
  -- and the row height.
  local function drawKeyRow(w, m, p, live, items)
    local line = m.th + 4
    local keyRowH = line + m.pad * 2
    local kw = math.floor(w / KEY_SLOTS)
    local rects = {}
    for i = 1, KEY_SLOTS do
      local kx = (i - 1) * kw
      local it = items[i]
      lcd.font(FONT_S)
      if not it then
        lcd.color(p.line)
        local tw = lcd.getTextSize("--")
        draw.textAt(kx + math.floor((kw - tw) / 2), m.pad, "--")
      else
        local bx, by, bw2, bh2 = kx + 2, 0, kw - 4, keyRowH - m.pad
        local focused  = live and it.focused
        local armed    = it.style == "armed"
        local disabled = it.style == "disabled"
        local labelColor
        if not live or disabled then
          lcd.color(p.line)
          lcd.drawRectangle(bx, by, bw2, bh2, focused and 2 or 1)
          labelColor = p.line
        elseif focused then
          lcd.color(armed and p.armed or p.text)
          lcd.drawFilledRectangle(bx, by, bw2, bh2)
          labelColor = p.bg
        else
          lcd.color(armed and p.armed or p.line)
          lcd.drawRectangle(bx, by, bw2, bh2, 1)
          labelColor = armed and p.armed or p.dim
        end

        if not pcall(lcd.font, FONT_XS) then pcall(lcd.font, FONT_S) end
        lcd.color((focused and not disabled) and p.bg or p.line)
        draw.textAt(bx + 4, by + 2, "FS" .. i)
        lcd.font(FONT_S)

        lcd.color(labelColor)
        local tw = lcd.getTextSize(it.label)
        draw.textAt(kx + math.floor((kw - tw) / 2), m.pad, it.label, kw - 6)

        -- Tap targets only exist once the row is actually live, matching
        -- the visual affordance -- a dimmed, unfocused key can't be woken
        -- up by a stray tap any more than it could by a stray rotary press.
        if live and isTouchCapable() then
          rects[i] = { x = kx, y = 0, w = kw, h = keyRowH }
        end
      end
    end
    return rects, keyRowH
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
    -- press. All 4 slots hold a real key as of 2.0 (MARK/REVIEW LOG/CFG/
    -- CHANGES, UNDO removed); see drawKeyRow for the rendering rules.
    local live = (not opts.needsFocus) or (lcd.hasFocus and lcd.hasFocus())
    local items = {}
    for i = 1, KEY_SLOTS do
      local id = V.keys[i]
      if id then
        local armedKey = (id == "CHANGE" and st.armed)
        items[i] = { label = armedKey and "CANCEL" or (KEY_LABEL[id] or id),
                     style = armedKey and "armed" or "normal",
                     focused = V.focus == i }
      end
    end
    local keyRowH
    V.keyRects, keyRowH = drawKeyRow(w, m, p, live, items)

    -- No title bar (model name + unit) any more -- removed 2026-09-10 at
    -- the pilot's request to give the strip the row back: the unit already
    -- sits next to the hero number and on every log row, and the model
    -- name is on the radio's own screen. Content starts right under the
    -- key row; the strip below absorbs the freed height.
    local y = keyRowH + pad

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
    -- and this row drop theirs: this row's throws are exactly the
    -- "previous set"/"current set" bars in the strip below (countable
    -- there), and Lifetime's count is churn that doesn't change what to
    -- do next.
    --
    -- Label rule (2.0, confirmed with the pilot): exactly one mark since
    -- baseline -> "Previous set" is accurate, it IS the one set right
    -- before this one. Two or more (including the st.fallback case, no
    -- mark yet at all) -> "Original baseline", since the comparison is
    -- however many marks back to the real baseline, not to "the set right
    -- before this one" -- calling that "previous" would be misleading
    -- once there's more than one mark to contend with.
    local baselineLabel = (st.marksSinceBaseline == 1) and "Previous set" or "Original baseline"
    local rows = {
      -- st.baselineAvg, not cmpBeforeAvg: the figure now genuinely reaches
      -- back to the baseline set (see core.baselineGroup), not just the
      -- label. The delta badge above keeps "vs previous set" on purpose.
      { label = baselineLabel,
        value = draw.fmt1(st.baselineAvg), color = p.text },
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

    -- The strip fills whatever's left below the two panels, down to the
    -- true bottom edge -- "align to the bottom," per the pilot (2026-09-09).
    -- A fixed status-line reservation used to sit here (before that, a
    -- 30%-of-h cap) -- both left a permanent dead gap at the bottom
    -- whenever nothing was actually being said, which is most of the
    -- time. Captions and the status line now share ONE line instead,
    -- mutually exclusive -- a real status (an error, a warning) always
    -- wins that line over the decorative current/previous-set captions,
    -- rather than the two needing separate reserved space.
    --
    -- Top clearance bumped from pad*2 to pad*3: the tallest bar's own
    -- value label sits almost exactly at `top` (see draw.strip), so pad*2
    -- was leaving it close enough to "avg .. best .." above to read as
    -- overlapping, not just close.
    local top = math.max(y, ry) + m.pad * 3
    local avail = h - top - pad
    local status = core.status()
    local hasStatus = status ~= nil or core.S.ioError ~= nil or core.telemetryWarning()
    local wantCaption = (not hasStatus) and avail > (m.th * 3)
    local capH = (wantCaption or hasStatus) and (m.th + 2) or 0
    local stripH = avail - capH
    if stripH < m.th * 2 then stripH = m.th * 2 end

    draw.strip(pad, top, w - pad * 2, stripH, core.strip(m.bars), m, p)
    if wantCaption then
      draw.stripCaptions(pad, top + stripH + 2, w - pad * 2, core.strip(m.bars), p)
    elseif hasStatus then
      drawStatus(pad, top + stripH + 2, w, p)
    end
  end

  -- ------------------------------------------------------------ setup change detected

  -- Camber and reflex are the SAME physical trim axis, not two separate
  -- ones -- see project memory: flaperons trimmed below center is Camber,
  -- above center is Reflex, and which name applies depends only on which
  -- side of center the trim currently sits on. Every screen that shows
  -- this axis picks the name from whichever number it's actually
  -- displaying alongside it (pilot's own clarification, 2026-09-09:
  -- positive reads as Reflex) rather than hardcoding "Camber" -- a real
  -- labeling bug an earlier version had throughout this file.
  local function camberLabel(v, titleCase)
    local reflex = v ~= nil and v > 0
    if titleCase then return reflex and "Reflex" or "Camber" end
    return reflex and "REFLEX" or "CAMBER"
  end

  -- Rounds to the nearest whole number for display -- every value this
  -- feature deals with (trim/VAR readings, their deltas) is already
  -- effectively a whole-number reading (see the approved mockup's own
  -- "+2"/"+4"-style figures), so this is purely a display nicety, not a
  -- correctness concern the way core.lua's own roundEq (revertProgress) is.
  local function iv(x)
    if not x then return "?" end
    return tostring(math.floor(x + 0.5))
  end

  -- Signed whole number, no unit and no trailing space -- draw.signed's
  -- "%d %s" form leaves a space before an empty unit, which showed up as
  -- "-20 ->+11" on the CHANGES pills.
  local function sv(x)
    if not x then return "?" end
    local n = math.floor(x + 0.5)
    return (n >= 0 and "+" or "") .. tostring(n)
  end

  -- Draws one row of pills starting at (x, y), each {text, color, bg} --
  -- shared by paintSetup and paintReverting so both screens' cards look
  -- like the same visual language. Returns the x position just past the
  -- last pill, in case a caller wants to keep drawing on the same line.
  local function drawPillRow(x, y, maxW, pills, p)
    local px = x
    local rects = {}
    for i = 1, #pills do
      local pill = pills[i]
      local bw, bh = draw.badge(px, y, pill.text, pill.color, pill.bg, maxW - (px - x))
      rects[i] = { x = px, y = y, w = bw, h = bh }
      px = px + bw + 6
    end
    return px, rects
  end

  -- Full-screen, auto-switched-to (see self.paint's consumeSetupJustDetected
  -- call) the instant a trim/VAR drifts from its power-on baseline -- see
  -- core.pollSetupChange -- or opened manually via the CHANGES key (see
  -- activate()). No dedicated "confirm" action -- confirmation is a real
  -- throw (core.recordLaunch -> core.confirmPendingSetup), not a button
  -- press -- see project memory project_throwtrainer_2.0_marks.md for why
  -- a throw is the trustworthy signal here rather than a switch/flight-
  -- mode heuristic. RTN backs out to MAIN (self.event's generic
  -- "V.screen ~= MAIN" handling covers it), and so does the explicit
  -- on-screen "< BACK" touch button (added 2026-09-09 after RTN alone
  -- left a pilot stuck here more than once -- see its own comment) --
  -- either way, a pending change keeps tracking in the background
  -- regardless of which screen is showing.
  local function paintSetup(w, h)
    local m = draw.metrics(w, h)
    local p = draw.palette()
    local pad = m.pad * 2
    local line = m.th + 4

    draw.clear(w, h, p)

    local fm = core.currentFlightMode()

    -- Named anyPending, not pending -- drawCard below has its own local
    -- `pending` parameter (a per-FM delta table), which would otherwise
    -- shadow this one inside its body.
    local anyPending = core.hasPendingSetup()
    local canAccept  = not anyPending and not core.isArmed()
    local canRevert  = #core.revertTargetsToBaseline() > 0

    -- Same focus rule as Main's key row: on a widget nothing here responds
    -- until the pilot has focused it (ENTER), and Ethos drops that focus
    -- after ~10 idle seconds -- longer than a throw takes. drawKeyRow dims
    -- the keys to show that, and the hint below says so (pilot,
    -- 2026-09-10: "back is inaccessible" was exactly this).
    local live = (not opts.needsFocus) or (lcd.hasFocus and lcd.hasFocus())
    local touch = isTouchCapable()

    -- The screen's own FS-aligned key row, same shape and rules as Main
    -- (pilot's call 2026-09-10): FS1 BACK, FS2 ACCEPT ("this is my new
    -- normal" -- moves the COMPARE baseline, changes nothing else; two-
    -- step, armed = "SURE?"; dimmed while a change is pending or a MARK is
    -- armed, which core refuses anyway), FS3 REVERT (undo everything since
    -- baseline, see core.revertTargetsToBaseline; dimmed when there's
    -- nothing to undo), FS4 RUD OFFSET (toggles the wheel between moving
    -- key focus and editing rudder offset -- editing is a deliberate step
    -- since an always-live wheel once edited the real VAR the moment this
    -- screen auto-opened). Rotary focus moves across these four exactly
    -- like Main's row; ENTER activates; physical FS1-FS4 map 1:1.
    local items = {
      { label = "BACK",   style = "normal", focused = V.setupFocus == 1 },
      { label = V.acceptArmed and "SURE?" or "ACCEPT",
        style = V.acceptArmed and "armed" or (canAccept and "normal" or "disabled"),
        focused = V.setupFocus == 2 },
      { label = "REVERT", style = canRevert and "normal" or "disabled",
        focused = V.setupFocus == 3 },
      { label = V.rudEdit and "EDITING" or "RUD OFFSET",
        style = V.rudEdit and "armed" or "normal", focused = V.setupFocus == 4 },
    }
    local keyRowH
    V.setupRects, keyRowH = drawKeyRow(w, m, p, live, items)
    local y = keyRowH + pad

    -- Header wording depends on whether something is ACTUALLY pending
    -- right now, not just on being on this screen -- the pilot's own
    -- correction (2026-09-09): opening this manually via the CHANGES key
    -- with nothing pending yet is a live readout, not a detection, and
    -- claiming "detected" when nothing has changed is simply wrong.
    lcd.font(FONT_M)
    lcd.color(p.text)
    draw.textAt(pad, y, anyPending and "SETUP CHANGE DETECTED" or "CURRENT SETUP", w - pad * 2)

    y = y + line + 2

    -- Second row: flight mode on the left (named per the pilot's explicit
    -- ask -- a bold card border alone wasn't considered enough), the
    -- controls hint right-aligned. The hint used to share row one with
    -- the title and collided with it at 640px (pilot screenshot,
    -- 2026-09-10) -- this row always exists now, so it has the room.
    -- Rudder offset is the only editable thing here (see self.event's
    -- rotary handling / core.nudgeRud) -- Camber/Elevator stay read-only,
    -- confirmed via CurveVarProbe/the official Ethos Lua docs.
    lcd.font(FONT_S)
    local hint
    if not live then hint = "press ENTER to focus widget"
    elseif V.rudEdit then hint = "wheel: adjust rud offset  ENTER: done"
    elseif V.acceptArmed then hint = "ENTER again to accept"
    else hint = "wheel: select key  ENTER: press" end
    local hw = lcd.getTextSize(hint)
    lcd.color((not live or V.rudEdit or V.acceptArmed) and p.armed or p.dim)
    draw.textAt(w - pad - hw, y, hint)
    if fm == core.FM_LAUNCH or fm == core.FM_ZOOM then
      lcd.color(p.dim)
      draw.textAt(pad, y, "Currently in " .. (fm == core.FM_LAUNCH and "LAUNCH" or "ZOOM"),
        w - pad * 2 - hw - m.pad)
    end
    y = y + line + m.pad

    local S = core.S
    local cardW = w - pad * 2

    -- Launch on top, Zoom below -- stacked vertically per the pilot's
    -- explicit revision (2026-09), not side by side. Both cards ALWAYS
    -- show, and each ALWAYS shows all of its possible pills (Camber, Elev,
    -- +Rudder on Launch only) -- matches the approved mockup exactly:
    -- accent/blue for a changed axis, dim/neutral "+0" for an unchanged
    -- one, never omitted. An earlier version of this screen hid unchanged
    -- pills and skipped an empty card entirely -- fixed 2026-09-09 after
    -- re-reading the mockup itself rather than a summarized memory of it.
    -- Each pill = confirmed drift since the COMPARE baseline for that axis
    -- (core.driftSinceBaseline), with any pending, unconfirmed delta shown
    -- as "confirmed -> total" in accent blue on top. Pilot's call
    -- (2026-09-10): after a confirmed change the old pending-only pills
    -- read "+0" everywhere, which said nothing about the setup this set
    -- is actually flying. Three states: pending (blue, from -> to),
    -- confirmed non-zero drift (plain text on the neutral wash), no drift
    -- at all (dim "+0").
    local function drawCard(label, fmConst, pending, drift, rud)
      local pills = {}
      local function item(baseLabel, confirmed, pend, isCamber)
        local total = confirmed + (pend or 0)
        local lbl = isCamber and camberLabel(total) or baseLabel
        -- Blue = changed since baseline (pending reads "from -> to",
        -- confirmed reads the plain number); grey = +0. The pilot's
        -- correction 2026-09-10: a confirmed change is still part of what
        -- this set is flying, so it stays coloured -- an earlier version
        -- greyed confirmed drift, which read as "not a change".
        if pend and confirmed ~= 0 then
          pills[#pills + 1] = { text = lbl .. " " .. sv(confirmed) .. " -> " .. sv(total),
                                color = p.accent, bg = p.accentBg }
        elseif pend then
          pills[#pills + 1] = { text = lbl .. " " .. sv(total), color = p.accent, bg = p.accentBg }
        elseif confirmed ~= 0 then
          pills[#pills + 1] = { text = lbl .. " " .. sv(confirmed), color = p.accent, bg = p.accentBg }
        else
          pills[#pills + 1] = { text = lbl .. " +0", color = p.dim, bg = p.dimBg }
        end
      end
      item("CAMBER", drift.camber, pending and pending.camber, true)
      item("ELEV", drift.elev, pending and pending.elev, false)
      if fmConst == core.FM_LAUNCH then item("RUDDER OFFSET", drift.rud, rud, false) end

      local cardH = line + m.th + m.pad * 3
      -- Bold (thicker) border on whichever card matches the flight mode
      -- the pilot is actually sitting in right now -- the pilot's own
      -- words: "a bold border and perhaps some text when you're making
      -- your adjustment while in launch."
      local active = (fm == fmConst)
      lcd.color(active and p.accent or p.line)
      lcd.drawRectangle(pad, y, cardW, cardH, active and 2 or 1)

      local cy = y + m.pad
      lcd.font(FONT_S)
      lcd.color(active and p.accent or p.dim)
      draw.textAt(pad + m.pad, cy, label, cardW - m.pad * 2)
      cy = cy + line

      local _, rects = drawPillRow(pad + m.pad, cy, cardW - m.pad, pills, p)

      -- The rudder pill (Launch card, third pill) is the one editable
      -- thing on this screen: a tap target, and a rotary focus ring --
      -- accent while merely selected, armed/amber while the wheel is
      -- actually editing it.
      if fmConst == core.FM_LAUNCH and rects[3] then
        local r = rects[3]
        V.setupRudRect = (touch and live) and r or nil
        if live and (V.rudEdit or V.setupFocus == 4) then
          lcd.color(V.rudEdit and p.armed or p.accent)
          lcd.drawRectangle(r.x - 2, r.y - 2, r.w + 4, r.h + 4, 2)
        end
      end

      y = y + cardH + m.pad
    end

    local drift, nSession = core.driftThisSession()
    drawCard("LAUNCH", core.FM_LAUNCH, S.pendingByFM[core.FM_LAUNCH],
      { camber = drift.launchCamber, elev = drift.launchElev, rud = drift.rud }, S.pendingRud)
    drawCard("ZOOM", core.FM_ZOOM, S.pendingByFM[core.FM_ZOOM],
      { camber = drift.zoomCamber, elev = drift.zoomElev }, nil)

    -- Plain, larger text rather than an icon -- the pilot's own correction
    -- (2026-09): an earlier revision's triangle glyph next to a lost bottom
    -- bar read as a location pin, not "throw to confirm." Bigger than the
    -- header above it, per the same note. Measured off FONT_L itself, not
    -- the FONT_S-derived `line` above -- reusing that would under-space two
    -- lines of a visibly larger font and risk them overlapping.
    y = y + m.pad * 2
    if not pcall(lcd.font, FONT_L) then pcall(lcd.font, FONT_M) end
    lcd.color(p.text)
    local _, bigH = lcd.getTextSize("Ay")
    if not bigH or bigH < line then bigH = line end
    local bigLine = bigH + 6
    if anyPending then
      draw.textAt(pad, y, "Throw glider to confirm", w - pad * 2)
      y = y + bigLine
      draw.textAt(pad, y, "and mark the change", w - pad * 2)
    else
      -- Nothing pending: say what the pills are relative to and how many
      -- confirmed marks that covers, so "+0 everywhere" after a reload
      -- reads as "nothing changed since power-on" rather than "nothing
      -- here".
      lcd.color(p.dim)
      if nSession == 0 then
        draw.textAt(pad, y, "No changes since baseline", w - pad * 2)
      else
        draw.textAt(pad, y, string.format("%d change%s since baseline", nSession,
          nSession == 1 and "" or "s"), w - pad * 2)
      end
    end

    -- Status line, bottom of the screen -- ACCEPT's own refusals and
    -- confirmations land here (core.acceptBaseline sets them), and this
    -- screen never rendered core.status() before, so they'd have been
    -- invisible. Same slot Review Log's footer uses.
    local status = core.status()
    if status then
      lcd.font(FONT_S)
      lcd.color(p.armed)
      draw.textAt(pad, h - pad - line, status, w - pad * 2)
    end
  end

  -- ------------------------------------------------------------ revert confirm

  -- Reached from a "setup" mark row in Review Log that ISN'T the current
  -- undo target (see activateLogRow). Deliberately a full custom screen,
  -- not a real Ethos form.openDialog -- the app's own history (see
  -- main.lua's widgetCreate comment) is that building UI from a widget's
  -- own event handler outside its dedicated configure() callback has
  -- crashed before, and confirmErase's dialog is the one place that's
  -- proven safe, reached from inside an already-open Settings form, not
  -- directly from a key press the way this would be. A same-shaped
  -- custom screen (rotary/tap between two on-screen buttons, exactly like
  -- every other screen here) gets the same two-step safety property with
  -- zero new untested API surface.
  local function paintRevertConfirm(w, h)
    local m = draw.metrics(w, h)
    local p = draw.palette()
    local pad = m.pad * 2
    local line = m.th + 4

    draw.clear(w, h, p)

    local y = pad
    local mark = V.revertMark
    local toBaseline = mark and mark.toBaseline
    lcd.font(FONT_M)
    lcd.color(p.text)
    draw.textAt(pad, y, toBaseline and "Revert to baseline?" or "Revert to this mark?", w - pad * 2)
    y = y + line + m.pad

    local targets = {}
    if toBaseline then targets = core.revertTargetsToBaseline()
    elseif mark then targets = core.revertTargetsFor(mark) end
    lcd.font(FONT_S)
    lcd.color(p.text)
    if #targets == 0 then
      draw.textAt(pad, y, "Nothing to revert -- already matches this mark.", w - pad * 2)
      y = y + line
    else
      for i = 1, #targets do
        local t = targets[i]
        local lbl = (t.axis == "camber") and camberLabel(t.target, true) or t.label
        draw.textAt(pad, y,
          lbl .. " back to " .. iv(t.target) .. " (from " .. iv(t.current) .. ")",
          w - pad * 2)
        y = y + line
      end
    end

    y = y + m.pad
    lcd.color(p.dim)
    draw.textAt(pad, y, "Starts a new baseline here -- later marks stay logged.", w - pad * 2)

    -- Two on-screen buttons, rotary+ENTER (V.revertConfirmFocus, see
    -- self.event) or tap -- same convention as the main key row: filled
    -- when focused, outlined otherwise. "Revert" in bad/red -- it's the
    -- destructive-ish choice (Erase's own dialog uses the same red-on-
    -- right convention).
    local btnH = line + m.pad * 2
    local by = h - btnH
    lcd.color(p.line)
    lcd.drawLine(pad, by, w - pad, by)
    local bw = math.floor((w - pad * 2) / 2)
    V.revertRects = {}
    local labels = { "Keep current", "Revert" }
    for i = 1, 2 do
      local bx = pad + (i - 1) * bw
      local focused = V.revertConfirmFocus == i
      local accent = (i == 2) and p.bad or p.text
      local dim    = (i == 2) and p.bad or p.line
      if focused then
        lcd.color(accent)
        lcd.drawFilledRectangle(bx + 2, by + m.pad, bw - 4, btnH - m.pad * 2)
        lcd.color(p.bg)
      else
        lcd.color(dim)
        lcd.drawRectangle(bx + 2, by + m.pad, bw - 4, btnH - m.pad * 2, 1)
        lcd.color((i == 2) and p.bad or p.dim)
      end
      local tw = lcd.getTextSize(labels[i])
      draw.textAt(bx + math.floor((bw - tw) / 2), by + m.pad * 2, labels[i])
      if isTouchCapable() then
        V.revertRects[i] = { x = bx, y = by, w = bw, h = btnH }
      end
    end
  end

  local function activateRevertConfirm()
    local mark = V.revertMark
    if V.revertConfirmFocus == 2 and mark then
      core.beginRevert(mark)
      V.revertDone, V.revertDoneSnap = false, nil
      V.screen = REVERTING
    else
      -- "Keep current" goes back to wherever this was opened from.
      V.screen = (mark and mark.toBaseline) and SETUP or LOG
    end
    V.revertMark = nil
    lcd.invalidate()
  end

  -- ACCEPT on the CHANGES screen -- tap or ENTER. Two-step arm/confirm
  -- (see V.acceptArmed); core.acceptBaseline does the real work and its
  -- own refusals (pending change, armed MARK) surface on that screen's
  -- status line, so a dimmed button that's tapped anyway still explains
  -- itself. Drops back to Main on success -- the accepted setup is now
  -- just "normal", nothing left to look at here.
  local function activateAccept()
    if core.hasPendingSetup() or core.isArmed() then
      V.acceptArmed = false
      core.acceptBaseline()          -- refuses, and sets the status saying why
    elseif V.acceptArmed then
      V.acceptArmed = false
      if core.acceptBaseline() then V.screen = MAIN end
    else
      V.acceptArmed = true
    end
    lcd.invalidate()
  end

  -- The CHANGES screen's key row, by slot -- physical FS1-FS4, a tap, or
  -- rotary focus + ENTER all land here (see paintSetup for what each is).
  local function activateSetupKey(i)
    V.setupFocus = i
    if i == 1 then                          -- BACK
      V.acceptArmed, V.rudEdit = false, false
      V.screen = MAIN
    elseif i == 2 then                      -- ACCEPT (two-step, see activateAccept)
      V.rudEdit = false
      activateAccept()
    elseif i == 3 then                      -- REVERT to baseline
      V.acceptArmed, V.rudEdit = false, false
      if #core.revertTargetsToBaseline() == 0 then
        core.setStatus("nothing to revert")
      else
        V.revertMark = { grp = core.sessionBaselineGrp(), ts = os.time(), toBaseline = true }
        V.revertConfirmFocus = 1
        V.screen = REVERT_CONFIRM
      end
    elseif i == 4 then                      -- RUD OFFSET edit toggle
      V.acceptArmed = false
      V.rudEdit = not V.rudEdit
    end
    lcd.invalidate()
  end

  -- ------------------------------------------------------------ reverting to mark

  -- Live progress screen while a revert is in flight. Rudder offset (the
  -- one writable axis, see core.beginRevert) already reads matched the
  -- instant this screen appears; Camber/Elevator stay red until the
  -- pilot's own trim taps close the gap, since core.lua confirmed those
  -- are read-only from Lua. Auto-closes back to Main the moment
  -- core.revertAllMatched() goes true -- see self.paint, which checks that
  -- BEFORE calling this, not inside it.
  local function paintReverting(w, h)
    local m = draw.metrics(w, h)
    local p = draw.palette()
    local pad = m.pad * 2
    local line = m.th + 4

    draw.clear(w, h, p)

    -- Once done, core has already cleared its own revert state (see
    -- self.paint) -- paint from the snapshot taken at that moment instead.
    local done = V.revertDone
    local progress = done and V.revertDoneSnap or core.revertProgress()
    if not progress then
      -- Reached with no revert actually in flight (shouldn't normally
      -- happen) -- fall back rather than paint a blank screen.
      paintMain(w, h)
      return
    end

    local fm = core.currentFlightMode()
    local y = pad
    local rt = done and progress or core.S.revertTarget
    local what = (rt and rt.toBaseline) and "BASELINE" or "MARK"

    lcd.font(FONT_M)
    lcd.color(done and p.good or p.armed)
    draw.textAt(pad, y, done and ("REVERT COMPLETE -- " .. what) or ("REVERTING TO " .. what), w - pad * 2)
    y = y + line
    lcd.font(FONT_S)
    lcd.color(p.dim)
    draw.textAt(pad, y, (rt and rt.ts) and os.date("%H:%M:%S", rt.ts) or "", w - pad * 2)
    y = y + line + m.pad

    local function findAxis(fmConst, axis)
      for i = 1, #progress.axes do
        local a = progress.axes[i]
        if a.fm == fmConst and a.axis == axis then return a end
      end
      return nil
    end

    -- Three-way pill state per axis: tracked-by-this-revert (red until it
    -- matches its fixed target, green once it does); untracked but
    -- currently drifting anyway (red, target implicitly "back to no
    -- change" -- the pilot's own words: "if you accidentally make that
    -- change in Zoom mode, it has to take the same difference treatment");
    -- or genuinely untouched (dim "+0", same neutral convention as Setup
    -- Change Detected).
    local function pillFor(fmConst, axis, label)
      local tracked = findAxis(fmConst, axis)
      if tracked then
        local lbl = (axis == "camber") and camberLabel(tracked.current) or label
        local txt = lbl .. " " .. iv(tracked.current) .. "->" .. iv(tracked.target)
        if tracked.matched then
          return { text = txt, color = p.good, bg = p.goodBg }, true, false
        end
        return { text = txt, color = p.bad, bg = p.badBg }, false, false
      end
      local pending = core.S.pendingByFM[fmConst]
      local delta = pending and pending[axis]
      if delta then
        local lbl = (axis == "camber") and camberLabel(delta) or label
        return { text = lbl .. " 0->" .. iv(delta), color = p.bad, bg = p.badBg }, true, true
      end
      local lbl = (axis == "camber") and "CAMBER" or label
      return { text = lbl .. " +0", color = p.dim, bg = p.dimBg }, true, false
    end

    local rudPill
    if progress.rud then
      local r = progress.rud
      rudPill = { text = r.label .. " " .. iv(r.current) .. "->" .. iv(r.target),
                  color = r.matched and p.good or p.bad, bg = r.matched and p.goodBg or p.badBg }
    else
      rudPill = { text = "RUDDER OFFSET +0", color = p.dim, bg = p.dimBg }
    end

    local cardW = w - pad * 2
    local labelW = 68

    local function drawCard(label, fmConst, extraPill)
      local active = (fm == fmConst)
      local camberPill, camberOk, camberWarn = pillFor(fmConst, "camber", "CAMBER")
      local elevPill, elevOk, elevWarn = pillFor(fmConst, "elev", "ELEV")
      local warn = camberWarn or elevWarn
      local pills = { camberPill, elevPill }
      if extraPill then pills[#pills + 1] = extraPill end

      local cardH = line + m.th + m.pad * 3 + (warn and (m.th + 2) or 0)
      lcd.color(active and p.armed or p.line)
      lcd.drawRectangle(pad, y, cardW, cardH, active and 2 or 1)

      local cy = y + m.pad
      lcd.font(FONT_S)
      lcd.color(active and p.armed or p.dim)
      draw.textAt(pad + m.pad, cy, label, labelW)
      if active then
        draw.textAt(pad + m.pad, cy + m.th, "ACTIVE NOW", labelW)
      end

      drawPillRow(pad + m.pad + labelW, cy, cardW - m.pad - labelW, pills, p)

      if warn then
        lcd.color(p.bad)
        draw.textAt(pad + m.pad + labelW, cy + line,
          "not part of this mark -- flagged, it moved while " .. label .. " is active",
          cardW - m.pad - labelW)
      end

      y = y + cardH + m.pad
    end

    drawCard("LAUNCH", core.FM_LAUNCH, rudPill)
    drawCard("ZOOM", core.FM_ZOOM, nil)

    -- Names the specific axis and direction still outstanding, rather
    -- than a generic "keep going" -- mirrors the approved mockup's own
    -- "Move Camber trim down 2 to finish reverting". Whichever axis is
    -- found first (Launch checked before Zoom) when more than one is
    -- still outstanding.
    local instruction
    for i = 1, #progress.axes do
      local a = progress.axes[i]
      if not a.matched and a.current ~= nil then
        local diff = a.target - a.current
        local dir = (diff >= 0) and "up" or "down"
        local lbl = (a.axis == "camber") and camberLabel(a.current, true) or a.label
        instruction = string.format("Move %s trim %s %d to finish reverting",
          lbl, dir, math.abs(math.floor(diff + 0.5)))
        break
      end
    end

    y = y + m.pad
    if not pcall(lcd.font, FONT_M) then pcall(lcd.font, FONT_S) end
    if done then
      lcd.color(p.good)
      draw.textAt(pad, y, "All values match. Throw, or press RTN, to return.", w - pad * 2)
    else
      lcd.color(p.armed)
      draw.textAt(pad, y, instruction or "Adjusting...", w - pad * 2)
    end
  end

  -- ------------------------------------------------------------ log page

  -- Merged, newest-first: every throw AND every boundary event (manual
  -- "change" mark, auto "setup" mark, "revert", or a plain power-cycle
  -- "baseline" divider) -- the pilot's own ask for 2.0 ("merge existing
  -- plain LOG page with new MARK rows"), and the approved mockup shows
  -- power-cycle boundaries too ("-- BASELINE -- power cycle, ..."), so
  -- those are included here as well (an earlier version of this function
  -- hid them entirely -- fixed 2026-09-09 after re-reading the mockup
  -- itself). Grouped by set rather than interleaved by raw append order: a
  -- boundary event's own .grp field is exactly the set NUMBER it opened,
  -- so walking sets newest-to-oldest and, for each one, showing its own
  -- boundary (if any) followed by its own throws (newest-first)
  -- reproduces the true chronology without needing a reliable cross-array
  -- timestamp/seq to merge by -- which doesn't exist for rows reloaded
  -- from disk (launches.csv never persisted seq, only ever set in-memory
  -- by core.recordLaunch for the current session -- see core.lua's
  -- loadLog). Each throw also carries its own ordinal (`ord`, counting
  -- from the oldest throw on record) so a mark row can cross-reference
  -- "confirmed by throw #N", matching the mockup.
  --
  -- Both paintLog (rendering) and activateLogRow (the row action) call
  -- this, so the row a pilot sees selected and the row that action acts on
  -- can never disagree about what's at a given index.
  local function buildLogRows()
    local out = {}
    local cur = core.currentGroup()
    local L, E = core.S.launches, core.S.events

    local byGrp = {}
    for i = #L, 1, -1 do                     -- newest-first within each set
      local r = L[i]
      byGrp[r.grp] = byGrp[r.grp] or {}
      byGrp[r.grp][#byGrp[r.grp] + 1] = { rec = r, ord = i }
    end

    local markForGrp, revertForGrp, acceptForGrp, baselineForGrp = {}, {}, {}, {}
    for i = 1, #E do
      local e = E[i]
      if e.type == "change" or e.type == "setup" then markForGrp[e.grp] = e
      elseif e.type == "revert" then revertForGrp[e.grp] = e
      elseif e.type == "accept" then acceptForGrp[e.grp] = e
      elseif e.type == "power" then baselineForGrp[e.grp] = e
      end
    end

    for g = cur, 1, -1 do
      local throws = byGrp[g]
      -- The confirming throw is the OLDEST one in the set it opened --
      -- core.recordLaunch calls core.confirmPendingSetup before grouping
      -- ITSELF into the new group, so that throw is always the first
      -- (lowest-ord, last in this newest-first list) member of the set.
      local confirmedByOrd = throws and throws[#throws].ord or nil

      local mark = markForGrp[g]
      if mark then
        out[#out + 1] = { kind = "mark", e = mark, grp = g, confirmedByOrd = confirmedByOrd }
      end
      local revert = revertForGrp[g]
      if revert then
        out[#out + 1] = { kind = "revert", e = revert, grp = g,
                           revertedMark = markForGrp[revert.revertToGrp] }
      end
      local accept = acceptForGrp[g]
      if accept then out[#out + 1] = { kind = "accept", e = accept, grp = g } end
      local baseline = baselineForGrp[g]
      if baseline then out[#out + 1] = { kind = "baseline", e = baseline, grp = g } end

      if throws then
        for i = 1, #throws do
          out[#out + 1] = { kind = "throw", rec = throws[i].rec, ord = throws[i].ord, grp = g }
        end
      end
    end
    return out
  end

  -- Full words, not the packed abbreviations an earlier version used --
  -- mark rows get two lines now (see paintLog), so there's room, and this
  -- matches the mockup's own "Camber +2, Rudder offset +1" style. Most
  -- marks only ever touch one or two of the five possible fields (see
  -- core.lua's addEvent), so this only prints what's really there. A
  -- mode qualifier is only added when BOTH Launch and Zoom contributed to
  -- the same mark -- the common case (one mode) stays as clean as the
  -- mockup's own examples. Manual "change" marks carry no deltas at all;
  -- the caller's own "MARK" label already says enough, so this returns "".
  local function markSummaryText(e)
    if e.type ~= "setup" then return "" end
    local function d(v)
      if not v then return nil end
      local n = math.floor(v + 0.5)
      return (n >= 0 and "+" or "") .. tostring(n)
    end
    local bothModes = (e.launchCamber or e.launchElev) and (e.zoomCamber or e.zoomElev)
    local parts = {}
    local function add(label, v, mode)
      if not v then return end
      parts[#parts + 1] = label .. " " .. d(v) .. (bothModes and (" (" .. mode .. ")") or "")
    end
    add(camberLabel(e.launchCamber, true), e.launchCamber, "Launch")
    add("Elevator", e.launchElev, "Launch")
    add("Rudder offset", e.rud, "Launch")
    add(camberLabel(e.zoomCamber, true), e.zoomCamber, "Zoom")
    add("Elevator", e.zoomElev, "Zoom")
    return table.concat(parts, ", ")
  end

  -- Throw and baseline rows are one line tall; mark and revert rows are
  -- two (title + delta on line one, timestamp/caption on line two) --
  -- matches the mockup's own taller mark rows. Scrolling below accounts
  -- for this directly rather than assuming a uniform row height.
  local function logRowHeight(row, line)
    if row.kind == "mark" or row.kind == "revert" or row.kind == "accept" then
      return line * 2
    end
    return line
  end

  local function paintLog(w, h)
    local m = draw.metrics(w, h)
    local p = draw.palette()
    local pad = m.pad * 2
    local line = m.th + 2
    local headerH = line

    draw.clear(w, h, p)
    lcd.font(FONT_S)
    lcd.color(p.dim)
    draw.textAt(pad, pad, "REVIEW LOG - newest first", w - pad * 2)

    local entries = buildLogRows()
    local total = #entries
    if total == 0 then
      lcd.color(p.dim)
      draw.textAt(pad, pad + headerH * 2, "no throws recorded", w - pad * 2)
      return
    end

    if V.logSel < 1 then V.logSel = 1 end
    if V.logSel > total then V.logSel = total end
    if V.logTop < 1 then V.logTop = 1 end
    if V.logTop > V.logSel then V.logTop = V.logSel end

    -- Persistent footer, one line, reserved below the row area -- shows
    -- what ENTER does right now. This is the pilot-reported fix
    -- (2026-09-09): core.setStatus("press again to remove") was already
    -- being called correctly when a removal armed, but paintLog never
    -- actually rendered core.status() anywhere, so arming only showed as
    -- an unexplained red row with no indication of what a second press
    -- would do. Matches the mockup's own persistent bottom hint line.
    local footerH = line + 6

    -- Bottom-anchored scroll under variable row heights: keep pulling
    -- logTop forward (dropping older rows off the top) while the selected
    -- row still doesn't fit in the space below the header.
    local avail = h - (pad + headerH) - m.pad - footerH
    local function spanHeight(from, to)
      local s = 0
      for i = from, to do s = s + logRowHeight(entries[i], line) end
      return s
    end
    while V.logTop < V.logSel and spanHeight(V.logTop, V.logSel) > avail do
      V.logTop = V.logTop + 1
    end

    -- Shared column grid for throw rows: ordinal, height, status, time, set.
    local colN, colA, colB, colC, colD = 0.00, 0.07, 0.20, 0.50, 0.74
    local curGrp, prevGrp = core.currentGroup(), core.beforeGroup()

    local y = pad + headerH
    local i = V.logTop
    while i <= total do
      local row = entries[i]
      local rh = logRowHeight(row, line)
      if y + rh > h - pad - footerH then break end

      -- Theme-aware selection wash (2026-09-09, pilot-reported: the old
      -- lcd.GREY(60) fill was a hardcoded dark grey that ignored the
      -- active theme -- fine on Night, but read as a near-black block on
      -- Day, swallowing the text drawn on top of it instead of
      -- highlighting it). p.dimBg is the same neutral wash already used
      -- for every other "highlighted but not urgent" surface in this app
      -- (e.g. an unchanged pill on Setup Change Detected), so this now
      -- actually adapts with the theme like everything else on screen.
      if i == V.logSel then
        lcd.color(V.logRemoveArmed and p.badBg or p.dimBg)
        lcd.drawFilledRectangle(pad, y, w - pad * 2, rh)
      end

      if row.kind == "throw" then
        local rec = row.rec
        lcd.color(p.dim)
        draw.textAt(pad + math.floor(w * colN) + 2, y, tostring(row.ord) .. ".", w * (colA - colN))
        lcd.color(rec.st == "ok" and p.text or (rec.st == "low" and p.bad or p.high))
        draw.textAt(pad + math.floor(w * colA), y, draw.fmt(rec.h, rec.u), w * (colB - colA))
        if rec.st ~= "ok" then
          draw.textAt(pad + math.floor(w * colB), y,
            rec.st == "low" and "low" or "high", w * (colC - colB))
        end
        lcd.color(p.dim)
        draw.textAt(pad + math.floor(w * colC), y, os.date("%H:%M:%S", rec.ts), w * (colD - colC))
        -- Same vocabulary as the strip captions and the mockup's own log
        -- ("current set" / "previous set"); only older sets keep a number.
        local setLabel = "set " .. tostring(rec.grp)
        if rec.grp == curGrp then setLabel = "current set"
        elseif rec.grp == prevGrp then setLabel = "previous set" end
        draw.textAt(pad + math.floor(w * colD), y, setLabel, w * (1 - colD))

      elseif row.kind == "baseline" then
        lcd.color(p.dim)
        draw.textAt(pad + 4, y,
          "-- BASELINE -- power cycle, " .. os.date("%H:%M:%S", row.e.ts), w - pad * 2)

      else -- "mark" or "revert" -- same two-line shape, orange accent bar
        lcd.color(p.marker)
        lcd.drawFilledRectangle(pad, y, 3, rh)
        local tx = pad + 8

        local title, caption
        if row.kind == "mark" then
          local e = row.e
          local summary = markSummaryText(e)
          title = "MARK" .. (summary ~= "" and ("  " .. summary) or "")
          local kindDesc = (e.type == "setup") and "auto-detected" or "manual"
          if row.confirmedByOrd then
            caption = os.date("%H:%M:%S", e.ts) .. " -- " .. kindDesc ..
              ", confirmed by throw #" .. row.confirmedByOrd
          else
            caption = os.date("%H:%M:%S", e.ts) .. " -- " .. kindDesc .. ", armed"
          end
        elseif row.kind == "revert" then
          title = "REVERTED"
          local backTo = row.revertedMark
            and ("mark from " .. os.date("%H:%M:%S", row.revertedMark.ts)) or "baseline"
          caption = os.date("%H:%M:%S", row.e.ts) .. " -- back to " .. backTo
        else -- "accept"
          title = "BASELINE ACCEPTED"
          caption = os.date("%H:%M:%S", row.e.ts) .. " -- current setup is the new baseline"
        end

        -- Height delta vs the set right before this boundary, same
        -- up/down glyph + signed convention as the main screen's delta
        -- badge (see draw.lua's deltaInfo) -- "--" until this boundary's
        -- own set has at least one throw to average. Measured BEFORE the
        -- title is drawn (2026-09-09, pilot-reported truncation: a mark
        -- touching both Launch and Zoom produces a long summary like
        -- "Camber +41 (Launch), Elevator -12 (Launch), Camber +7 (Zoom)"
        -- that a flat 90px reservation for this figure was cutting off
        -- mid-word) so the title gets back whatever room the actual
        -- (usually much narrower) delta text isn't using.
        lcd.font(FONT_S)
        local after, before = core.groupAvg(row.grp), core.groupAvg(row.grp - 1)
        local dtxt, dcolor = "--", p.dim
        if after and before then
          local dv = after - before
          local glyph = (dv >= 0) and "\226\150\178" or "\226\150\188"
          dtxt = glyph .. " " .. draw.signed1(dv)
          dcolor = (dv >= 0) and p.good or p.bad
        end
        local dw = lcd.getTextSize(dtxt)

        lcd.color(p.text)
        draw.textAt(tx, y, title, w - pad - tx - dw - 10)

        lcd.color(dcolor)
        draw.textAt(w - pad - dw, y, dtxt)

        lcd.color(p.dim)
        draw.textAt(tx, y + line, caption, w - pad - tx)
      end

      y = y + rh
      i = i + 1
    end

    local footerY = h - pad - line
    lcd.color(p.line)
    lcd.drawLine(pad, footerY - 4, w - pad, footerY - 4)
    lcd.font(FONT_S)
    if V.logRemoveArmed then
      lcd.color(p.bad)
      draw.textAt(pad, footerY, "Press ENTER again to remove this entry", w - pad * 2)
    else
      local status = core.status()
      if status then
        lcd.color(p.armed)
        draw.textAt(pad, footerY, status, w - pad * 2)
      else
        lcd.color(p.dim)
        draw.textAt(pad, footerY, "ENTER: remove latest, or revert an older auto mark", w - pad * 2)
      end
    end
  end

  -- ------------------------------------------------------------ actions

  local function activate(i)
    local key = V.keys[i]
    if key == "CHANGE" then
      core.change()
    elseif key == "LOG" then
      V.screen = LOG
      V.logSel, V.logTop = 1, 1
      V.logRemoveArmed = false
    elseif key == "CONFIG" then
      V.screen = CONFIG
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
    elseif key == "SETUP" then
      V.screen = SETUP
      -- Seed from whatever's actually true right now: if something's
      -- already pending the moment this opens, treat it the same as the
      -- auto-triggered path (will auto-close once it resolves); if
      -- nothing's pending, this is a pure live-readout visit and should
      -- stay open on its own until the pilot backs out manually.
      V.setupSeenPending = core.hasPendingSetup()
      V.setupFocus = 1
      V.rudEdit = false
    end
    lcd.invalidate()
  end

  -- Review Log's row action -- what ENTER does depends on which row is
  -- selected:
  --   1. The current core.undoTarget() (the single most-recently-appended
  --      session item, whatever kind) -- two-step arm/confirm remove, same
  --      as before (2026-09-09, pilot's own call via AskUserQuestion: this
  --      capability moved here from the old dedicated UNDO key). Mirrors
  --      the old hardware-UNDO flick pattern -- see core.lua's
  --      fireUndoFlick -- so a destructive action still needs two
  --      deliberate presses with no dialog.
  --   2. An older auto-detected "setup" mark -- opens Revert Confirm (see
  --      below). Not offered on a manual "change" mark: those carry no
  --      trim deltas at all, so there is nothing to revert.
  --   3. Anything else (an older manual mark, a "revert" row, a throw
  --      that isn't the latest) -- no action, just a status explaining why.
  local function activateLogRow()
    local row = buildLogRows()[V.logSel]
    if not row then return end
    local t = core.undoTarget()
    local isTarget = t and (
      (row.kind == "throw" and t.kind == "launch" and row.rec == t.rec) or
      ((row.kind == "mark" or row.kind == "accept") and t.kind == "change" and row.e == t.rec))
    if isTarget then
      if V.logRemoveArmed then
        V.logRemoveArmed = false
        core.undo()
      else
        V.logRemoveArmed = true
        core.setStatus("press again to remove")
      end
      lcd.invalidate()
      return
    end

    V.logRemoveArmed = false
    if row.kind == "mark" and row.e.type == "setup" then
      V.revertMark = row.e
      V.revertConfirmFocus = 1
      V.screen = REVERT_CONFIRM
      lcd.invalidate()
      return
    end

    core.setStatus("select the newest entry to remove, or an auto mark to revert")
    lcd.invalidate()
  end

  -- Public entry point for hardware FS1-FS4 -- see main.lua's widgetWakeup,
  -- which only calls this once it's already confirmed this instance is the
  -- visible, focused one. Mirrors what a tap or a rotary+ENTER on the same
  -- key index would do.
  function self.pressKey(i)
    if V.inForm then return end
    if V.screen == MAIN and V.keys[i] then
      V.focus = i
      activate(i)
    elseif V.screen == SETUP then
      activateSetupKey(i)
    end
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
    -- Act on a tap's release only. Every other touch phase (start, move,
    -- long-hold) is consumed here, ahead of the V.inForm/V.screen gates, so
    -- a key whose action changes screens never sees the same tap's other
    -- phases land on whatever is now underneath it.
    if isTouchEvent(category, x, y) and value ~= TOUCH_END_VAL then
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

    -- Touch: hit-test against the rectangles paintMain (or paintRevertConfirm)
    -- recorded this same frame.
    local touch = isTouchEvent(category, x, y)
    if V.screen == MAIN and touch then
      for i, r in pairs(V.keyRects) do
        if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
          V.focus = i
          activate(i)
          return true
        end
      end
    end
    if V.screen == REVERT_CONFIRM and touch then
      for i, r in pairs(V.revertRects) do
        if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
          V.revertConfirmFocus = i
          activateRevertConfirm()
          return true
        end
      end
    end
    if V.screen == SETUP and touch then
      for i, r in pairs(V.setupRects) do
        if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
          activateSetupKey(i)
          return true
        end
      end
      local r = V.setupRudRect
      if r and x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
        activateSetupKey(4)                -- tapping the pill = RUD OFFSET key
        return true
      end
    end

    if value == KEY_ROTARY_RIGHT or value == KEY_ROTARY_LEFT then
      local d = step(value, x)
      if V.screen == MAIN then
        -- Wrap modularly, so a fast spin overshooting by 2 lands on the
        -- second key rather than collapsing onto the first.
        V.focus = ((V.focus - 1 + d) % #V.keys) + 1
      elseif V.screen == LOG then
        V.logSel = V.logSel + d
        -- Moving the cursor is a deliberate change of mind about which row
        -- is selected, so any still-armed remove no longer applies to it.
        V.logRemoveArmed = false
      elseif V.screen == REVERT_CONFIRM then
        V.revertConfirmFocus = ((V.revertConfirmFocus - 1 + d) % 2) + 1
      elseif V.screen == SETUP then
        -- Rudder offset is the one axis this app can actually edit
        -- directly -- confirmed read-write via CurveVarProbe, unlike
        -- Camber/Elevator (trims, read-only from Lua). Pilot's own
        -- request (2026-09-09): nudge it straight from here instead of
        -- needing the radio's separate VARs config page. This is a real
        -- live edit, not a revert -- core.pollSetupChange picks up the
        -- resulting difference from baseline exactly like an edit made
        -- from the VARs screen would, and it still needs a throw to
        -- confirm it into an official mark, same as always. No focus
        -- Editing is a deliberate step now (pilot's call 2026-09-10 --
        -- an always-live wheel quietly edited a real VAR the moment this
        -- screen auto-opened): the wheel only nudges while V.rudEdit is
        -- on; otherwise it just moves focus between ACCEPT and the pill.
        V.acceptArmed = false
        if V.rudEdit then
          core.nudgeRud(d)
        else
          V.setupFocus = ((V.setupFocus - 1 + d) % KEY_SLOTS) + 1
        end
      end
      lcd.invalidate()
      return true
    end

    -- Act on BREAK, not FIRST: BREAK also fires after a long press, and there
    -- is no separate long-press constant to distinguish them on FIRST.
    if value == KEY_ENTER_BREAK then
      if V.screen == MAIN then
        activate(V.focus)
      elseif V.screen == LOG then
        activateLogRow()
      elseif V.screen == REVERT_CONFIRM then
        activateRevertConfirm()
      elseif V.screen == SETUP then
        if V.rudEdit then
          V.rudEdit = false                 -- done editing
          lcd.invalidate()
        else
          activateSetupKey(V.setupFocus)
        end
      end
      return true
    end

    if value == KEY_RTN_FIRST or value == KEY_EXIT_FIRST or value == 99 then
      -- Mid-edit on the CHANGES screen, RTN just ends the edit.
      if V.screen == SETUP and V.rudEdit then
        V.rudEdit = false
        lcd.invalidate()
        return true
      end
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
    -- Drain the edge flag EVERY frame, regardless of which screen is
    -- showing -- not just while V.screen == MAIN. Confirmed real bug
    -- 2026-09-09 (X20RS touch test, pilot report: "no way to get back to
    -- the main screen from the change screen, period"): the flag was only
    -- ever being consumed inside the `V.screen == MAIN and ...` check
    -- below, via short-circuit evaluation -- so it never got drained while
    -- sitting on SETUP, and manual entry via the CHANGES key (activate())
    -- never consumed it either. If the change was still genuinely pending
    -- (hasn't been confirmed by a throw yet), backing out via RTN landed
    -- on MAIN for exactly one frame before THIS check saw the still-true,
    -- never-drained flag and snapped straight back to SETUP -- a real
    -- trap with no way out short of a confirming throw. Draining it
    -- unconditionally here, then only ACTING on the drained value while
    -- V.screen == MAIN, means the flag can never linger across a screen
    -- switch to cause a later false re-trigger.
    local justDetected = core.consumeSetupJustDetected()
    -- ACCEPT's arm, the rudder edit and its focus only mean anything
    -- while the CHANGES screen is showing.
    if V.screen ~= SETUP then
      V.acceptArmed = false
      V.rudEdit = false
      V.setupFocus = 1
    end
    -- Any recorded throw returns to Main, whatever screen was up and
    -- whether or not it confirmed anything -- pilot's call 2026-09-10:
    -- "every time you throw, the behavior should stay the same." A
    -- revert in flight keeps its own completion logic; a form is left
    -- alone.
    if core.consumeLaunchRecorded() and (V.screen ~= REVERTING or V.revertDone) then
      V.screen = MAIN
    end
    if V.screen ~= REVERTING then
      V.revertDone, V.revertDoneSnap = false, nil
    end
    -- Edge-triggered auto-switch: only fires the one paint after a change
    -- newly became pending, and only grabs the screen away from MAIN --
    -- deliberately backing out to LOG or CFG while a change is still
    -- unconfirmed must not get yanked back here on the very next frame.
    --
    -- The extra core.hasPendingSetup() check (2026-09-09, separately
    -- pilot-reported bug: Setup Change Detected showing up with every
    -- pill at "+0" right after a completely ordinary launch, no trim ever
    -- touched) guards against the edge having gone stale by the time this
    -- actually runs: S.setupJustDetected latches true the instant
    -- something briefly reads as pending (plausibly a one-tick unsettled
    -- trim/flight-mode reading right at a mode transition -- this
    -- codebase already has one documented precedent for that class of
    -- glitch, see identityStillCurrent's own comment on model.id()), but
    -- nothing clears the latch if the underlying delta falls back to zero
    -- again before the flag gets consumed here. Requiring the change to
    -- still be genuinely pending RIGHT NOW, not just "was at some point,"
    -- is a strictly correct tightening regardless of the exact root cause
    -- -- this screen should never show up with nothing to actually confirm.
    if V.screen == MAIN and justDetected and core.hasPendingSetup() then
      V.screen = SETUP
      V.setupSeenPending = true
    end
    -- Same bug's other half, generalized for the CHANGES key's manual
    -- entry too (2026-09-09, pilot's own request -- see activate()):
    -- auto-close back to Main once a change that WAS actually seen
    -- pending resolves (the glitch clears, or the normal/desired case, a
    -- throw just confirmed it into a real mark) -- but a manual visit
    -- that opened with nothing pending yet is a deliberate live readout
    -- and must NOT get yanked shut on its very first paint. See
    -- V.setupSeenPending's own comment.
    if V.screen == SETUP then
      if core.hasPendingSetup() then
        V.setupSeenPending = true
      elseif V.setupSeenPending then
        V.screen = MAIN
        V.setupSeenPending = false
      end
    end
    -- Checked BEFORE dispatching to paintReverting, not inside it: once
    -- every trim axis matches its fixed target, the revert is done and the
    -- screen closes itself back to Main, per the approved mockup ("Once
    -- everything reads green the screen closes itself back to Main").
    if V.screen == REVERTING and not V.revertDone and core.revertAllMatched() then
      -- Log it the moment it's true, but STAY here in the green "done"
      -- state -- RTN or the next throw returns to Main (pilot's call
      -- 2026-10: the old instant jump to Main was startling, and gave no
      -- confirmation the revert had actually landed).
      local snap = core.revertProgress()
      snap.ts = core.S.revertTarget and core.S.revertTarget.ts
      snap.toBaseline = core.S.revertTarget and core.S.revertTarget.toBaseline
      core.finishRevert()
      V.revertDoneSnap = snap
      V.revertDone = true
    end

    if V.screen == LOG and fits(w, h) then
      paintLog(w, h)
    elseif V.screen == SETUP and fits(w, h) then
      paintSetup(w, h)
    elseif V.screen == REVERT_CONFIRM and fits(w, h) then
      paintRevertConfirm(w, h)
    elseif V.screen == REVERTING and fits(w, h) then
      paintReverting(w, h)
    else
      paintMain(w, h)
    end
  end

  function self.reset()
    V.screen = MAIN
    V.focus = 1
    V.inForm = false
    V.logRemoveArmed = false
    V.revertMark = nil
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
