#!/usr/bin/env bash
# uninstall.sh — remove the dock-monitor-toggle watcher.
#
# Stops the systemd unit if present, removes the exec-once line if
# present, and deletes the script. With --purge, also removes config and
# log files.

set -euo pipefail

PURGE=0
if [[ "${1:-}" == "--purge" ]]; then
    PURGE=1
fi

SCRIPT_DIR="$HOME/.config/hypr/custom/scripts"
SCRIPT_DST="$SCRIPT_DIR/dock-monitor-toggle.sh"
CONF_DST="$SCRIPT_DIR/dock-monitor-toggle.conf"
LOG_FILE="$HOME/.local/state/dock-monitor-toggle.log"

UNIT_DST="$HOME/.config/systemd/user/dock-monitor-toggle.service"
EXECS_FILE="$HOME/.config/hypr/custom/execs.conf"

log() { printf '[uninstall] %s\n' "$*"; }

# 1. Stop + disable systemd unit if installed
if [[ -f "$UNIT_DST" ]]; then
    if command -v systemctl >/dev/null 2>&1 \
        && systemctl --user show-environment >/dev/null 2>&1; then
        systemctl --user disable --now dock-monitor-toggle.service || true
        log "stopped + disabled dock-monitor-toggle.service"
    fi
    rm -f "$UNIT_DST"
    log "removed unit file $UNIT_DST"
    systemctl --user daemon-reload 2>/dev/null || true
fi

# 2. Strip exec-once line from execs.conf if present
if [[ -f "$EXECS_FILE" ]] && grep -Fq "dock-monitor-toggle.sh" "$EXECS_FILE"; then
    cp "$EXECS_FILE" "$EXECS_FILE.bak"
    grep -Fv "dock-monitor-toggle.sh" "$EXECS_FILE.bak" > "$EXECS_FILE"
    log "removed exec-once line from $EXECS_FILE (backup at $EXECS_FILE.bak)"
fi

# 3. Kill any straggler processes (covers exec-once installs and dev runs)
pkill -f "$SCRIPT_DST" 2>/dev/null || true

# 4. Remove the script itself
if [[ -f "$SCRIPT_DST" ]]; then
    rm -f "$SCRIPT_DST"
    log "removed $SCRIPT_DST"
fi

# 5. Optional purge
if (( PURGE )); then
    rm -f "$CONF_DST" "$LOG_FILE"
    log "purged config + log"
fi

log "done."
