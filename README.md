# Throw Trainer

DLG launch-height training assistant for FrSky Ethos. Built/tested on an X14
running Ethos 26.1.1.

Throw Trainer is an Ethos widget that reads launch height from Mike
Shellim's "DLG for Ethos" template and helps a DLG pilot tell whether a
setup change (camber, trim, ballast, rudder offset) actually helped, or
whether the difference is just throw-to-throw noise.

## What the widget shows

- A running average and count for the current "set" of throws.
- A bar strip of recent launch heights with group-boundary markers.
- A before/after delta comparison: mark a setup change with the on-screen
  **MARK** key, and the widget compares the average of throws before the
  mark against throws after it. With no mark pressed, it falls back to a
  recent-vs-previous window split.
- Light/dark theme, and three layout tiers so it looks right at any widget
  size.

## Settings

Long-press the widget on a model screen (native Ethos "Configure" option,
or the widget's own "Throw Trainer settings" menu entry) to reach the
Settings form: floor/ceiling height bounds, comparison window size, bar
count, and theme.

**Known limitation:** switch-type config fields (CHANGE/UNDO switch
assignment) do not currently survive a reboot — see `CLAUDE.md` for why and
the workaround (use the on-screen soft keys instead of a physical switch).

## Installation

### Install with Ethos Suite

1. Prepare a ZIP file that contains the final folder structure directly:
   the archive's top-level path should be `scripts/ThrowTrn/...`, not
   wrapped in an extra parent folder.
2. In Ethos Suite, open the **Lua Library** tab.
3. Choose **Install lua script** and select the ZIP file.
4. Let Ethos Suite copy the script to the radio storage, then assign the
   widget to the desired model screen (it will appear as "Throw Trainer" in
   the widget picker) and open its Settings to configure floor/ceiling and
   the height source from the DLG template.

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
   configuration, choose a widget location, and select "Throw Trainer".
5. Open the widget configuration page and set floor/ceiling height, the
   comparison window, and any other options.

## Development

See [`CLAUDE.md`](CLAUDE.md) for architecture notes, the hard-won
Ethos-Lua gotchas this codebase ran into (file I/O quirks, logic-switch
polarity, etc.), and the known-unfixed switch-persistence bug — read that
before touching file I/O or widget config code.
