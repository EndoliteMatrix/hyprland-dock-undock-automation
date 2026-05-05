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

apply() {
    local cfg result state
    if docked; then
        cfg="${INTERNAL_DESC},disable"
        state="docked"
    else
        cfg="${INTERNAL_DESC},$(internal_on_config)"
        state="undocked"
    fi
    result=$(hyprctl keyword monitor "$cfg" 2>&1)
    log "apply state=$state cfg=${cfg} result=${result}"
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
