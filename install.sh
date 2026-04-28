#!/usr/bin/env bash
# install.sh — install the dock-monitor-toggle watcher.
#
# Prefers a systemd --user service (auto-restart on failure, journalctl
# logging). Falls back to Hyprland exec-once on systems without
# systemd-user.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SCRIPT_SRC="$REPO_DIR/dock-monitor-toggle.sh"
CONF_SRC="$REPO_DIR/dock-monitor-toggle.conf.example"
UNIT_SRC="$REPO_DIR/dock-monitor-toggle.service"

SCRIPT_DIR="$HOME/.config/hypr/custom/scripts"
SCRIPT_DST="$SCRIPT_DIR/dock-monitor-toggle.sh"
CONF_DST="$SCRIPT_DIR/dock-monitor-toggle.conf"

UNIT_DIR="$HOME/.config/systemd/user"
UNIT_DST="$UNIT_DIR/dock-monitor-toggle.service"

EXECS_FILE="$HOME/.config/hypr/custom/execs.conf"

log() { printf '[install] %s\n' "$*"; }

# 1. Drop the script
mkdir -p "$SCRIPT_DIR"
install -m 0755 "$SCRIPT_SRC" "$SCRIPT_DST"
log "installed script -> $SCRIPT_DST"

# 2. Drop the config template if the user doesn't already have one
if [[ ! -e "$CONF_DST" ]]; then
    install -m 0644 "$CONF_SRC" "$CONF_DST"
    log "installed default config -> $CONF_DST"
    log "  -> edit it and set INTERNAL_DESC / EXTERNAL_TAG before relying on this"
else
    log "kept existing config at $CONF_DST"
fi

# 3. Decide on launch method
have_systemd_user() {
    command -v systemctl >/dev/null 2>&1 \
        && systemctl --user show-environment >/dev/null 2>&1
}

if have_systemd_user && [[ -f "$UNIT_SRC" ]]; then
    mkdir -p "$UNIT_DIR"
    install -m 0644 "$UNIT_SRC" "$UNIT_DST"
    log "installed systemd unit -> $UNIT_DST"

    systemctl --user daemon-reload
    systemctl --user enable --now dock-monitor-toggle.service
    log "enabled + started dock-monitor-toggle.service"
    log "  -> check it with: journalctl --user -u dock-monitor-toggle -f"
else
    log "systemd --user not available; falling back to Hyprland exec-once"
    EXEC_LINE="exec-once = $SCRIPT_DST"

    if [[ -f "$EXECS_FILE" ]]; then
        if grep -Fq "$EXEC_LINE" "$EXECS_FILE"; then
            log "exec-once line already present in $EXECS_FILE"
        else
            printf '\n%s\n' "$EXEC_LINE" >> "$EXECS_FILE"
            log "appended exec-once line to $EXECS_FILE"
        fi
    else
        cat <<EOF

  No $EXECS_FILE found.
  Add the following line to your Hyprland config manually:

      $EXEC_LINE

EOF
    fi
fi

log "done. dock/undock to test, or restart Hyprland to apply at session level."
