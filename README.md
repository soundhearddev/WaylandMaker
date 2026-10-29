# WaylandMaker

A Wayland window manager that tries to feel like [Window Maker](https://www.windowmaker.org/).
It is a Wayland compositor of its own, built on [wlroots](https://gitlab.freedesktop.org/wlroots/wlroots)
0.20: it does compositing, input, layout and focus. The root menu, the Dock and the Clip are being ported
to it (see [docs/TODO wlroots.md](docs/TODO%20wlroots.md); the old drawing code is kept in `attic/`).

Windows are laid out in a horizontally scrolling strip of columns (the niri / PaperWM idea), in a
NeXTSTEP-style look. The parts of Window Maker I care about most are kept as they were: the root menu,
Dock, Clip and DockApps, and the `WMRootMenu`, `WMWindowAttributes` and `WMState` files.


## Build

Needs Zig **0.16.0**, **wlroots 0.20** and the development files for wayland, wayland-protocols,
xkbcommon and pixman (on Debian: `libwlroots-0.20-dev libwayland-dev wayland-protocols libxkbcommon-dev
libpixman-1-dev`; wayland-protocols older than 1.44 needs `-Dcolor-manager-version=1`). wlprefs also
needs cairo, pango and glib. Lua 5.4 is built from source as a Zig dependency, so no system Lua is needed.

```sh
zig build                                # wmaker-wl and wlprefs into zig-out/bin
zig build test                           # unit tests, no compositor needed
zig build probe                          # can wlroots be used on this machine at all?
zig build run                            # nested in the current session (WLR_BACKENDS=wayland)
./zig-out/bin/wmaker-wl                  # from a TTY: DRM + libinput, no other session needed
```

Nix and Scheme files are provided for Nix and Guix users.

## Configuration

The config is a Lua script: `$XDG_CONFIG_HOME/wmaker-wl/config.lua`, else
`~/.config/wmaker-wl/config.lua`. It runs on top of the built-in
[`src/share/default_config.lua`](src/share/default_config.lua), so you only write what you want to change.
To start from a full copy: `wmaker-wl --print-config > ~/.config/wmaker-wl/config.lua`.

## Default key bindings

| Key | Action |
|---|---|
| `Super+Return` / `a` / `b` | terminal / launcher / browser |
| `Super+h j k l`, arrow keys | focus left / down / up / right |
| `Super+Shift+h l`, `Shift+arrows` | move column |
| `Super+Shift+j k` | move window down / up within its column |
| `Super+,` / `Super+.` | stack the window into the column on its left / push it out into a new column on its right |
| `Super+[` / `]` | scroll the view |
| `Super+c` | center column |
| `Super+r`, `-`, `=` | cycle, narrow, widen the column |
| `Super+d` | maximize column |
| `Super+t` | toggle tiling / floating |
| `Super+f` | fullscreen |
| `Super+1…4`, `Shift` to take the window along | workspace |
| `Super+Page_Up` / `Page_Down` | previous / next workspace |
| `Super+n`, `Super+Shift+n` | minimize, restore the last minimized window |
| `Super+Alt+Left` / `Right` | focus previous / next monitor (`Shift` moves the window) |
| `Super` + left / right mouse button | move / resize a window |
| `Super+q` | close window |
| `Super+Shift+e` | exit |

## Command line

```
wmaker-wl [OPTION]       without an option: start the session
  -h, --help             show the options
  -V, --version          show the version
      --config FILE      read FILE instead of the default config.lua
      --config-dir DIR   use DIR instead of ~/.config/wmaker-wl
      --check            check config.lua, key bindings, root menu, window attributes and WMState
                         (exit 0: fine, 1: problems)
      --paths            list the files wmaker-wl reads and which of them exist
      --binds            list the key bindings in effect (also on Super+/ in a session)
      --print-config     print the built-in default config.lua
      --log SPEC         log filter, e.g. info,anim=debug (same as WMAKER_LOG)
```

An unknown option is an error and does not start a session.

## Documentation

| | |
|---|---|
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | how the code is organised and the rules it follows |
| [docs/INTEGRATION.md](docs/INTEGRATION.md) | what is taken from Window Maker, and what is not |
| [docs/DOCKAPPS.md](docs/DOCKAPPS.md) | Dock, Clip, Drawers, writing a DockApp |
| [docs/MONITORS.md](docs/MONITORS.md) | multiple monitors and hotplug |
| [docs/THEMES.md](docs/THEMES.md) | the look: colours, fonts, `theme("nord")` |
| [docs/WMPREFS.md](docs/WMPREFS.md) | `wlprefs`, the settings window |
| [docs/DEBUGGING.md](docs/DEBUGGING.md) | logging, state dump, tests, benchmark |
| [docs/TODO.md](docs/TODO.md) | open work |

`examples/` has two small DockApps, `wl-clock` and `wl-battery`, which also serve as templates.

## Credits and license

Window Maker is the model for almost everything visible here, and much of the Dock logic follows its
`dock.c`. [wlmaker](https://github.com/phkaeser/wlmaker) was a reference for menu names and dimensions.
The animation curves come from [niri](https://github.com/YaLTeR/niri).

GPL-3.0, see [LICENSE](LICENSE).