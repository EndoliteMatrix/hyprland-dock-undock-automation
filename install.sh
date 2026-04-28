#!/usr/bin/env bash
# Installer for dock-monitor-toggle.
#
# Copies the watcher script and config template into your Hyprland config tree,
# wires it into exec-once, and optionally starts it now if Hyprland is running.

set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HYPR_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/hypr"
SCRIPTS_DIR="$HYPR_DIR/custom/scripts"
TARGET_SCRIPT="$SCRIPTS_DIR/dock-monitor-toggle.sh"
TARGET_CONF="$SCRIPTS_DIR/dock-monitor-toggle.conf"
EXEC_FILE="$HYPR_DIR/custom/execs.conf"

say()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!! \033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx \033[0m %s\n' "$*" >&2; exit 1; }

# --- prerequisite checks -----------------------------------------------------
[ -d "$HYPR_DIR" ] || die "no Hyprland config dir at $HYPR_DIR — is Hyprland installed?"
for cmd in hyprctl jq socat bash grep sed; do
    command -v "$cmd" >/dev/null || die "missing dependency: $cmd"
done

# --- copy the script ---------------------------------------------------------
mkdir -p "$SCRIPTS_DIR"
install -m 755 "$SRC_DIR/dock-monitor-toggle.sh" "$TARGET_SCRIPT"
say "installed script -> $TARGET_SCRIPT"

# --- copy config template (only if no existing config) -----------------------
if [ -f "$TARGET_CONF" ]; then
    say "kept existing config -> $TARGET_CONF"
else
    install -m 644 "$SRC_DIR/dock-monitor-toggle.conf.example" "$TARGET_CONF"
    say "wrote config template -> $TARGET_CONF"
    warn "EDIT THIS FILE before first run. Find your monitor IDs with:"
    printf '       hyprctl monitors -j | jq '\''.[] | {name, description}'\''\n'
fi

# --- wire exec-once ----------------------------------------------------------
EXEC_LINE="exec-once = $TARGET_SCRIPT"

if [ -f "$EXEC_FILE" ]; then
    if grep -qF "dock-monitor-toggle.sh" "$EXEC_FILE"; then
        say "exec-once already present in $EXEC_FILE"
    else
        printf '\n# Auto-toggle internal laptop panel based on external dock presence.\n%s\n' "$EXEC_LINE" >> "$EXEC_FILE"
        say "appended exec-once -> $EXEC_FILE"
    fi
else
    warn "$EXEC_FILE not found. Add this to a sourced Hyprland config file:"
    printf '       %s\n' "$EXEC_LINE"
fi

# --- offer to start the watcher now ------------------------------------------
if [ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
    if [ -s "$TARGET_CONF" ] && grep -qE '^INTERNAL_DESC=.+' "$TARGET_CONF" && ! grep -qE "0xABCD|Acme Corp DockMonitor" "$TARGET_CONF"; then
        printf '\nStart the watcher now via Hyprland? [Y/n] '
        read -r yn
        case "${yn:-Y}" in
            [Yy]*|'')
                hyprctl dispatch exec "$TARGET_SCRIPT" >/dev/null
                say "started watcher under Hyprland (logs at \$XDG_STATE_HOME/dock-monitor-toggle.log or ~/.local/state/dock-monitor-toggle.log)"
                ;;
        esac
    else
        warn "config still has placeholder values — edit $TARGET_CONF, then run:"
        printf '       hyprctl dispatch exec %s\n' "$TARGET_SCRIPT"
    fi
else
    say "Hyprland not currently running — watcher will start automatically on next login via exec-once."
fi

# --- monitors.conf invariant reminder ----------------------------------------
cat <<'EOF'

[!] monitors.conf invariant
    Keep your internal panel ENABLED in monitors.conf (e.g.
    `monitor=desc:Your Laptop Panel,3200x2000@120,0x0,1.33`), NOT `disable`.
    The watcher flips it OFF at runtime when the dock is detected. If
    monitors.conf disables the panel, an undocked boot can land you in a
    black-screen state if the watcher is slow or fails.

    If you use nwg-displays: save your config WHILE UNDOCKED so it persists
    a real internal-panel line. Saving while docked writes `disable` for
    the panel and breaks this invariant.
EOF
