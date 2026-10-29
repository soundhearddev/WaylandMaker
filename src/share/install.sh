#!/bin/sh
# Set up wmaker-wl for the current user, and optionally install the session.
#
#   ./install.sh            config + env in ~/.config/wmaker-wl (nothing is overwritten)
#   sudo ./install.sh --system   also install the binaries and the login-manager entry
#
# Build first!!!
set -eu

here=$(cd "$(dirname "$0")" && pwd)
cfg="${XDG_CONFIG_HOME:-$HOME/.config}/wmaker-wl"
share="$here/src/share"

mkdir -p "$cfg"

if [ ! -e "$cfg/config.lua" ]; then
    if [ -x "$here/zig-out/bin/wmaker-wl" ]; then
        "$here/zig-out/bin/wmaker-wl" --print-config > "$cfg/config.lua"
    else
        cp "$share/default_config.lua" "$cfg/config.lua"
    fi
    echo "created $cfg/config.lua"
else
    echo "kept    $cfg/config.lua"
fi

if [ ! -e "$cfg/env" ]; then
    cat > "$cfg/env" <<'ENV'
# Read by wmaker-wl-session before the compositor starts. Plain sh.
# Keyboard layout:
# export XKB_DEFAULT_LAYOUT=de
# export XKB_DEFAULT_OPTIONS=caps:escape
ENV
    echo "created $cfg/env"
fi

if [ "${1:-}" = "--system" ]; then
    [ "$(id -u)" -eq 0 ] || { echo "--system needs root (sudo)" >&2; exit 1; }
    install -Dm755 "$here/zig-out/bin/wmaker-wl" /usr/local/bin/wmaker-wl
    [ -x "$here/zig-out/bin/wlprefs" ] && install -Dm755 "$here/zig-out/bin/wlprefs" /usr/local/bin/wlprefs
    install -Dm755 "$share/wmaker-wl-session" /usr/local/bin/wmaker-wl-session
    install -Dm644 "$share/wmaker-wl.desktop" /usr/share/wayland-sessions/wmaker-wl.desktop
    install -Dm644 "$share/wlprefs.desktop" /usr/share/applications/wlprefs.desktop
    mkdir -p /usr/share/wmaker-wl/Themes
    cp "$share"/Themes/*.lua /usr/share/wmaker-wl/Themes/
    echo "installed to /usr/local and /usr/share; pick WaylandMaker in your login manager"
fi

echo
echo "check your config:   wmaker-wl --check"
echo "list key bindings:   wmaker-wl --binds | less      (in the session: Super+/)"