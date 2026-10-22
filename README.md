# WaylandMaker (`wmaker-wl`)

Window Maker brought to the modern age: a scrolling column layout in the NeXTSTEP look, with window animations, using River as backend.

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
| `Super+n` / `Super+Shift+n` / `Super+Shift+m` | Minimize / Restore last / Dock tiles of minimized windows on-off |

## Animations

Windows slide to their new place (scrolling, a column opens, closes or is resized) and a new window is uncovered from its middle. The curves are ported from niri. Options in `config.lua`: `animations`, `anim_slowdown`, `anim_window_movement`, `anim_window_open` (see `src/share/default_config.lua`). The closing window itself is not animated: river drops it before the compositor can.

Keybindings can be changed in `~/.config/wmaker-wl/config.lua` (template: `src/share/default_config.lua`).

## Configuration

The config is a **Lua script**: `$XDG_CONFIG_HOME/wmaker-wl/config.lua`, else `~/.config/wmaker-wl/config.lua`.
It runs on top of the built-in `src/share/default_config.lua`, so you only write what you want to change:

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

