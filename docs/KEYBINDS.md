# Key bindings

Everything about keys is in `config.lua`. `wmaker-wl --binds` lists what is in effect;
inside the session `Super+/` (or `Super+F1`) shows the same list in a terminal.

## Writing a bind

```lua
bind("Super+Return", "spawn_terminal")           -- a command of wmaker-wl
bind("Super+Shift+s", "shell grim -g \"$(slurp)\" - | wl-copy")   -- any shell line
bind("XF86AudioMute", "shell wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle")   -- no modifier needed
bind("Super+F5", function() run("workspace 2") shell("notify-send hi") end)  -- Lua
unbind("Super+q")                                -- remove a default
```

A bind replaces a default on the same key combination. Keys are xkb keysym names
(`Return`, `Left`, `XF86AudioPlay`, `Print`) or the character itself (`ü`).
Modifiers: `Super`, `Shift`, `Ctrl`, `Alt`, `Mod3`, `Mod5`. What a bind does not
name must not be held: `Super+q` does not fire on `Super+Shift+q`.

`bind_layout = 0` pins every bind to the first keyboard layout, so `Super+q` stays
the same physical key after switching between `us` and `de`.

## Repeat

| option | default | |
|---|---|---|
| `repeat_rate` | 25 | keys per second, `0` turns repeat off (for clients and binds) |
| `repeat_delay` | 600 | ms until the repeat starts |
| `repeat_binds` | true | binds that move around repeat while held |

These repeat: `focus_*`, `move_column_*`, `move_window_*`, `scroll_*`, `widen_column`,
`narrow_column`, `float_move`, `float_resize`, `focus_window_or_workspace_*`,
`focus_column_or_output_*`, and the volume and brightness keys (`XF86Audio{Raise,Lower}Volume`,
`XF86{Mon,Kbd}Brightness{Up,Down}`) with at most ten program starts per second.
Opening programs, `close`, `exit` and toggles never repeat.

## The keyboard layout

The layout is read from `XKB_DEFAULT_*` when a keyboard appears:

```lua
environment = { XKB_DEFAULT_LAYOUT = "de", XKB_DEFAULT_OPTIONS = "caps:escape" }
-- two layouts, Alt+Shift switches:
-- environment = { XKB_DEFAULT_LAYOUT = "us,de", XKB_DEFAULT_OPTIONS = "grp:alt_shift_toggle" }
```

or `export XKB_DEFAULT_LAYOUT=de` in `~/.config/wmaker-wl/env` (read by `wmaker-wl-session`).
A layout change needs a new session (a reload does not re-create the keymap).

## Autostart

`spawn_at_startup` in `config.lua` is the autostart: programs started once when the session
comes up (never on `Super+Shift+r`). There is no separate autostart file.

```lua
spawn_at_startup = {
    "mako",                                   -- a string is split like a command line (no shell)
    "nm-applet --indicator",
    { "swaybg", "-i", "/home/me/wall.png" },  -- a table is the argv
    { "sh", "-c", "wl-paste --watch cliphist store" },   -- a shell line: use sh -c
}
table.insert(spawn_at_startup, "blueman-applet")
```

Order: `environment` is set; with `import_environment = true` (default) `WAYLAND_DISPLAY`,
`XDG_CURRENT_DESKTOP`, `XDG_SESSION_TYPE` and the names in `environment` are given to D-Bus and
`systemd --user` (`dbus-update-activation-environment --systemd`), because programs started by
D-Bus (portals, notification daemons) otherwise cannot find the compositor; then the programs start.
A program that cannot be started is a warning in the log. DockApps with `AutoLaunch = Yes` in
WMState start as before.

## What does not work yet (and is not a key problem)

Programs that need protocols the compositor does not serve yet are missing from the
defaults on purpose: a screen locker (`ext-session-lock`), screenshots with `grim`
(`wlr-screencopy`; the `Super+p` bind is there for when it comes), clipboard managers
(`wlr-data-control`), bars and wallpapers (`wlr-layer-shell`). See `docs/TODO wlroots.md`, section 5.