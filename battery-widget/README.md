# Battery Widget

A drop-in replacement for Noctalia's built-in `battery` bar widget, focused on
two problems that the built-in widget (and every battery plugin in the
community catalog) inherits from UPower:

1. **Rate and time-left spiking.** On laptops whose fuel gauge only updates in
   coarse steps, UPower's `EnergyRate` is a short-interval derivative. One
   0.37 Wh step inside a 15 s window becomes ~89 W, and the derived time-left
   collapses to "15m" — then both vanish when a window happens to contain no
   step. This plugin ignores UPower entirely: it samples sysfs and computes a
   least-squares slope over a configurable 20-minute window. The rate appears
   once the window holds real movement, and it does not flicker.
2. **Health pinned at 100 %.** Some firmwares (HP, in particular) report
   `energy_full_design` equal to the current `energy_full`, so `capacity` is
   always 100 %. This plugin derives the real design capacity from SMBIOS
   Type 22 instead, caches it, and recomputes health from the learned
   full-charge capacity on every update.

The bar appearance is intentionally the same as the built-in widget: the same
battery glyphs and thresholds, the same percentage/time/rate label options, the
same warning colour and hide rules, and the same tooltip order (level, status,
time, power, health) with design capacity and cycle count appended.

## Requirements

- Noctalia v5 with plugin API 26 or newer.
- Linux sysfs battery attributes (`/sys/class/power_supply/BAT*`).
- Optional, only for the one-time privileged SMBIOS read: `pkexec` and `dmidecode`.

## Install

### As a local path source (recommended for development)

```sh
noctalia msg plugins source add local-dev path /home/tunaflsh/noctalia-plugins
noctalia msg plugins enable tunaflsh/battery-widget
```

Edits to `.luau` files hot-reload.

### Copy into the local data dir

```sh
mkdir -p ~/.local/share/noctalia/plugins
cp -r battery-widget ~/.local/share/noctalia/plugins/
noctalia msg plugins enable tunaflsh/battery-widget
```

## Replace the built-in widget

The built-in widget is named `battery` in the bar. Override that instance with
the plugin, so the bar list does not change:

```toml
# ~/.config/noctalia/config.toml
[widget.battery]
type = "tunaflsh/battery-widget:battery"
```

`[bar.default] end = [ ..., "battery", ... ]` keeps working unchanged. If you
prefer a separate icon next to the built-in one, add a new name instead:

```toml
[widget.battery-plugin]
type = "tunaflsh/battery-widget:battery"
```

and put `"battery-plugin"` in the bar's `start`/`center`/`end` array.

Noctalia hot-reloads the config; no restart is needed.

## Settings

Plugin-level settings are edited under **Settings → Plugins → Battery Widget**
(the gear on the plugin row):

| Setting | Default | Purpose |
| --- | --- | --- |
| `device` | `auto` | `auto`, a sysfs name (`BAT0`), or an absolute sysfs path |
| `design_capacity_mwh` | `0` | `0` = auto: cached SMBIOS → direct SMBIOS → firmware. Set a value only to override auto-detection |
| `auto_detect_design` | `false` | When firmware lies, ask once via polkit to read SMBIOS (2 min after start; retries after 7 days if missed) |
| `smoothing_window_min` | `20` | Least-squares window for rate/time; 10–60 minutes |

Widget settings are edited on the widget instance itself:

| Setting | Default | Purpose |
| --- | --- | --- |
| `show_label` | `true` | Show the text next to the glyph |
| `label_content` | `percent` | `percent`, `time`, or `rate` on horizontal bars |
| `hide_when_plugged` | `false` | Hide while on AC |
| `hide_when_full` | `false` | Hide when fully charged |
| `show_health` | `true` | Show health in the tooltip |
| `warning_color` | `error` | Colour at/below `[battery] warning_threshold` |

Clicking the widget opens Noctalia's built-in control-center power panel, so the
power-profile switch and the rest of the built-in power controls stay available.
That native tab reads UPower directly, so its rate/time can still show the old
88 W / 15m artifacts; this widget's tooltip is the corrected source for rate,
time, and health.

## Health and design capacity

Health is `energy_full / design_capacity * 100`, capped at 100 %.

Design capacity is resolved in this order:

1. an explicit `design_capacity_mwh` setting,
2. a cached SMBIOS value (`~/.local/state/noctalia/plugins/data/tunaflsh/battery-widget/design.json`),
3. a direct rootless read of `/sys/firmware/dmi/entries/22-*/raw` (or
   `/sys/firmware/dmi/tables/DMI`) — parsed in the plugin,
4. the firmware's `energy_full_design`.

When the resolved value is exactly equal to `energy_full`, the plugin treats it
as the firmware's "design = full" bug, marks the tooltip health as
`(design not reported)`, and never pretends 100 % is real.

On this HP the DMI entries are root-only (`-r-------- nobody nobody`), so step 3
cannot work from the plugin process. Run the one-time privileged read:

```sh
noctalia msg plugin tunaflsh/battery-widget:sampler all detect-design
```

It runs `pkexec dmidecode -t 22`, parses the `Design Capacity: … mWh` line,
stores it in the plugin data directory, and immediately republishes the
snapshot. There is no model-specific constant in the plugin or the config.

You can also enable `auto_detect_design` to have the plugin ask two minutes
after start when it detects the firmware bug. If the prompt is missed, it will
not nag on every start; use the IPC command above any time.

An explicit `design_capacity_mwh` always wins over the cache, which wins over
the direct SMBIOS read, which wins over the firmware value.

## Why not the community plugins?

Checked against the community catalog at commit `0ad2bbf`:

- `yocraft/battery-widget` — desktop/lockscreen widget; reads UPower
  `EnergyRate`/`TimeToEmpty` directly, so it has the same 88 W / 15m spikes, and
  it does not show health.
- `piero-93/battery-power-management` — bar widget with watts and power
  profiles, but watts come from UPower (0 W here) and time from
  `upower`; no health and the charge threshold is unsupported on this HP.
- `frai3mega/battery-graph` — history graph only.
- `damian-ds7/battery-threshold`, `neoscaler/charge-mode` — charge limit/mode
  control, neither exposed by the HP EC.

None of them addresses the coarse-gauge rate estimate or a design capacity
that the firmware reports incorrectly.

## Limitations

- One battery. `auto` picks the first present `BAT*`; multi-battery laptops can
  pin a device but the tooltip does not list every battery like the built-in
  widget does.
- `display_mode = "graphic"` and `peek` are not implemented; this is the glyph
  layout only.
- Peripheral batteries (mice, headsets, gamepads) are not followed; this is for
  the system battery.
- The rate needs a few minutes of history after login or a power-source change.
  Until then the label falls back to percentage, which is the same fallback the
  built-in uses when it has no value.

## Files

- `plugin.toml` — manifest, entries, settings.
- `service.luau` — sysfs sampler, rate regression, health, design detection.
- `widget.luau` — bar presentation.
- `lib/battery.luau` — sysfs reader, SMBIOS parser, glyph/threshold helpers, formatting.
- `translations/en.json` — strings.

## License

MIT.
