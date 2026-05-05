# hypr-dock-toggle

A small Hyprland watcher that auto-disables your laptop's internal panel
when a specific external monitor is connected, and re-enables it when you
undock. Reacts both at startup and live to monitor add/remove events.

Built to fill a gap that one-shot display configurators (like nwg-displays)
can't fill: switching laptop-panel state automatically based on dock
presence, without manual toggling.

## What it does

- On Hyprland startup, runs once and applies the right state for your
  current dock situation.
- Subscribes to Hyprland's `socket2` event stream and reruns whenever a
  monitor is added or removed (i.e. every time you dock, undock, open or
  close the lid). Reacts within milliseconds.
- Only touches the internal panel. Your external monitors' positions,
  scales, refresh rates, etc. are governed by `monitors.conf` (which
  nwg-displays or your hand-edits manage). The script never overrides them.

## Requirements

- Hyprland (tested on 0.54.x)
- `bash`, `jq`, `socat` — all available in standard package repositories
- Optional: nwg-displays for managing the rest of your monitor layout

## Install

```bash
git clone https://github.com/EndoliteMatrix/hypr-dock-toggle.git
cd hypr-dock-toggle
./install.sh
```

The installer:
1. Drops `dock-monitor-toggle.sh` into `~/.config/hypr/custom/scripts/`.
2. Drops a config template `dock-monitor-toggle.conf` next to it (only if
   you don't already have one).
3. Appends `exec-once = …/dock-monitor-toggle.sh` to
   `~/.config/hypr/custom/execs.conf`.
4. Optionally launches the watcher under your running Hyprland.

> If your Hyprland config layout doesn't have a `custom/execs.conf`, the
> installer will print the line you need to add manually.

## Configure

After install, edit `~/.config/hypr/custom/scripts/dock-monitor-toggle.conf`.
The keys below all take placeholder values — replace each `<...>` with
something from your own setup.

### Step 1: find your monitor identifiers

```bash
hyprctl monitors -j | jq '.[] | {name, description}'
```

You'll see something like:

```
{ "name": "eDP-1", "description": "<laptop panel vendor + model>" }
{ "name": "DP-1",  "description": "<external monitor vendor + model>" }
```

Copy the laptop's `description` and a substring of any monitor that's
only present when you're docked.

### Step 2: required keys

```bash
# Which monitor is your laptop's internal panel.
# Use 'desc:<exact description string>' so it survives connector renames.
INTERNAL_DESC='desc:<your laptop panel description>'

# Substring of any monitor that's only attached via your dock.
# When the script sees this in any connected monitor's description, it
# treats you as docked. Vendor + model is usually a safe pick.
EXTERNAL_TAG='<unique substring of your dock monitor>'
```

### Step 3: optional keys

```bash
# How to set the laptop when there's nothing usable in monitors.conf.
# Format: <MODE>,<POSITION>,<SCALE>
INTERNAL_FALLBACK='preferred,auto,1'

# Hyprland monitor extras (bitdepth, color management, VRR, etc.) that
# nwg-displays doesn't write. Appended every time the panel is enabled
# so they remain "sticky" across nwg-displays saves. Empty = nothing.
INTERNAL_EXTRAS=''                  # or e.g. 'bitdepth,10'

# When set, override the position/scale fields read from monitors.conf.
# Use these only if your display configurator can't place the laptop
# tile cleanly next to your externals (e.g. nwg-displays' tile snapping
# struggles with mismatched DPIs). Both default to empty.
INTERNAL_FORCE_POSITION=''          # or e.g. '<x>x<y>' such as '0x1440'
INTERNAL_FORCE_SCALE=''             # or e.g. '1.0'
```

A fully worked example config with comments is at
[`dock-monitor-toggle.conf.example`](dock-monitor-toggle.conf.example).

## monitors.conf invariant

**Keep your internal panel enabled in `monitors.conf` — never `disable`.**

```
# good
monitor=desc:Your Laptop Panel Name,preferred,auto,1

# bad — bricks an undocked boot if the watcher is slow or fails
monitor=desc:Your Laptop Panel Name,disable
```

The watcher takes care of disabling the panel at runtime when the dock is
detected. If `monitors.conf` itself disables the panel, an undocked boot
can land you in a black-screen state before the watcher gets a chance to
override it (the panel powers down at the hardware level, so even
switching to a TTY doesn't help — you'd need to reboot).

A reference layout is in
[`monitors.conf.example`](monitors.conf.example).

### nwg-displays gotcha

If you use nwg-displays: **save your monitor layout while undocked.**
Saving while docked writes `disable` for the laptop panel, breaking the
invariant. The watcher will still recover you on undock via the fallback,
but you'll have lost any custom scale/mode you'd set, and you'll have a
fragile boot until you re-save undocked.

## Usage

After install, login to Hyprland and dock/undock as normal. The script
runs in the background for the entire session.

To verify it's reacting in real time:

```bash
tail -f ~/.local/state/dock-monitor-toggle.log
```

…then plug or unplug your dock. You should see lines like:

```
2026-04-27 22:34:11 [12345] event: monitoraddedv2>>5,DP-1,Acme Corp DockMonitor 27
2026-04-27 22:34:11 [12345] apply state=docked  cfg=desc:LG Display 0xABCD,disable  result=ok
```

## Uninstall

```bash
./uninstall.sh           # keeps config and log
./uninstall.sh --purge   # also removes config + log
```

Stops the running watcher, removes the exec-once line (with a `.bak` of
the modified file), and deletes the script.

## How it works

The script:

1. Reads `~/.config/hypr/.../dock-monitor-toggle.conf` for monitor
   identifiers and behavior knobs.
2. Defines `apply()`, which calls `hyprctl monitors -j` and uses `jq` to
   check if any connected monitor's description contains `EXTERNAL_TAG`.
3. If yes (docked), runs `hyprctl keyword monitor "$INTERNAL_DESC,disable"`.
4. If no (undocked), reads the laptop's line from `monitors.conf`, falls
   back to `INTERNAL_FALLBACK` if it's `disable` or missing, appends any
   `INTERNAL_EXTRAS` not already present, and applies that.
5. Runs `apply()` once at startup, then `socat`s to Hyprland's `socket2`
   and reruns `apply()` on every `monitoradded` / `monitorremoved` event
   (and the `v2` variants), as well as on `configreloaded` events so that
   `INTERNAL_EXTRAS` and any force-overrides survive an nwg-displays save.
6. On topology-change events (add/remove only — not config reloads),
   wraps the apply with a hyprlock kill-and-restart guard so the lock
   surface doesn't segfault on a vanishing EGL context. No-op when
   hyprlock isn't running.

Logs each apply to `~/.local/state/dock-monitor-toggle.log`.

## License

GNU — do whatever.
# hyprland-dock-undock-automation
