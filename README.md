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

Keybindings can be changed in `~/.config/wmaker-wl/config.conf` (template: `src/default_config.conf`).

## Build

Requires Zig **0.16.0**, `libwayland-dev`, `libxkbcommon-dev`, and, for the root menu's cairo/pango
rendering, `libcairo2-dev`, `libpango1.0-dev`, and `libglib2.0-dev` 

```sh
zig build
zig build test
river -c ./zig-out/bin/wmaker-wl
```

Window Maker's **Dock** (a column of 64 px tiles on a screen edge) and **Clip** (workspace tile with arrows,
plus per-workspace launchers) are built in; configure them with the `dock_*` / `clip_*` options in
`config.conf` and the entries in `~/.config/wmaker-wl/dockapps.conf` (or an existing `WMState`).

Also built in: minimize/hide (`minimize`, `restore`, `show_all`, `hide_others`), several monitors
(`focus_output_*`, `move_to_output_*`), themes (`theme = NAME`, `include = FILE`), XPM icons for Dock tiles,
`OPEN_MENU` for directories and menu files, scrolling menus, and `bind_layout` / umlaut key names for
non-US keyboards. See `docs/TODO.md` for what is done and what is not.

**wlprefs** is the settings window (modelled on Window Maker's WPrefs.app): `zig-out/bin/wlprefs`. It edits
`~/.config/wmaker-wl/config.conf` in place -- only the keys you change, comments and `bind` lines stay -- and tells
a running wmaker-wl to reload. See [`docs/WMPREFS.md`](docs/WMPREFS.md); `zig build test-wlprefs` runs its tests.

See [`docs/ARCHITECTURE.md`](https://github.com/soundhearddev/WaylandMaker/blob/main/docs/ARCHITECTURE.md) for the architecture, and [`docs/DOCKAPPS.md`](https://github.com/soundhearddev/WaylandMaker/blob/main/docs/DOCKAPPS.md) for how to define DockApps (`~/.config/wmaker-wl/dockapps.conf`).