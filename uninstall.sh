#!/usr/bin/env bash
# Uninstaller for dock-monitor-toggle.
#
# Stops the running watcher, removes the exec-once line, and deletes the script.
# By default keeps your config file (so a re-install picks it up).
# Pass --purge to also remove the config and the log file.

set -euo pipefail

HYPR_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/hypr"
SCRIPTS_DIR="$HYPR_DIR/custom/scripts"
TARGET_SCRIPT="$SCRIPTS_DIR/dock-monitor-toggle.sh"
TARGET_CONF="$SCRIPTS_DIR/dock-monitor-toggle.conf"
EXEC_FILE="$HYPR_DIR/custom/execs.conf"
LOG="${XDG_STATE_HOME:-$HOME/.local/state}/dock-monitor-toggle.log"

PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1

say() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }

# --- stop running watcher ----------------------------------------------------
PIDS=$(ps -eo pid,args | awk '/dock-monitor-toggle\.sh/ && !/awk/ {print $1}' || true)
if [ -n "$PIDS" ]; then
    # shellcheck disable=SC2086
    kill $PIDS 2>/dev/null || true
    say "stopped running watcher (PIDs: $PIDS)"
fi

# --- remove exec-once line ---------------------------------------------------
if [ -f "$EXEC_FILE" ] && grep -qF "dock-monitor-toggle.sh" "$EXEC_FILE"; then
    sed -i.bak '/dock-monitor-toggle\.sh/d; /^# Auto-toggle internal laptop panel based on external dock presence\.$/d' "$EXEC_FILE"
    say "removed exec-once line from $EXEC_FILE (backup at ${EXEC_FILE}.bak)"
fi

# --- remove the script -------------------------------------------------------
[ -f "$TARGET_SCRIPT" ] && rm "$TARGET_SCRIPT" && say "removed $TARGET_SCRIPT"

# --- optionally remove config + log ------------------------------------------
if [ "$PURGE" -eq 1 ]; then
    [ -f "$TARGET_CONF" ] && rm "$TARGET_CONF" && say "removed $TARGET_CONF"
    [ -f "$LOG" ] && rm "$LOG" && say "removed $LOG"
else
    [ -f "$TARGET_CONF" ] && say "kept config at $TARGET_CONF (use --purge to remove)"
fi

say "done. Reload Hyprland (or log out/in) to fully detach from this session."
