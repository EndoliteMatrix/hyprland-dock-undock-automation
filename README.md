# hypr-dock-toggle

A small Hyprland watcher that automatically hides your laptop's internal
panel when a specific external (dock) monitor is connected, and restores it
when you undock. Reacts both at startup and live to monitor add/remove events.

It hides the panel by **parking it off-screen + DPMS-off** rather than
`monitor:disable` — see [Why off-screen park](#why-off-screen-park-not-disable)
for the reason. Optionally **lid-aware**: keeps the panel on as an extra monitor
when docked with the lid open, and parks it only in clamshell (lid closed).

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

## Why off-screen park, not `disable`

The obvious way to hide the internal panel when docked is
`hyprctl keyword monitor "desc:…,disable"`. On some setups that's fine — but
with a physically-connected internal panel, Hyprland's `monitor:disable` has
two failure modes (observed on Hyprland **0.55.2**):

1. **Flap while docked** — Hyprland keeps re-adding the still-present internal
   panel, fighting the `disable`: a `monitorremoved`→`monitoradded` loop every
   few seconds.
2. **No re-enable on undock** — once disabled, removing the externals and
   dispatching `…,enable` is *accepted* but no monitor-add follows, so the
   panel stays **dark until you re-dock**.

Both failure modes show up entirely in **Hyprland's own monitor events** (the
flap loop; the `enable` that's accepted but never re-adds the panel), with no
matching upstream kernel bug — i.e. it's a **compositor** issue, not a
kernel/CRTC one. To sidestep both, this tool never disables the panel; it
**parks it off-screen** at `-30000x0` with **DPMS-off**, so the monitor stays
*enabled* the whole docked session (the cursor can't reach a negative-x
position, so the parked panel is unreachable). On undock / lid-open it restores
the panel's normal mode/position and DPMS-on.

> If your Hyprland doesn't show those `disable` bugs, plain `monitor:disable` is
> simpler (real power-down, no phantom monitor). This project defaults to
> off-screen-park because that's what its author needs; the trade-off is a
> still-powered (but blanked, off-screen) panel while docked.

## Requirements

- Hyprland (developed against 0.54.x–0.55.x; current behavior verified on 0.55.2)
- `bash`, `jq`, `socat` — all available in standard package repositories
- Optional: nwg-displays for managing the rest of your monitor layout
- Optional (for lid-aware parking): a Hyprland lid bind — see [Configure](#configure)

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

# The panel's CONNECTOR name, for the dpms on/off calls (INTERNAL_DESC selects
# by description; dpms needs the connector). Defaults to eDP-1.
INTERNAL_CONNECTOR='eDP-1'

# Re-home workspace 1 onto a VISIBLE dock monitor while docked, so Super+1 /
# focus never lands on the off-screen-parked panel. A persistent named
# `offscreen` workspace is pinned to the panel so no numbered Super+N reaches
# it. Empty = leave workspaces alone.
DOCKED_WS1_DESC=''                  # or e.g. 'desc:Acme Corp DockMonitor 27'
```

### Step 4 (optional): lid-aware parking

By default the panel is parked whenever you're docked. To instead keep it on as
an extra monitor when docked with the **lid open**, and park it only in
**clamshell** (lid closed), wire Hyprland's lid switch to the script so it knows
the lid state (Hyprland's `socket2` does not emit lid events). Add to your
Hyprland config:

```
bindl = , switch:on:Lid Switch,  exec, ~/.config/hypr/custom/scripts/dock-monitor-toggle.sh --lid closed
bindl = , switch:off:Lid Switch, exec, ~/.config/hypr/custom/scripts/dock-monitor-toggle.sh --lid open
```

> If your lid reports reversed (some firmware does), swap `closed`/`open`.
> Without this bind the script falls back to assuming clamshell while docked.

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
2026-04-27 22:34:11 [12345] apply state=clamshell(docked+lid-closed) action=offscreen+dpms-off result=ok
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
3. If docked **and** the lid is closed (clamshell), **parks** the panel
   off-screen (`desc:…,preferred,-30000x0,1.0`) and `dpms off`s it — never
   `disable` (see [Why off-screen park](#why-off-screen-park-not-disable)).
   If `DOCKED_WS1_DESC` is set, it also re-homes workspace 1 onto that visible
   monitor and pins a persistent named `offscreen` workspace to the panel so no
   `Super+N` strands on it.
4. Otherwise (undocked, or docked with the lid open), reads the laptop's line
   from `monitors.conf`, falls back to `INTERNAL_FALLBACK` if it's `disable`
   or missing, applies `INTERNAL_FORCE_POSITION`/`SCALE` if set, appends any
   `INTERNAL_EXTRAS` not already present, applies that, and `dpms on`s the
   panel (restoring workspace 1 to it).
5. Runs `apply()` once at startup, then `socat`s to Hyprland's `socket2`
   and reruns `apply()` on every `monitoradded` / `monitorremoved` event
   (and the `v2` variants), as well as on `configreloaded` events so that
   `INTERNAL_EXTRAS` and any force-overrides survive an nwg-displays save.
6. On topology-change events (add/remove only — not config reloads),
   wraps the apply with a hyprlock kill-and-restart guard so the lock
   surface doesn't segfault on a vanishing EGL context. No-op when
   hyprlock isn't running.
7. Lid state is fed separately by the optional `--lid closed|open` bind
   (`socket2` emits no lid event); `apply()` reads the cached state to decide
   clamshell vs. docked-lid-open.

Logs each apply to `~/.local/state/dock-monitor-toggle.log`.

## License

GNU — do whatever.
# hyprland-dock-undock-automation
