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

The top row of keys — **MARK / UNDO / LOG / CFG** — lines up with your
radio's FS1–FS4 function switches, so you can use either the physical
switches or the on-screen keys (rotary + ENTER, or tapping directly on a
touch-capable radio like the X20RS). None of it responds until the widget
is the visible, focused thing on your screen — a stray press or switch
flick elsewhere never affects it.

- **MARK** — record a setup change. Press again before any throw lands
  under it to cancel.
- **UNDO** — remove the last throw or mark. Press twice to confirm (no
  confirmation dialog on a widget — two presses stands in for one).
- **LOG** — see every recorded throw, newest first.
- **CFG** — open Settings without leaving the widget.

## Settings

Press **CFG**, or long-press the widget on a model screen (native Ethos
"Configure" option, or the widget's own "Throw Trainer settings" menu
entry — all three reach the same form) for: minimum height, comparison
window size, bar count, and theme.

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
