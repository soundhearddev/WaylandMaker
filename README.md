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

See [`docs/ARCHITECTURE.md`](https://github.com/soundhearddev/WaylandMaker/blob/main/docs/ARCHITECTURE.md) for the architecture.