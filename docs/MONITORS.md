# Multiple monitors

What wmaker-wl does with external monitors, what it cannot do, and how to set it up. The logic is in
`src/monitors.zig`; the connection to wlroots is in `src/output.zig`.

## What wmaker-wl does

Every output wlroots announces gets its preferred mode and a place on the desk (`wlr_output_layout`).
wmaker-wl does not change modes, scale or arrangement yet: tools do that through
`wlr-output-management` (kanshi, wlr-randr, wdisplays), once that protocol is served. Until then wmaker-wl
does two things:

1. It recognises monitors (connector such as `DP-1`, make, model, description) through the wlroots output, and then manages windows and workspaces per monitor.
2. It starts the right tool when exactly a given set of monitors is connected (`monitor_profile`).

## What happens automatically

- **Debouncing.** Plugging in a dock with three screens makes wlroots report output, position and size one
  after another, three times. A change only counts after `monitor_settle_ms` (default 400 ms) without
  another one, and only then are rules applied.
- **Windows remember their monitor.** When a monitor disappears, its windows move to the primary monitor
  (same workspace index) and remember where they came from. When the monitor comes back (same identity,
  same connector) they return. Moving a window yourself clears that memory.
- **Order by position.** `focus_output_next` / `focus_output_prev` go left to right
  (`output_order = "position"`), not in the order the monitors were announced. `"connection"` gives that
  old behaviour back.
- **Primary monitor.** New windows, the Dock and the Clip go there unless something else decides.
- The only connected monitor can never be disabled.

## Configuration (`config.lua`)

```lua
output_order = "position"      -- position | connection
monitor_settle_ms = 400

-- A name is a connector ("DP-1"), "make model", part of the description, or "*".
-- The most specific rule wins; on a tie, the one written last.
monitor("DP-1",  { primary = true, workspaces = 6, start_workspace = 1 })
monitor("eDP-1", { enabled = false })                     -- ignore the laptop screen
monitor("*",     { on_connect = "notify-send 'monitor connected'",
                   on_disconnect = { "notify-send", "monitor gone" } })

-- When exactly these monitors are present, run this tool:
monitor_profile{ name = "docked", needs = { "eDP-1", "DP-1" },
                 run = "kanshictl switch docked" }
monitor_profile{ name = "mobile", needs = { "eDP-1" }, exact = true,
                 run = "kanshictl switch mobile" }
```

| Key | Meaning |
|---|---|
| `enabled` | `false`: the monitor is ignored and its windows move away |
| `primary` | default target for new windows, Dock and Clip |
| `workspaces` | number of workspaces on this monitor (default `workspace_count`) |
| `start_workspace` | workspace shown when the monitor is connected (1-based) |
| `restore_windows` | `false`: windows do not return (default `true`) |
| `on_connect` / `on_disconnect` | command (string or list), started detached |

For profiles, `needs` has one name per required monitor. Each monitor satisfies at most one name, even
when `"*"` is among them. `exact = true` requires that no other monitor is connected. Of several matching
profiles, the one with the most `needs` wins, then one with `exact`, then the one written last. A profile
runs **once per set of monitors**, not on every event, so a mode change or a reload does not start it
again. Misspelled keys produce a warning.

## Looking at the state

```
pkill -USR1 wmaker-wl     # state dump -> $XDG_RUNTIME_DIR/wmaker-wl-state.txt
```

For each output the dump shows identity, key (`key=`), `primary` / `disabled` / `[working]`, the rules,
the profile chosen last, and for windows `home=<key>/wsN`. See [DEBUGGING.md](DEBUGGING.md).

## Not done

- `focus_output_left/right/up/down` and moving a window to the neighbouring monitor. The neighbour search
  (`types.outputToward`, `monitors.neighbor`) exists and is tested; the commands themselves are missing.
- Setting modes, scale and position directly through `wlr-output-management` instead of only running hook
  commands.
- Dock and Clip per monitor, and separate workspace names per monitor.
- Real hotplug testing. Everything is tested on the model, not against a running compositor with a monitor
  actually being plugged in and out.