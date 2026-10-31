# Session: login manager, systemd, `wmaker-wl-session`

## Install

```sh
zig build -Doptimize=ReleaseSafe
sudo zig build install -p /usr          # DESTDIR=... works for packages
```

`zig build install` installs the programs and the whole session:

| file | goes to |
|---|---|
| `wmaker-wl`, `wlprefs` | `bin/` |
| `wmaker-wl-session` | `bin/` |
| `wmaker-wl.desktop` | `share/wayland-sessions/` |
| `wmaker-wl.service`, `wmaker-wl-shutdown.target` | `lib/systemd/user/` |
| `wmaker-wl-portals.conf` | `share/xdg-desktop-portal/` |
| `wlprefs.desktop` | `share/applications/` |
| `Themes/*.lua` | `share/wmaker-wl/Themes/` |

The `.desktop` file and the unit contain the absolute path of `bin/`.

### Fallback: from the binary

For a build that did not go through `zig build install`:

```sh
sudo ./zig-out/bin/wmaker-wl --install-session            # /usr/local (/usr if run from /usr/bin)
sudo ./zig-out/bin/wmaker-wl --install-session --prefix /usr
./zig-out/bin/wmaker-wl --install-session --user          # ~/.local
wmaker-wl --session-status                                # what is installed, what differs
sudo wmaker-wl --uninstall-session                        # the session files, not the programs
```

`--dry-run` only reports, `--destdir DIR` stages below `DIR`. Running it again repairs
changed files and leaves current ones alone. It also copies `wmaker-wl` and `wlprefs` into
`bin/` when they are not there yet. Most login managers read only `/usr/share/wayland-sessions`
or `/usr/local/share/wayland-sessions`, so `--user` is for TTY use.

## What `wmaker-wl-session` does

1. sets `XDG_SESSION_TYPE`, `XDG_SESSION_DESKTOP`, `XDG_CURRENT_DESKTOP`
2. without a terminal, logs to `~/.local/state/wmaker-wl/session.log` (one old log is kept)
3. reads `~/.config/wmaker-wl/env` (plain sh, e.g. `export XKB_DEFAULT_LAYOUT=de`); a file with
   a syntax error is skipped with a message
4. finds `XDG_RUNTIME_DIR` (`/run/user/UID`) or stops with a clear message
5. starts the compositor:
   - **with systemd**: `systemctl --user start wmaker-wl.service` (`Type=notify`; the
     compositor sends `READY=1` once its socket and the environment import are done), so
     `graphical-session.target` and units bound to it follow; when the compositor ends,
     `wmaker-wl-shutdown.target` stops them again. Log: `journalctl --user -u wmaker-wl`
   - **without**: `wmaker-wl` directly, under `dbus-run-session` if there is no session bus

`WMAKER_NO_SYSTEMD=1` forces the second way, `WMAKER_WL=/path` runs another compositor binary
(also without systemd).

## From a TTY

```sh
wmaker-wl-session        # or just wmaker-wl
```

## Troubleshooting

- not listed in the login manager: `wmaker-wl --session-status`; try `--prefix /usr`
- black screen / back at the login: read `~/.local/state/wmaker-wl/session.log`
  and `journalctl --user -u wmaker-wl -b`
- portals: `wmaker-wl-portals.conf` prefers the GTK backend for everything; adjust it in
  `~/.config/xdg-desktop-portal/wmaker-wl-portals.conf`
