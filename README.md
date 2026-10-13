# WaylandMaker (`wmaker-wl`)

Scrollable tiling with floating windows for [river](https://codeberg.org/river/river) using `river_window_management_v1`, inspired by niri and Window Maker.

## Default Keybindings

| Key | Action |
|---|---|
| `Super+Return` / `a` / `b` | Terminal / Launcher / Browser |
| `Super+h l j k` / Arrow keys | Focus |
| `Super+Shift+h l` | Move column |
| `Super+[` / `]` | Scroll view |
| `Super+r`, `-`, `=` | Column width |
| `Super+t` | Tiling ↔ Floating |
| `Super+f` | Fullscreen |
| `Super+1…4` (+Shift) | Switch workspace / Move window |
| `Super` + Left/Right mouse | Move / Resize window |
| `Super+q` / `Super+Shift+e` | Close window / Exit |

Keybindings can be changed in `~/.config/wmaker-wl/config.lua` (template: `src/share/default_config.lua`).

## Configuration

The config is a **Lua script**: `$XDG_CONFIG_HOME/wmaker-wl/config.lua`, else `~/.config/wmaker-wl/config.lua`.
It runs on top of the built-in `src/share/default_config.lua`, so you only write what you want to change:

```lua
gap = 10
clip_corner = "bottom_right"
bind("Super+Shift+h", "move_column_left")
unbind("Super+q")
```

- Every global you set is an option; an unknown name or a bad value is a warning in the log (typos do not go
  unnoticed), a Lua error ends the script at that line and keeps what ran before it. The session always starts.
- `include("FILE")` and `theme("NAME")` (`Themes/NAME.lua`) work as described in `default_config.lua`.
- Reload without restarting: `pkill -HUP wmaker-wl`.
- The old `config.conf` (`key = value`) is **not read any more**; wmaker-wl logs a warning if one is still lying around.
- Dock/Clip: what you change with the mouse is saved in `$XDG_STATE_HOME/wmaker-wl/WMState`
  (`~/.local/state/wmaker-wl/WMState`). Options that **your `config.lua` names itself** (`dock_edge`, `dock_offset`,
  `dock_on_top`, `dock_auto_raise`, `clip_corner`, `clip_on_top`, `clip_collapsed`, `clip_auto_collapse`,
  `clip_auto_raise`) win over that saved state; everything you leave out follows the saved state. To let the mouse
  decide again, delete the line from `config.lua`.

## Build

Requires Zig **0.16.0**, `libwayland-dev`, `libxkbcommon-dev`, and, for the root menu's cairo/pango
rendering, `libcairo2-dev`, `libpango1.0-dev`, and `libglib2.0-dev` 

```sh
zig build
zig build test
river -c ./zig-out/bin/wmaker-wl
```

Window Maker's **Dock** (a column of tiles on a screen edge; `dock_size`, 64 px by default) and **Clip** (workspace tile with arrows,
plus per-workspace launchers) are built in; configure them with the `dock_*` / `clip_*` options in
`config.lua`; the tiles themselves live in the `WMState` property list (`$XDG_STATE_HOME/wmaker-wl/WMState`, or an
existing Window Maker `~/GNUstep/Defaults/WMState`).

Also built in: minimize/hide (`minimize`, `restore`, `show_all`, `hide_others`), several monitors
(`focus_output_*`, `move_to_output_*`), themes (`theme = NAME`, `include = FILE`), XPM icons for Dock tiles,
`OPEN_MENU` for directories and menu files, scrolling menus, and `bind_layout` / umlaut key names for
non-US keyboards. See `docs/TODO.md` for what is done and what is not.

**wlprefs** is the settings window (modelled on Window Maker's WPrefs.app): `zig-out/bin/wlprefs`.
It reads and writes `~/.config/wmaker-wl/config.lua` (the same file wmaker-wl loads) and changes only the lines of the
keys you change. See [`docs/WMPREFS.md`](docs/WMPREFS.md); `zig build test-wlprefs` runs its tests.

See [`docs/ARCHITECTURE.md`](https://github.com/soundhearddev/WaylandMaker/blob/main/docs/ARCHITECTURE.md) for the architecture, and [`docs/DOCKAPPS.md`](https://github.com/soundhearddev/WaylandMaker/blob/main/docs/DOCKAPPS.md) for how DockApps, the Dock and the Clip work (`WMState`).