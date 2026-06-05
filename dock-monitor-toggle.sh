#!/usr/bin/env bash
# dock-monitor-toggle: a Hyprland watcher that auto-disables an internal laptop
# panel when a specific external dock monitor is connected, and re-enables it
# when undocked. Reacts both at startup and live to monitor add/remove events.
#
# Reads its configuration from:
#   ${XDG_CONFIG_HOME:-$HOME/.config}/hypr/custom/scripts/dock-monitor-toggle.conf
#
# See README.md for design notes and the recommended monitors.conf invariant.

set -u

CONF="${XDG_CONFIG_HOME:-$HOME/.config}/hypr/custom/scripts/dock-monitor-toggle.conf"
if [ ! -r "$CONF" ]; then
    echo "dock-monitor-toggle: missing config at $CONF" >&2
    echo "  copy dock-monitor-toggle.conf.example there and edit it." >&2
    exit 1
fi
# shellcheck source=/dev/null
. "$CONF"

: "${INTERNAL_DESC:?config error: INTERNAL_DESC must be set (e.g. 'desc:LG Display 0xABCD')}"
: "${EXTERNAL_TAG:?config error: EXTERNAL_TAG must be set (e.g. 'My Dock Monitor Vendor Name')}"
INTERNAL_FALLBACK="${INTERNAL_FALLBACK:-preferred,auto,1}"
INTERNAL_EXTRAS="${INTERNAL_EXTRAS:-}"
# Optional: when set, the position and/or scale fields in monitors.conf
# are ignored and replaced with these values. Useful when a display
# configurator (e.g. nwg-displays) cannot reliably place the laptop tile
# relative to higher- or lower-DPI external monitors.
INTERNAL_FORCE_POSITION="${INTERNAL_FORCE_POSITION:-}"
INTERNAL_FORCE_SCALE="${INTERNAL_FORCE_SCALE:-}"
# Optional: a visible dock monitor's desc to re-home workspace 1 onto while docked,
# so Super+1 / focus doesn't land on the off-screen-parked internal panel. Empty = off.
DOCKED_WS1_DESC="${DOCKED_WS1_DESC:-}"
# Lid state is event-driven: the Hyprland lid bind calls this script with
# `--lid closed|open` and we cache the value here. We do NOT poll
# /proc/acpi/button/lid — on this machine it wrongly reports 'open' while physically
# closed (lid_init_state=method, EC quirk). The panel is parked only when docked AND
# the lid is closed (clamshell); docked + lid open keeps eDP-1 on as a normal monitor.
LID_STATE_FILE="${LID_STATE_FILE:-${XDG_RUNTIME_DIR:-/tmp}/dock-monitor-lid}"

MONITORS_CONF="${MONITORS_CONF:-${XDG_CONFIG_HOME:-$HOME/.config}/hypr/monitors.conf}"
LOG="${XDG_STATE_HOME:-$HOME/.local/state}/dock-monitor-toggle.log"
mkdir -p "$(dirname "$LOG")"
log() { printf '%s [%d] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$$" "$*" >>"$LOG"; }

with_extras() {
    local cfg="$1"
    if [ -n "$INTERNAL_EXTRAS" ]; then
        printf '%s,%s' "$cfg" "$INTERNAL_EXTRAS"
    else
        printf '%s' "$cfg"
    fi
}

# Append any INTERNAL_EXTRAS keys that aren't already present in the parsed line.
# INTERNAL_EXTRAS is a comma-separated list of "key,value" pairs, e.g. "bitdepth,10,cm,hdr".
append_missing_extras() {
    local cfg="$1"
    [ -z "$INTERNAL_EXTRAS" ] && { printf '%s' "$cfg"; return; }
    local IFS=','
    read -ra pairs <<<"$INTERNAL_EXTRAS"
    local i k v
    for ((i=0; i+1<${#pairs[@]}; i+=2)); do
        k="${pairs[i]}"
        v="${pairs[i+1]}"
        if [[ "$cfg" != *"${k},"* ]]; then
            cfg="${cfg},${k},${v}"
        fi
    done
    printf '%s' "$cfg"
}

force_position_and_scale() {
    local cfg="$1"
    if [ -z "$INTERNAL_FORCE_POSITION" ] && [ -z "$INTERNAL_FORCE_SCALE" ]; then
        printf '%s' "$cfg"
        return
    fi
    # Hyprland monitor syntax is MODE,POSITION,SCALE[,extras...].
    local -a parts
    IFS=',' read -ra parts <<<"$cfg"
    if (( ${#parts[@]} >= 3 )); then
        [ -n "$INTERNAL_FORCE_POSITION" ] && parts[1]="$INTERNAL_FORCE_POSITION"
        [ -n "$INTERNAL_FORCE_SCALE" ] && parts[2]="$INTERNAL_FORCE_SCALE"
        cfg=$(IFS=','; echo "${parts[*]}")
    fi
    printf '%s' "$cfg"
}

internal_on_config() {
    local line rest
    line=$(grep -F "monitor=${INTERNAL_DESC}," "$MONITORS_CONF" 2>/dev/null | tail -n1)
    if [ -z "$line" ]; then
        rest="$INTERNAL_FALLBACK"
    else
        rest=${line#monitor=${INTERNAL_DESC},}
        if [ "$rest" = "disable" ] || [ -z "$rest" ]; then
            rest="$INTERNAL_FALLBACK"
        fi
    fi
    rest=$(force_position_and_scale "$rest")
    append_missing_extras "$rest"
}

docked() {
    hyprctl monitors -j 2>/dev/null \
        | jq -e --arg tag "$EXTERNAL_TAG" 'any(.[]; .description | contains($tag))' >/dev/null
}

# True when the lid is closed, per the event-driven cache the Hyprland lid bind writes.
# Only evaluated when docked (see apply). If no lid event has been seen yet this boot
# (flag absent), assume clamshell — the common docked-boot case — and let the next lid
# toggle correct it.
lid_closed() {
    if [ -r "$LID_STATE_FILE" ]; then
        [ "$(cat "$LID_STATE_FILE" 2>/dev/null)" = closed ]
    else
        return 0
    fi
}

apply() {
    local result is_docked=0
    docked && is_docked=1
    # Park the panel only in clamshell (docked AND lid closed). Docked with the lid
    # open, or undocked, keeps eDP-1 on as a normal monitor.
    if [ "$is_docked" = 1 ] && lid_closed; then
        # Park eDP-1 off-screen + DPMS-off instead of `monitor:disable`.
        # WHY NOT disable: Hyprland's `monitor:disable` misbehaves with a
        # physically-connected internal panel — (1) while docked it FLAPS
        # (Hyprland keeps re-adding the panel, fighting the disable), and
        # (2) on undock a disabled internal panel often fails to RE-ENABLE
        # (the `enable` keyword is accepted but no monitor-add event follows),
        # leaving the panel dark until you re-dock. Parking off-screen keeps
        # the monitor ENABLED the whole time, sidestepping both failure modes
        # (it keeps a CRTC assigned as a side effect). Observed on Hyprland
        # 0.55.2 — a compositor issue: the flap and the failed re-enable show
        # up in Hyprland's own monitor events, with no matching upstream kernel
        # bug. See README "Why off-screen park".
        #
        # `preferred` = the panel's native EDID mode. Off-screen at -30000x0 is
        # unreachable: no monitor's left edge sits at a negative x, so the
        # cursor stops at x=0 and can't wander onto the parked panel.
        hyprctl keyword monitor "${INTERNAL_DESC},preferred,-30000x0,1.0" >/dev/null 2>&1
        result=$(hyprctl dispatch dpms off "${INTERNAL_CONNECTOR:-eDP-1}" 2>&1)
        log "apply state=clamshell(docked+lid-closed) action=offscreen+dpms-off result=${result}"
        # The off-screen panel is still a live monitor, so Hyprland insists on an active
        # workspace there. Pin a NAMED parking workspace to it (no numeric Super+N can
        # reach a named workspace) and re-home ws1 — eDP-1's normal default — onto a
        # visible dock monitor. Together this guarantees none of Super+1..0 strand you on
        # the invisible panel. No-op when DOCKED_WS1_DESC is empty.
        if [ -n "$DOCKED_WS1_DESC" ]; then
            hyprctl keyword workspace "name:offscreen,monitor:${INTERNAL_DESC},default:true,persistent:true" >/dev/null 2>&1
            hyprctl keyword workspace "1,monitor:${DOCKED_WS1_DESC}" >/dev/null 2>&1
            # Order matters: move ws1 OFF eDP-1 first, THEN force name:offscreen on as
            # eDP-1's final active workspace — so whatever empty numbered ws eDP-1 grabs
            # when ws1 leaves is immediately displaced by the (unreachable) named one.
            hyprctl dispatch moveworkspacetomonitor "1 ${DOCKED_WS1_DESC}" >/dev/null 2>&1
            hyprctl dispatch moveworkspacetomonitor "name:offscreen ${INTERNAL_DESC}" >/dev/null 2>&1
            log "apply state=clamshell ws1->${DOCKED_WS1_DESC} edp->name:offscreen"
        fi
    else
        # eDP-1 ON: either undocked (sole screen) or docked with the lid open (4th
        # monitor). Re-assert its mode/position/extras (clears any off-screen park),
        # then wake. eDP-1 keeps a CRTC here, so a later undock stays safe.
        local st; [ "$is_docked" = 1 ] && st="docked+lid-open" || st="undocked"
        local cfg="${INTERNAL_DESC},$(internal_on_config)"
        hyprctl keyword monitor "$cfg" >/dev/null 2>&1
        result=$(hyprctl dispatch dpms on "${INTERNAL_CONNECTOR:-eDP-1}" 2>&1)
        log "apply state=${st} cfg=${cfg} action=dpms-on result=${result}"
        # eDP-1 is visible again — drop the parking workspace's persistence and restore
        # ws1 to eDP-1 (its normal home).
        if [ -n "$DOCKED_WS1_DESC" ]; then
            hyprctl keyword workspace "name:offscreen,monitor:${INTERNAL_DESC},persistent:false" >/dev/null 2>&1
            hyprctl keyword workspace "1,monitor:${INTERNAL_DESC},default:true" >/dev/null 2>&1
            hyprctl dispatch moveworkspacetomonitor "1 ${INTERNAL_DESC}" >/dev/null 2>&1
            log "apply state=${st} ws1->${INTERNAL_DESC}"
        fi
    fi
}

# Wrap apply() with a hyprlock kill-and-restart so the lock surface doesn't
# segfault on a vanishing EGL context during dock/undock. Only used for
# topology changes — configreloaded events don't change the monitor set.
apply_with_lock_guard() {
    local was_locked=0
    if pgrep -x hyprlock >/dev/null 2>&1; then
        was_locked=1
        pkill -x hyprlock 2>/dev/null || true
        log "lock-guard: stopped hyprlock before monitor change"
    fi
    apply
    if [ "$was_locked" = "1" ]; then
        sleep 0.5
        hyprlock &
        log "lock-guard: restarted hyprlock after monitor change"
    fi
}

# Lid bind entrypoint: record the new lid state (authoritative, event-driven) then
# re-apply. Hyprland's switch:on/off:Lid Switch binds call this; socket2 emits no event
# for lid changes, so this is how a lid toggle re-runs the logic. Runs in the Hyprland
# env, so hyprctl works. `--apply-once` re-applies using the cached lid state.
case "${1:-}" in
    --lid)
        case "${2:-}" in closed|open) printf '%s' "$2" > "$LID_STATE_FILE" 2>/dev/null ;; esac
        apply; exit 0 ;;
    --apply-once)
        apply; exit 0 ;;
esac

log "start (HYPR=${HYPRLAND_INSTANCE_SIGNATURE:-unset})"

# Brief settle delay so Hyprland's initial monitor parse completes before we override.
sleep 0.5
apply

if [ -z "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
    log "HYPRLAND_INSTANCE_SIGNATURE unset — cannot subscribe to socket2; exiting"
    exit 1
fi

SOCKET="${XDG_RUNTIME_DIR}/hypr/${HYPRLAND_INSTANCE_SIGNATURE}/.socket2.sock"
if [ ! -S "$SOCKET" ]; then
    log "socket missing at $SOCKET; exiting"
    exit 1
fi

exec socat -U - "UNIX-CONNECT:${SOCKET}" | while IFS= read -r ev; do
    case "$ev" in
        monitoradded\>\>*|monitoraddedv2\>\>*|monitorremoved\>\>*|monitorremovedv2\>\>*)
            log "event: $ev"
            apply_with_lock_guard
            ;;
        configreloaded\>\>*)
            # Hyprland reloads when a sourced config (e.g. monitors.conf) changes.
            # Without this, INTERNAL_EXTRAS get dropped whenever a display tool
            # (nwg-displays etc.) rewrites monitors.conf without them.
            log "event: $ev"
            apply
            ;;
    esac
done
