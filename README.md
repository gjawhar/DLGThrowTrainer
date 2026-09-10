# Throw Trainer

DLG launch-height training assistant for FrSky Ethos. Built and tested on
FrSky X14 and X20RS radios running Ethos 26.1.1.

Throw Trainer is an Ethos widget that reads launch height from Mike
Shellim's "DLG for Ethos" template and helps a DLG pilot tell whether a
setup change (camber, trim, ballast, rudder offset) actually helped, or
whether the difference is just throw-to-throw noise.

## What the widget shows

- The height of your last launch, and how it compares to your previous set.
- A bar strip of recent launch heights, each one labeled with its own
  value, with "current set"/"previous set" captioned underneath the bars
  when there's room for it.
- A before/after delta comparison: mark a setup change with the **MARK**
  key, and the widget compares your current set's average against the
  previous one. With no mark ever pressed, it falls back to a
  recent-vs-earlier window split of the same ongoing set.
- **Automatic setup marks (2.0).** Adjust camber/reflex or elevator trim
  in Launch or Zoom mode, or the rudder offset, and the widget notices.
  Your next throw that clears the minimum height confirms the change as a
  mark, with the actual trim deltas recorded against it, so you never have
  to remember to press MARK after a field tweak.
- Day (light) or Night (dark) theme — defaults to Day, since most flying
  happens outdoors.
- A fresh install starts with a small demo data set (including a sample
  mark) instead of a blank screen, so you can see how the comparison and
  strip captions work before your first real throw. It's purged
  automatically and silently the moment a real throw comes in.

## Layouts

Throw Trainer is only offered at two widget sizes, chosen so the numbers
stay legible and the bar strip is actually readable:

- **Full** — the complete interactive view: the key row, last-launch and
  comparison panels, and the bar strip.
- **Half** — a wide, full-width/half-height slot. Deliberately read-only:
  just the bar strip filling the space, nothing to press. If you want to
  mark a change or reach Settings, use the Full layout elsewhere on the
  same model.

Any smaller placement (a quarter cell, a narrow column) isn't supported —
it just shows a short message telling you to use one of the two sizes
above.

## Controls (Full layout only)

The top row of keys — **MARK / REVIEW LOG / CFG / CHANGES** — lines up
with your radio's FS1–FS4 function switches, so you can use either the
physical switches or the on-screen keys (rotary + ENTER, or tapping
directly on a touch-capable radio like the X20RS). None of it responds
until the widget is the visible, focused thing on your screen — a stray
press or switch flick elsewhere never affects it.

- **MARK** — record a setup change by hand. Press again before any throw
  lands under it to cancel.
- **REVIEW LOG** — every throw and mark, newest first, with the trim
  deltas each auto-detected mark carried. ENTER on the newest entry
  removes it (press again to confirm — this replaces the old UNDO key).
  ENTER on an older auto-detected mark offers to revert your trims to it.
- **CFG** — open Settings without leaving the widget.
- **CHANGES** — the current setup: trim and rudder-offset drift since
  power-on for Launch and Zoom, plus:
  - **ACCEPT** — take the current setup as the new baseline.
  - **REVERT** — walk you back to the baseline (or to a mark chosen from
    the log) one trim at a time, telling you which trim to move, which
    way, and by how much, and confirming when everything matches.
  - **RUD OFFSET** — edit the rudder offset with the rotary without
    leaving the widget.

When a setup change is detected mid-session the CHANGES screen opens by
itself, and every throw returns you to the main screen.

## What the widget needs from your model

Throw Trainer reads Mike Shellim's "DLG for Ethos" template by name. On
the model it must find:

- a telemetry sensor named **`Altitude`** (the vario), and
- logic switches named **`ALT_CALL`** and **`MOM_LAUNCH`**.

Auto-detected setup marks additionally use the **`V_RudOffset`** variable
and the template's Throttle (camber/reflex) and Elevator trims. If any of
these are renamed on your model, throws or changes silently stop
registering — check the names before assuming the widget is broken.

## Settings

Press **CFG**, or long-press the widget on a model screen (native Ethos
"Configure" option, or the widget's own "Throw Trainer settings" menu
entry — all three reach the same form) for: minimum height, comparison
window size, stale-telemetry limit (how old the altitude reading may be
before a throw is refused; 0 switches the check off, mainly for the
simulator), bar count, and theme.

**Known limitation:** switch-type config fields (CHANGE/UNDO switch
assignment) do not currently survive a reboot — see `CLAUDE.md` for why
and the workaround (use the on-screen/hardware keys instead of assigning a
physical switch).

## Installation

### Install with Ethos Suite

1. Download the release ZIP (see the
   [Releases page](https://github.com/gjawhar/DLGThrowTrainer/releases)) —
   it's already shaped the way Ethos Suite expects, no repacking needed.
2. In Ethos Suite, open the **Lua Library** tab.
3. Choose **Install lua script** and select the ZIP file.
4. Let Ethos Suite copy the script to the radio storage, then assign the
   widget to a model screen at Full size, or the wide Half slot (it will
   appear as "Throw Trainer" in the widget picker either way) and open its
   Settings to configure the minimum height and confirm the height source
   from the DLG template.

ZIP structure for Ethos Suite:

```
scripts/
└── ThrowTrn/
    ├── main.lua
    ├── core.lua
    ├── draw.lua
    ├── screen.lua
    ├── config.lua
    └── Files/
```

`Files/` must exist (even empty) because the widget stores
`launches.csv`, `events.csv`, `gliders.csv`, and `config.csv` there
automatically as it runs.

### Install manually via the SD card or internal storage

Ethos radios can store scripts either on a removable SD card or in the
transmitter's internal storage — use whichever your radio is set up with.

1. Connect the radio to your computer and open its storage (SD card or
   internal storage, depending on your setup) in your file manager.
2. Copy the `ThrowTrn` folder into the `scripts` folder there so the final
   script path is `scripts/ThrowTrn/main.lua`.
3. Safely disconnect/eject and start (or reboot) the radio.
4. Open the model where the widget will be used, go to screen
   configuration, choose a Full or wide Half widget location, and select
   "Throw Trainer".
5. Open the widget configuration page and set the minimum height, the
   comparison window, and any other options.

## Feedback

Found a bug, or something that doesn't behave the way you'd expect?
Please open an issue on GitHub rather than emailing me directly — that
way bugs, discussion, and fixes all stay tracked in one place other pilots
can also see:

**https://github.com/gjawhar/DLGThrowTrainer/issues**

## Development

See [`CLAUDE.md`](CLAUDE.md) for architecture notes, the hard-won
Ethos-Lua gotchas this codebase ran into (file I/O quirks, logic-switch
polarity, undocumented Function Switch resolution, etc.), and the
known-unfixed switch-persistence bug — read that before touching file I/O
or widget config code.
