-- ThrowTrainer rendering. Shared by the widget cell and the tool page so a
-- bar strip looks identical in both. Every dimension derives from the measured
-- text height, never from raw pixels: an X14 renders FONT_S at 20px while the
-- physically larger X20RS renders it at 18px, so pixel thresholds misclassify.

local core = ...
local draw = {}

-- ---------------------------------------------------------------- geometry

-- Measure rather than assume. th is the unit everything else is expressed in.
function draw.metrics(w, h)
  lcd.font(FONT_S)
  local _, th = lcd.getTextSize("8")
  if not th or th < 8 then th = 18 end

  local tier = "C"
  if h >= 8 * th and w >= 14 * th then tier = "A"
  elseif h >= 6 * th and w >= 9 * th then tier = "B" end

  local bars = math.floor((w - 16) / (1.7 * th))
  if bars < 5 then bars = 5 end
  if bars > 12 then bars = 12 end

  return { w = w, h = h, th = th, tier = tier, bars = bars,
           cw = th * 0.5, pad = math.floor(th * 0.3) }
end

-- ---------------------------------------------------------------- colours

local function C(r, g, b) return lcd.RGB(r, g, b) end

-- Two self-contained palettes rather than leaning on Ethos's own theme
-- colour: this app clears and owns its whole canvas (see draw.clear /
-- draw.clearAll), so background and text have to be chosen as a matched
-- pair -- pulling text from the OS theme while we pick our own background
-- risks a light-on-light or dark-on-dark mismatch if the two disagree.
local function darkPalette()
  return {
    bg      = C(14, 14, 16),      -- full-canvas clear colour, see draw.clear
    text    = C(235, 235, 235),
    dim     = lcd.GREY(140),
    line    = lcd.GREY(90),
    before  = lcd.GREY(150),
    after   = C(80, 170, 240),
    accent  = C(80, 170, 240),
    old     = lcd.GREY(80),
    bad     = C(220, 90, 70),
    badBg   = C(50, 24, 22),
    high    = C(230, 170, 60),
    good    = C(90, 200, 120),
    goodBg  = C(20, 46, 30),
    dimBg   = C(42, 42, 42),
    armed   = C(240, 190, 60),
    marker  = C(230, 130, 40),   -- "change" boundary + its caption
    accentBg = C(30, 44, 61),    -- changed-axis pill fill, Setup Change
                                  -- Detected / Reverting screens (2.0) --
                                  -- matches the approved mockup's own
                                  -- --accent-soft dark value (#1E2C3D).
  }
end

local function lightPalette()
  return {
    bg      = C(246, 246, 248),
    text    = C(20, 20, 22),
    dim     = C(110, 110, 116),
    line    = C(195, 195, 200),
    before  = C(140, 140, 146),
    after   = C(20, 105, 190),
    accent  = C(20, 105, 190),
    old     = C(205, 205, 210),
    bad     = C(190, 55, 45),
    badBg   = C(250, 222, 218),
    high    = C(175, 115, 15),
    good    = C(35, 140, 75),
    goodBg  = C(215, 240, 222),
    dimBg   = C(222, 222, 226),
    armed   = C(195, 135, 15),
    marker  = C(195, 95, 25),
    accentBg = C(229, 238, 248),  -- matches the approved mockup's own
                                    -- --accent-soft light value (#E5EEF8).
  }
end

-- Defaults to Day (theme 2 / lightPalette) -- most launches happen outdoors
-- in daylight, where a dark canvas is hard to read. Night (theme 1) is a
-- deliberate opt-in from Config -> Display.
local function palette()
  local theme = (core.S.cfg and core.S.cfg.theme) or 2
  if theme == 1 then return darkPalette() end
  return lightPalette()
end

draw.palette = palette

-- Wipes the whole draw region. The tool's canvas persists between frames
-- rather than being cleared by the framework, so any frame that draws less
-- than the previous one (most visibly: switching to a form, which stops our
-- own drawing entirely) leaves stale pixels behind. Cheap enough to call on
-- every paint rather than trying to track when it's actually needed.
function draw.clear(w, h, p)
  lcd.color(p.bg)
  lcd.drawFilledRectangle(0, 0, w, h)
end

-- Same wipe, but callable from an event handler rather than a paint
-- callback. lcd.getWindowSize() has only ever been established as safe from
-- inside paint() in this codebase -- calling it from activate() or an RTN
-- handler risks it returning nil, and drawFilledRectangle(0,0,nil,nil) would
-- throw. An oversized rectangle sidesteps needing the size at all; drawing
-- clips to the visible canvas the same way overflowing text does.
function draw.clearAll(p)
  lcd.color(p.bg)
  lcd.drawFilledRectangle(0, 0, 4000, 4000)
end

-- ---------------------------------------------------------------- text

-- Ethos clips overflowing text at the cell edge with no wrap and no ellipsis,
-- so anything that might not fit has to be measured and shortened first.
function draw.fitText(text, maxW)
  local tw = lcd.getTextSize(text)
  if tw <= maxW then return text end
  for i = #text - 1, 1, -1 do
    local cut = string.sub(text, 1, i)
    if lcd.getTextSize(cut) <= maxW then return cut end
  end
  return ""
end

function draw.textAt(x, y, text, maxW, flags)
  if maxW then text = draw.fitText(text, maxW) end
  lcd.drawText(x, y, text, flags)
end

local function fmt(v, unit)
  if not v then return "--" end
  return string.format("%d %s", math.floor(v + 0.5), unit or "")
end

draw.fmt = fmt

local function signed(v, unit)
  if not v then return "--" end
  local n = math.floor(v + 0.5)
  local s = (n >= 0) and "+" or "-"
  return string.format("%s%d %s", s, math.abs(n), unit or "")
end

draw.signed = signed

-- One-decimal variants for averages and deltas -- raw heights are already
-- whole numbers (recordLaunch floors them), but a mean of several throws
-- carries a fraction worth keeping, e.g. "94.5" rather than a rounded "94"
-- that hides two different sets landing on the same integer.
local function fmt1(v, unit)
  if not v then return "--" end
  return string.format("%.1f%s", v, unit and (" " .. unit) or "")
end

draw.fmt1 = fmt1

local function signed1(v, unit)
  if not v then return "--" end
  local s = (v >= 0) and "+" or "-"
  return string.format("%s%.1f%s", s, math.abs(v), unit and (" " .. unit) or "")
end

draw.signed1 = signed1

-- ---------------------------------------------------------------- badge

-- A small filled-and-bordered pill used for the delta readout. Flat corners
-- rather than rounded -- there's no rounded-rect primitive to rely on, and a
-- sharp-cornered tinted rectangle reads the same way at this size.
function draw.badge(x, y, text, color, bg, maxW)
  local tw, th = lcd.getTextSize(text)
  if maxW and tw > maxW - 10 then
    text = draw.fitText(text, maxW - 10)
    tw = lcd.getTextSize(text)
  end
  local bw, bh = tw + 10, th + 6
  lcd.color(bg)
  lcd.drawFilledRectangle(x, y, bw, bh)
  lcd.color(color)
  lcd.drawRectangle(x, y, bw, bh, 1)
  draw.textAt(x + 5, y + 3, text, tw + 2)
  return bw, bh
end

-- ARMED while the next throw is still pending, "--" with nothing to compare
-- yet, otherwise a coloured triangle and the signed difference, greyed when
-- under n=3. Shared text/colour logic so a size query and the actual draw
-- can never disagree.
local function deltaInfo(st, suffix, p)
  if st.armed then
    return "ARMED", p.armed, p.dimBg
  end
  if not st.delta then
    return "--", p.dim, p.dimBg
  end
  local up = st.delta >= 0
  local glyph = up and "\226\150\178" or "\226\150\188"   -- U+25B2 / U+25BC
  local txt = glyph .. " " .. signed1(st.delta)
  if not st.confident then txt = txt .. " (n<3)" end
  if suffix then txt = txt .. " " .. suffix end
  local color = st.confident and (up and p.good or p.bad) or p.dim
  local bg    = st.confident and (up and p.goodBg or p.badBg) or p.dimBg
  return txt, color, bg
end

-- The up/down delta pill shared by every screen and tier.
function draw.deltaBadge(x, y, st, suffix, maxW, p)
  local txt, color, bg = deltaInfo(st, suffix, p)
  return draw.badge(x, y, txt, color, bg, maxW)
end

-- Size without drawing, so a caller can right-align the pill before it knows
-- x -- avoids drawing off-canvas just to measure, which is not guaranteed
-- safe on every target.
function draw.deltaBadgeSize(st, suffix, p)
  local txt = deltaInfo(st, suffix, p)
  local tw, th = lcd.getTextSize(txt)
  return tw + 10, th + 6
end

-- ---------------------------------------------------------------- hero number

-- The big reading plus its unit in a smaller trailing font, e.g. "97" large
-- next to "ft" small -- rather than one string in one size. FONT_XL is used
-- far more here than in earlier revisions (previously touched in exactly one
-- place); unlike FONT_S it has never been explicitly confirmed against every
-- target in this project's hardware log, so a bad font constant degrades to
-- a smaller known-good size instead of throwing.
function draw.hero(x, y, value, unit, color, bigFont, smallFont)
  if not pcall(lcd.font, bigFont) then pcall(lcd.font, FONT_L) end
  local txt = value and tostring(math.floor(value + 0.5)) or "--"
  local bw, bh = lcd.getTextSize(txt)
  lcd.color(color)
  draw.textAt(x, y, txt)
  if not pcall(lcd.font, smallFont) then pcall(lcd.font, FONT_S) end
  local _, sh = lcd.getTextSize(unit or "")
  draw.textAt(x + bw + 4, y + (bh - sh), unit or "")
  lcd.font(FONT_S)
  return bw + 4 + lcd.getTextSize(unit or ""), bh
end

-- ---------------------------------------------------------------- bar strip

-- Boundary x-positions within a strip drawn at (x, w) -- shared by draw.strip
-- itself and by callers that want to caption a boundary underneath it,
-- so the slot arithmetic exists in exactly one place.
function draw.stripMarks(x, w, bars)
  if #bars == 0 then return {} end
  local slot = w / #bars
  local raw = core.stripBoundaries(bars)
  local out = {}
  for i = 1, #raw do
    out[#out + 1] = { x = math.floor(x + (raw[i].at - 1) * slot), kind = raw[i].kind }
  end
  return out
end

-- Absolute heights, not deltas: the pilot reads real numbers off this. The
-- axis therefore starts at zero and the top is the tallest bar shown. The
-- top of the area is reserved as a label margin so each bar's own printed
-- value has somewhere to sit without the tallest bar's label going off the
-- top edge -- the margin is sized to exactly fit the peak bar's label.
function draw.strip(x, y, w, h, bars, m, p)
  if #bars == 0 then
    lcd.color(p.dim)
    draw.textAt(x, y + math.floor(h / 2) - m.th, "no throws yet", w)
    return
  end

  local peak = 0
  for i = 1, #bars do
    if bars[i].h > peak then peak = bars[i].h end
  end
  if peak <= 0 then peak = 1 end

  -- Only reserve room for labels when there's genuinely enough height to
  -- both show them and still have a legible bar underneath -- otherwise
  -- skip them rather than crush the bars to nothing.
  local showLabels = h >= m.th * 3
  local labelH = showLabels and (m.th + 1) or 0
  local plotY  = y + labelH
  local plotH  = h - labelH
  if plotH < 4 then plotH = 4 end

  local slot = w / #bars
  local bw = math.floor(slot * 0.62)
  if bw < 3 then bw = 3 end

  for i = 1, #bars do
    local b = bars[i]
    local bh = math.floor(b.h / peak * plotH)
    if bh < 4 then bh = 4 end     -- a 1-2px sliver reads as nothing at all
    local bx = math.floor(x + (i - 1) * slot + (slot - bw) / 2)
    local by = plotY + plotH - bh

    local col = p.old
    if b.st == "low" then col = p.bad
    elseif b.st == "high" then col = p.high
    elseif b.band == "after" then col = p.after
    elseif b.band == "before" then col = p.before end

    lcd.color(col)
    lcd.drawFilledRectangle(bx, by, bw, bh)

    if showLabels then
      lcd.font(FONT_S)
      lcd.color(p.text)
      local label = tostring(b.h)
      local tw = lcd.getTextSize(label)
      draw.textAt(bx + math.floor((bw - tw) / 2), by - labelH, label, slot)
    end
  end

  -- Boundary rules sit in the gap between bars, not on top of one. Both
  -- kinds use the same hardware-verified DOTTED pen (no DASHED constant has
  -- been confirmed on this target) and are told apart by colour instead: a
  -- change is the one worth a second look, a power-on is routine background
  -- noise.
  local marks = draw.stripMarks(x, w, bars)
  for i = 1, #marks do
    lcd.color(marks[i].kind == "power" and p.line or p.marker)
    lcd.pen(DOTTED)
    lcd.drawLine(marks[i].x, y, marks[i].x, y + h)
    lcd.pen(SOLID)
  end
end

-- "current set" / "previous set" under the bars that belong to each, for
-- views with room to spare. Only sets are numbered internally (bars[].band
-- is exactly the "after"/"before"/"old" tag core.strip() already computes),
-- so there's nothing to count here -- just find each band's contiguous
-- pixel span and centre its label in it.
--
-- A label only appears when it actually fits under its own span; a single
-- narrow bar isn't captioned rather than truncated or overflowing into its
-- neighbour's space. "old" bars (neither the current nor previous set) are
-- never labelled.
function draw.stripCaptions(x, y, w, bars, p)
  if #bars == 0 then return end
  local slot = w / #bars

  local function spanOf(band)
    local first, last
    for i = 1, #bars do
      if bars[i].band == band then
        first = first or i
        last = i
      end
    end
    if not first then return nil end
    return x + (first - 1) * slot, last - first + 1
  end

  local function caption(band, text, color)
    local spanX, count = spanOf(band)
    if not spanX then return end
    local spanW = count * slot
    local tw = lcd.getTextSize(text)
    if tw > spanW - 4 then return end   -- wouldn't fit -- omit, don't cram
    lcd.color(color)
    draw.textAt(spanX + math.floor((spanW - tw) / 2), y, text)
  end

  caption("after", "current set", p.after)
  caption("before", "previous set", p.before)
end

-- ---------------------------------------------------------------- unsupported size

-- Throw Trainer is only offered at two sizes -- Full and the wide Half slot
-- (see screen.lua's layoutKind) -- both deliberately chosen so the numbers
-- stay legible and the bar strip has room to be read at a glance. A smaller
-- placement (a quarter cell, a narrow column) used to get a shrunk-down
-- three-tier readout instead of this message, but that was always a
-- compromise nobody could quite trust in the field, and the pilot decided
-- it's not worth keeping now that Half covers the "still fairly compact"
-- case properly. This has no keys and isn't interactive -- there's nowhere
-- to put a key row this small anyway.
function draw.widget(w, h)
  local p = palette()
  lcd.color(p.bg)
  lcd.drawFilledRectangle(0, 0, w, h)

  lcd.font(FONT_S)
  local _, th = lcd.getTextSize("8")
  if not th or th < 8 then th = 18 end
  local pad = math.floor(th * 0.3)

  lcd.color(p.dim)
  draw.textAt(pad, pad, "Throw Trainer", w - pad * 2)
  if h >= th * 2 then
    draw.textAt(pad, pad + th + 2, "needs Full or Half width", w - pad * 2)
  end
end

return draw
