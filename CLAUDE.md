# Throw Trainer — DLG launch-height training assistant for FrSky Ethos

A Lua widget for FrSky Ethos radios (built/tested on an X14, Ethos 26.1.1)
that reads launch height from Mike Shellim's "DLG for Ethos" template and
helps a DLG pilot tell whether a setup change (camber, trim, ballast, rudder
offset) actually helped, or whether the difference is just throw-to-throw
noise. Full background/rationale lives in the original requirements spec
(not included here, but ask if you need the "why" behind something — most
of it is also captured inline as code comments).

**Status:** working end-to-end on hardware as of this handoff. Real capture,
persistence across reboots, and settings all confirmed functional after a
long debugging chain (see "Hard-won Ethos-Lua facts" below — this is the
single most important section in this file).

## Deployment

Package layout Ethos expects, unzipped onto the transmitter's SD card:

```
scripts/ThrowTrn/
├── main.lua      -- registers the widget, wires all modules together
├── core.lua      -- state, persistence, capture, grouping, statistics
├── draw.lua      -- all rendering (shared by every screen size/tier)
├── screen.lua    -- the interactive app surface (main page, log page, keys)
├── config.lua    -- the Settings form
└── Files/        -- runtime data lives here (launches.csv, events.csv,
                     gliders.csv, config.csv) -- ships with a .gitkeep,
                     Lua can't create missing parent directories
```

Widget key is `thrwtrn` (max 7 chars, Ethos constraint). To test a change:
zip the `scripts/` folder, copy to the transmitter's SD card (or internal
storage) under `/scripts/`, reboot, and the widget should appear in the
widget picker on any model screen as "Throw Trainer".

There is **no System Tool anymore** — it was deliberately removed. The
widget is the only surface. Settings are reached by long-pressing the
widget on a model screen (native Ethos "Configure" option, or the widget's
own "Throw Trainer settings" menu entry — both call the same code).

## Architecture

- **`core.lua`** — the only place that touches files, computes statistics,
  or knows what a "group"/"set" is. Everything else asks core for numbers
  and draws them. `core.recordLaunch(height, unit, ts)` is the single
  injection seam every capture path goes through.
- **`draw.lua`** — all `lcd.*` drawing calls live here. Three widget
  "tiers" (A/B/C) for different cell sizes, all sharing one bar-strip
  renderer. Also owns the dark/light palette.
- **`screen.lua`** — the interactive layer: soft-key row, focus/rotary
  handling, the log page, dialogs. Shared between what used to be two
  hosts (widget + tool); now just the widget, but the option-based
  `screen.new(opts)` API was kept since it doesn't cost anything and the
  separation is still useful.
- **`config.lua`** — builds the Settings form with the real Ethos `form.*`
  API (so switch/source pickers are the native radio ones, not hand-rolled).
- **`main.lua`** — thin glue: loads the other modules, registers the
  widget with Ethos, wraps every entry point in `pcall` (see below for why
  this matters more than it looks like it should).

## Hard-won Ethos-Lua facts (do not regress these)

These cost a very long debugging session each. If you ever touch file I/O
or find yourself reaching for a "standard Lua" idiom, check this list first.

1. **`file:lines()` is not callable.** Ethos's file handles do not support
   the standard `for line in f:lines() do` idiom at all — it throws `method
   'lines' is not callable`. Read files with `f:read(N)` in a loop instead
   (see `readAll()` in `core.lua`).

2. **`file:read()` does not accept string format specifiers.** Neither the
   legacy Lua 5.1 style (`f:read("*a")`) nor the modern Lua 5.2+ style
   (`f:read("a")`) works — both throw `bad argument #1 to 'read'`. (Lua's
   method-call error numbering blames the visible argument, not `self`, so
   that really is complaining about the format string, not the file
   handle.) The only form that works is the **numeric byte-count** form:
   `f:read(2048)` in a loop, concatenating chunks until a short read
   signals EOF. This is what `core.lua`'s `readAll()` does now. If file
   reading ever breaks again, suspect this first.

3. **`system.registerWidget` and `system.registerSystemTool` can both be
   called from one `main.lua`.** An early draft of this project concluded
   otherwise; that conclusion was wrong. The actual cause of that earlier
   failure was a missing icon mask for the tool, not a one-registration
   limit. (Moot now since the System Tool was removed, but worth knowing if
   a second surface is ever added back.)

4. **A widget on a model screen cannot reliably build its own form pages
   from its own event handler.** It *can* build a form via the dedicated
   `configure()` callback (that's what `widgetConfigure` in `main.lua`
   does, and it works). But wiring a "CONFIG" soft-key into the widget's
   own custom key-handling loop and calling `form.clear()`/`config.build()`
   from there was tried once and it broke things badly: it crashed the
   widget's `wakeup()`, which also happens to be what drives real capture,
   so throws silently stopped being recorded — at the same time a
   persistent, system-wide (visible on every screen) error triangle
   appeared. **Do not re-add a CONFIG key to the widget's own soft-key row**
   without a from-scratch hardware test of that specific path.

5. **Logic switches read ±100, not 0/1.** A "false" switch reads `-100`,
   not `0`. Always test `> 0`, never truthiness.

6. **`source:age()` returns `-1`**, not `nil`, when telemetry has never
   been received. Freshness checks must treat negative age as invalid in
   addition to a large positive age.

7. **Ethos's global "script error" warning icon is sticky.** It can outlive
   the script that caused it — surviving even a full uninstall and reboot
   on some firmware versions. It's cleared from the radio's own **Info
   screen → Reset** (or, on older Ethos without that button, by reselecting
   the model that first showed it, switching that screen to full-screen,
   assigning any widget to it, and rebooting). If you see this icon and
   can't explain it from current code, check whether it's actually stale
   from a *previous* crash before assuming the current build is broken.

8. **Widgets keep running (`wakeup()`) in the background** even when a
   *different* screen of the same model is the one currently displayed —
   this is corroborated by community reports, not officially documented,
   so treat it as "probably true, confirm before relying on it for
   anything safety-critical." It does **not** survive switching to a
   *different model* — the widget only runs while its own model is loaded.
   A full-screen System Tool (if one is ever added back) almost certainly
   does *not* keep running once you navigate away from it.

9. **`model.id()` can return a not-yet-settled value in the first moment
   after power-on**, before the RF module finishes initializing. Identity
   binding (`bindIdentity()` in `core.lua`) is therefore re-checked on
   every `wakeup()`, not trusted forever from a single read at boot — see
   `identityStillCurrent()`. This turned out not to be the actual cause of
   the "data disappears after reboot" saga (that was the `:lines()`/`read()`
   bug above), but it's a real, separate, cheap-to-keep defense and was
   left in.

## Key design decisions worth preserving

- **One injection seam.** `core.recordLaunch()` is the only way a throw
  gets into the system. (A test-mode feature that injected fabricated
  throws through this same seam was removed once real capture was
  confirmed working — see git history / this doc's "Removed features"
  section if you need to resurrect it for bench testing.)
- **pcall everywhere at the boundary.** `core.init()`, `core.wakeup()`,
  `widgetPaint`, and `widgetConfigure` are all pcall-wrapped, and failures
  surface as visible text (red error screen for paint failures, a status
  line message for init/wakeup/config failures — including on the *empty*
  state screen, which is exactly where an uncaught `core.init()` failure
  used to land looking identical to "fresh install, no data yet"). This
  was added reactively after several rounds of silent failures were very
  hard to diagnose from symptoms alone. **Keep this pattern for any new
  entry point.**
- **`core.wakeup()` retries `core.init()` every cycle until it succeeds**,
  rather than permanently giving up after one failed attempt at widget
  creation. A transient boot-time failure can self-heal instead of
  disabling the app for the rest of the session.
- **Groups/"sets" vs. the delta comparison are deliberately separate
  fields** (`afterN`/`afterAvg` = true count/average for the current set,
  vs. `cmpAfterN`/`cmpAfterAvg` = whatever the delta badge is actually
  comparing, which falls back to a recent-vs-previous window split when no
  "MARK" has ever been pressed). These were briefly the same field and it
  was a real bug: with no MARK pressed, 5 real throws in "Set 1" would
  display as "n=2" because the fallback comparison window only fit 2 per
  side. Do not re-merge these.
- **Soft key identifiers vs. labels are separate.** The keys array is
  still `{"CHANGE", "UNDO", "LOG"}` internally (matches `core.change()`
  etc.), but displayed labels are remapped via `KEY_LABEL` in `screen.lua`
  (CHANGE → "MARK", CONFIG → "CFG"). If you rename a key's *label* again,
  do it in that map, not by renaming the identifier everywhere.
- **CSV schema has a trailing `seed` column** on launch rows (`"1"` or
  `""`). Sample/demo data seeded via Config → Data → "Seed sample data" is
  flagged this way and auto-purges itself the moment a genuine throw comes
  in (`purgeSeedIfPresent()`), so bench-seeded data can never bias a real
  average. If you add more columns, append them — don't reorder existing
  ones, since old rows in the field won't have new trailing columns.

## Known, unfixed bug — flagged early, never actually fixed

**Switch/source-type config fields do not survive a reboot.**
`changeSwitch`, `undoSwitch` in `core.lua`'s config are Ethos *source*
objects (assigned via the native `form.addSourceField` picker in
`config.lua`). `core.saveConfig()` persists every config value with
`tostring(v)` into `config.csv`. That's fine for numbers, but calling
`tostring()` on a source object does not produce something that can be
turned back into a usable source — on the next boot, `loadConfig()` reads
it back as an inert string, and `pollSwitches()`'s call to `:value()` on
that string fails silently inside a `pcall`, so the assigned switch just
stops doing anything. **No error, no warning — it just quietly stops
working after the first reboot following assignment.**

This was identified in the very first round of work on this codebase and
flagged repeatedly, but the fix was never implemented (attention kept
going to higher-priority bugs — the file-reading crash chain ate most of
the debugging budget). The likely correct fix: route these specific fields
through Ethos's native `storage.write`/`storage.read` (which is documented
to handle the `source` type correctly for widget config), rather than the
hand-rolled CSV, while leaving the numeric fields (floor/ceiling/window/
theme/bars) on the CSV scheme they're already using. This has **not been
attempted or verified** — treat it as an open task, not a known-good plan.

**Workaround until fixed:** assign CHANGE/UNDO via the on-screen soft keys
rather than a physical switch. The on-screen keys are unaffected (they
don't round-trip through config).

## Removed features (in case you need to resurrect one)

- **System Tool** (`system.registerSystemTool`) — removed once the widget
  was confirmed to cover every use case. See "Hard-won facts" #3 and #4
  above before re-adding.
- **Test mode** (`test.lua` — manual/auto/scripted synthetic-throw
  drivers) — removed once real hardware capture was confirmed reliable.
  It hooked into the same `core.recordLaunch()` seam real capture uses, so
  if you need it back for bench work, that architecture is the template:
  never fake data any other way.

## What's verified vs. what's still a guess

**Verified on real hardware (X14, Ethos 26.1.1):** real capture via the
DLG template's `ALT_CALL`/`MOM_LAUNCH` logic switches, persistence across
multiple reboots, settings opening via both the long-press menu and native
configure, light/dark theme switching, the bar strip with per-bar labels
and group-boundary markers, identity binding via `model.id()`+name in
`gliders.csv`.

**Not verified / best-effort only:**
- The switch-persistence bug above.
- Whether widget background execution (`wakeup()` continuing on a
  different screen of the same model) holds on this specific Ethos
  version — see fact #8.
- Rotary/encoder focus-cycling on the widget specifically (vs. the old
  System Tool, where it was more directly tested).
- Behavior when the DLG model is cloned (new receiver number) — the
  identity-binding design handles this in theory (see `bindIdentity()`
  comments) but hasn't been bench-tested with an actual clone.
