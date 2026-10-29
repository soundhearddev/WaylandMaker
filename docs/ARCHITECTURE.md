# Architecture

`wmaker-wl` is a Wayland compositor on [wlroots](https://gitlab.freedesktop.org/wlroots/wlroots) 0.20.
It composites, handles input, and decides where windows go and what has focus. This page is a map of the
source.

## Source layout

Everything is in `src/` unless noted. **Model** files do not import wlroots and are tested without a
display. **Compositor** files talk to wlroots.

| File | What it does | Kind |
|---|---|---|
| `types.zig` | data model, commands | model |
| `layout.zig` | geometry: columns, scrolling, floating | model |
| `workspace.zig` | every change to the window tree | model |
| `action.zig` | parses and runs commands (key bindings, menu entries) | model |
| `motion.zig` | where a window is *drawn*: movement spring, opening animation, clip box | model |
| `animation.zig` | spring and easing curves, parsing `anim_window_*` | model |
| `monitors.zig` | monitor identification, rules, profiles, hotplug decisions | model |
| `dock_model.zig` | Dock, Clip and Drawers: tiles, slots, grid, temporary tiles, geometry, hit testing | model |
| `dock_view.zig` | what each Dock tile looks like (`Look`, cached by key) and what changed between two plans (`diff`); the contract for drawing, see `DOCK.md` | model |
| `dockhost.zig` | DockApps (`dockapp:<name>`): adoption, tiles that follow the programs, the room the Dock reserves, where each DockApp goes | model |
| `outputs.zig` | what follows from a monitor coming or going: windows move away and come back (`home`), `monitor()` rules, profile after the settle time | model |
| `config.zig`, `lua.zig`, `share/default_config.lua` | Lua config and its defaults | model |
| `style.zig` | the look (palette and fonts) taken from the config once per load; read by the drawing code, see [THEMES.md](THEMES.md) | model |
| `plist.zig`, `wm_menu.zig`, `wm_attr.zig`, `wm_files.zig` | Window Maker files: property lists, root menu, `WMWindowAttributes`, where files live | model |
| `wm_dock.zig`, `dockapp.zig` | Dock and Clip logic and data, `WMState` read/write | model |
| `process.zig` | starts commands detached from the compositor | model |
| `log.zig`, `trace.zig`, `perf.zig`, `invariants.zig`, `diag.zig`, `dump.zig` | logging and debugging, see [DEBUGGING.md](DEBUGGING.md) | model |
| `model.zig` | one import for the whole model | model |
| `backend.zig` | the opaque handles the model keeps of compositor objects, and the two calls it makes back (`manageDirty`, `closeWindow`) | model |
| `manage.zig` | the **manage pass**: places new windows, runs queued commands, decides focus, lays out, tells a `Sink` what to do | model (against a `Sink`) |
| `keys.zig` | which bind a key press triggers | model |
| `pointer_op.zig` | moving and resizing with the pointer (`idle → requested → running → ending`) | model |
| `boot.zig` | loading the model from the config, `environment`, SIGCHLD | model |
| `cli.zig` | the command line | model |
| `main.zig` | startup, `--check`, `--paths`, `--print-config` | compositor |
| `server.zig` | wlroots objects, protocol globals, event loop, signals; implements the `Sink` | compositor |
| `output.zig` | one monitor: wlroots output, scene output, its model `Output` | compositor |
| `view.zig` | an xdg toplevel (and its popups) and its scene nodes | compositor |
| `keyboard.zig`, `cursor.zig` | input devices, bind dispatch, hit testing, click and hover focus | compositor |
| `probe.zig` | `zig build probe`: can wlroots be used here at all | compositor |
| `root.zig` | the test root; its `test { }` block is the list of test files | – |
| `*_test.zig`, `bench.zig` | tests and the benchmark | – |
| `../wlprefs/` | the settings program, a separate Wayland client | – |
| `../attic/` | the root menu, Dock, Clip and drawing code of the river build; not built, to be ported | – |

Anything that changes the model can be tested without a compositor, and so can the whole manage pass:
`outputs.zig` runs inside the manage pass; the compositor only reports monitors and arms a timer (`server.armSettleTimer`) so the rules apply after `monitor_settle_ms`.

`manage.zig` works against a `Sink` (configure a window, place it, focus it), and its tests use a fake.

### Registering tests

Zig only runs the tests of a file if the test root refers to it, and an unused `pub const x = @import(...)`
does not count. So every file with `test` blocks is named in one `test { }` block, one line each:

```zig
_ = @import("name.zig");
```

- **wmaker-wl:** `src/root.zig`. This is the only place to touch for a new test file. The test module
  does not link wlroots, so `zig build test` runs on a machine without it.
- **wlprefs:** `wlprefs/src/root.zig`, same convention. It is a separate module with its own Wayland
  bindings, so its tests cannot be listed in `src/root.zig`; `zig build test` runs both anyway.
- **Examples:** the `main.zig` of each example. They are separate projects, run by `zig build test-all`.

A test file that is missing from its list silently never runs. Nothing checks this automatically.

## Event flow

```text
events (map, unmap, key, button, output change, SIGHUP, ...)
   │   edit the model, then `backend.manageDirty`
   ▼
idle callback ──▶ manage.run(wm, sink, now)       once per turn of the event loop
                    reap · reload · place new windows · run queued commands
                    · focus · layout · animate
                         │
                         ▼
                    Sink: configure (xdg), place (scene nodes, borders, clip), focus (seat)
                         │
                         ▼
                    animation still running? ask for the next frame; the monitor's frame
                    event runs the next pass
```

- There is **one** place that changes model state in response to input: `manage.run`. Event handlers only
  record what happened (a key press queues its command, a click requests focus, a client's `maximize`
  request edits one column) and ask for a pass. Passes never nest, and there is at most one per turn of the
  event loop, after all events of that turn.
- Key presses are matched in `keys.zig` against `cfg.binds` (the keysym at level 0 of the active or pinned
  layout, plus modifiers; Caps and Num Lock do not count). A matched press and its release are not given
  to the client. `XF86Switch_VT_n` switches terminals regardless of the binds.
- A pass changes only what changed: `View.place` skips a window whose placement, geometry and colours are
  the same as last time, and `manage.applyManage` sends a configure only for a changed size, tiled or
  fullscreen state.
- Animations (`motion.zig`) are sampled once per pass, and a pass runs once per displayed frame while
  something still moves, paced by the monitor's frame callback. When nothing moves, nothing runs.
- A window exists in the model only while its toplevel is mapped. `map` creates the `Window`, `unmap` and
  `destroy` close it, and the next pass frees it (`manage.reapWindows`). The `View` belongs to the
  toplevel and lives as long as it does.
- A seat that had a closing window focused is told at once (`manage.forgetWindow`): by the next pass the
  model no longer remembers that the compositor still points at it.

## Data model

```text
Output ─ workspaces[N] ─ Workspace
                          ├─ strip    ─ Column ─ Window      (tiled)
                          ├─ floating ─ Window ...            (z-order, top = most recent)
                          └─ fullscreen: ?*Window
```

Invariants (kept by `workspace.zig`, checked in `model_test.zig` and, with `WMAKER_CHECKS=1`, at run time):

1. Every window is in exactly one container (`Window.mode`).
2. A column is never empty; it is destroyed with its last window.
3. A window changes between tiled and floating only through `floatWindow` / `tileWindow`. Going back uses
   the remembered column index and width, never a pointer to a column that may be freed.
4. Fullscreen is a display state on top of the container; the window stays in its column and the strip
   keeps its shape.
5. `wl.list.Link.remove()` dereferences `prev` and `next`. Unlinked links hold `null`, and removal only
   goes through `types.unlink()`.

DockApp windows are the exception to 1: they are moved out of `wm.windows` into `wm.dock_windows` (see
[DOCKAPPS.md](DOCKAPPS.md)).

## Layout

- Column width is `w = f·(avail + gap) − gap`, so 1/2 + 1/2 and 1/3 + 1/3 + 1/3 fit exactly.
- Windows in a column fill its height; leftover pixels are distributed.
- A maximized active column locks the view (`layout.lockMaximized`, `maximize_follow`) on every pass.
- The view (`scroll_x`) is clamped on every layout pass and follows the active column when focus changes
  (`center_focused_column`).
- Borders sit outside the content area; the layout subtracts them from the slot.
- Windows are kept inside the output's usable area (`Output.usable`; layer-shell panels will set it).

## Mouse (Super+left = move, Super+right = resize)

States: `idle → requested → running → ending → idle` (`types.OpState`).

- `op_delta` is cumulative since the start. Geometry is always `start + delta`, never `+=`.
- A tiled window leaves the strip only after being dragged `drag_threshold` pixels.
- An operation starts at a pass boundary (`requested → running`) with the window's geometry of that
  moment; if the button is released before then, it is cancelled on the spot.
- If a window dies during an operation, the state goes `running → ending`, so the pointer is not left
  grabbed.
- Client requests (`xdg_toplevel.move` / `resize`, valid only while a button is held) go through the same
  state machine. While one runs, motion only changes the distance from where it began; clients see no
  pointer events.

## Focus and workspaces

- `manage.run` resolves the focus target and calls `workspace.activate` on it before the layout runs, so a
  click or hover (which only requests focus) updates `strip.active` and the view follows the right column.
- Workspaces are modular. `workspace.setWorkspaceCount` only grows or shrinks the end of
  `Output.workspaces`, so addresses stay stable. `maintainDynamic` implements `dynamic_workspaces` once
  per manage pass.
- `reload_config` only sets `wm.reload_pending`; the pass reloads after the queued actions have run. A
  SIGHUP sets the same flag and asks for a pass.

## Configuration

`config.zig` runs the built-in `default_config.lua` first and then the user's script, each in its own Lua
state (Lua 5.4 from ziglua, linked statically). Every global the script sets is an option; `bind`,
`unbind`, `include`, `theme`, `monitor` and `monitor_profile` are the functions it can call. A Lua error,
unknown option or bad value gives a warning and is skipped, so startup never fails because of the config.
`SIGHUP` reloads it (`manage.reload`).

Dock and Clip options (`dock_edge`, `dock_offset`, `dock_on_top`, `dock_auto_raise`, `clip_corner`,
`clip_on_top`, `clip_collapsed`, `clip_auto_collapse`, `clip_auto_raise`) can also come from the saved
`WMState`. `Config.explicit` records which of them the user's `config.lua` sets itself (the built-in
defaults never count). The Dock itself is not ported yet.

Key names are xkbcommon keysyms and follow the active keyboard layout (`keys.zig`). There used to be a
QWERTZ remapping; I removed it because bindings are compared against the active layout and the extra
remapping made them wrong. `bind_layout` pins bindings to one layout if needed.

## Window Maker files

- `~/.config/wmaker-wl/{RootMenu,WMWindowAttributes}` win over `~/GNUstep/Defaults/{WMRootMenu,WMWindowAttributes}`
  (`$WMAKER_USER_ROOT` is respected). A broken file is reported with its line number and skipped.
- `enable_wmaker_compat = false` (the default) turns off reading from `~/GNUstep`.
- Attributes are looked up per `app_id` in `manage.placeNew`. `StartWorkspace`, `Omnipresent`, `KeepOnTop`,
  `StartMaximized` and `Floating` decide the initial placement; `NoBorder` and `Unfocusable` apply
  continuously and are refreshed when the `app_id` arrives late.
- Omnipresent windows (`Window.isOmnipresent`) follow the user in `action.switchWorkspace`.

## Known limitations

- No title bars or other window decoration. Dragging a tiled window makes it float; there is no
  drag-reordering of columns.
- The root menu, window list, Dock, Clip and DockApps are not ported yet (`attic/`).
- No layer-shell, so no panels or launchers that need it.
- One seat only. Touch and tablets are ignored.
- Monitor hotplug is tested on the model, not yet with real plugging and unplugging.