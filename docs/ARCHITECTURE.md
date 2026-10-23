# Architecture

`wmaker-wl` is a client of river's `river_window_management_v1` protocol. river composites and handles
input; this program decides where windows go, what has focus, and draws the menus, Dock and Clip. This
page is a map of the source.

## Source layout

Everything is in `src/` unless noted. "Wayland" means the file sends requests to the compositor.

| File | What it does | Wayland |
|---|---|---|
| `types.zig` | data model, commands, invariants | no |
| `layout.zig` | geometry: columns, scrolling, floating | no |
| `workspace.zig` | every change to the window tree | no |
| `action.zig` | parses and runs commands (key bindings, menu entries) | only `close` |
| `window.zig` | window events, `applyManage`, `applyRender` | yes |
| `seat.zig` | key bindings, focus, mouse move/resize | yes |
| `output.zig` | outputs, layer-shell work area | yes |
| `monitors.zig` | monitor identification, rules, profiles, hotplug decisions | no |
| `main.zig` | startup, registry, the manage/render loop, signals, CLI | yes |
| `config.zig`, `lua.zig`, `share/default_config.lua` | Lua config and its defaults | no |
| `plist.zig` | Window Maker / GNUstep property-list parser | no |
| `wm_menu.zig` | root menu model (plist and text format) | no |
| `fsmenu.zig` | `OPEN_MENU`: a menu built from a directory | no |
| `wm_attr.zig` | `WMWindowAttributes`, per-`app_id` rules | no |
| `wm_files.zig` | where Window Maker files are looked for, and loading them | no |
| `wm_dock.zig` | the logic of Window Maker's `dock.c` (slots, snapping, drawers, Clip) | no |
| `dockapp.zig` | Dock and Clip data: entries, order, `WMState` read/write | no |
| `dockhost.zig` | how DockApp windows are adopted and placed in their tile | yes |
| `dock.zig` | Dock/Clip geometry, hit testing, icon loading, drawing | no |
| `scale.zig` | tile-size scaling; an identical copy lives in each example | no |
| `appicon.zig` | finds the icon theme icon of an application | no |
| `xpm.zig`, `svg.zig` | XPM reader; SVG through `librsvg` loaded with `dlopen` | no |
| `ui.zig` | root menu, window list, Dock and Clip surfaces, pointer and keyboard input | yes |
| `miniwin.zig` | list of tiles for minimized windows | no |
| `gfx.zig`, `wm_text.c/.h` | cairo/pango drawing; the C file wraps Pango font-description macros | no |
| `shm.zig` | `wl_shm` buffers (memfd) with a checked size | yes |
| `anim.zig` | Window Maker's miniaturize animation (zoom, twist, flip), drawn as outlines | no |
| `animation.zig` | window animations: spring and easing curves, parsing `anim_window_*` | no |
| `process.zig` | starts commands detached from the WM | no |
| `log.zig`, `trace.zig`, `perf.zig`, `invariants.zig`, `diag.zig`, `dump.zig` | logging and debugging, see [DEBUGGING.md](DEBUGGING.md) | no |
| `compatibility.zig` | old stub, not used at run time; only imported by `root.zig` and the tests | no |
| `root.zig` | re-exports modules by name; its `test { }` block is the list of test files | no |
| `*_test.zig`, `bench.zig` | tests and the benchmark | – |
| `../wlprefs/` | the settings program, a separate executable | yes |

Anything that changes the model can be tested without a compositor.

### Registering tests

Zig only runs the tests of a file if the test root refers to it, and an unused `pub const x = @import(...)`
does not count. So every file with `test` blocks is named in one `test { }` block, one line each:

```zig
_ = @import("name.zig");
```

- **wmaker-wl:** `src/root.zig`. This is the only place to touch for a new test file. `src/main.zig` is the
  test root and only pulls in `root.zig`; its own tests run without a line.
- **wlprefs:** `wlprefs/src/root.zig`, same convention. It is a separate module with its own Wayland
  bindings, so its tests cannot be listed in `src/root.zig`; `zig build test` runs both anyway.
- **Examples:** the `main.zig` of each example. They are separate projects, run by `zig build test-all`.

A test file that is missing from its list silently never runs. Nothing checks this automatically.

## Protocol flow

```text
events ─▶ manage_start ─▶ [requests] ─▶ manage_finish ─▶ river configures clients
                                                              │
                          render_finish ◀─ [requests] ◀─ render_start
```

- **Management state** (`propose_dimensions`, `set_tiled`, `fullscreen`, focus, `op_start_pointer`,
  `op_end`, `close`) may only be sent between `manage_start` and `manage_finish`. It all happens in
  `main.onManage`.
- **Rendering state** (`set_position`, `place_top`, `set_borders`, `show`, `hide`) can be sent in either
  sequence and takes effect at `render_finish`. Positions are set during `manage_start` next to
  `propose_dimensions`, so a window is placed in the same frame it is resized. `render_start` only
  corrects windows that changed their own size.
- Every `manage_start` is answered with `manage_finish` on every path (a `defer` in `onManage`), or river
  waits forever.
- Key presses arrive outside a manage sequence. `pressed` only queues the command and calls
  `manage_dirty`; the command runs in `onManage`.
- The same applies to the menu: pointer and keyboard callbacks in `ui.zig` only change plain data (hover
  row, open levels, a pending request) and call `manage_dirty`. Creating and destroying shell surfaces,
  positioning, stacking, drawing, committing buffers and taking keyboard focus all happen in `Ui.sync()`,
  called once from `onManage`.
- A shell surface that is no longer needed (closed submenu, vanished output) is destroyed at the end of
  `sync()`, after drawing for that sequence is done. Destroying it earlier left the last frame on screen
  for one extra cycle.
- Menu buffers are double-buffered per surface; a `wl_buffer` that river has not released is never drawn
  into. `shm.checkedSize()` rejects zero or negative sizes, `i32` overflow, sides over 16384 px and
  buffers over 256 MiB before any `memfd` or `mmap` call. `wm_menu.zig` caps nesting depth, items per menu
  and the number of warnings, so a broken `RootMenu` cannot exhaust memory or stack.

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
- Windows are kept inside the layer-shell `non_exclusive_area`, so panels are not covered.

## Mouse (Super+left = move, Super+right = resize)

States: `idle → requested → running → ending → idle` (`types.OpState`).

- `op_delta` is cumulative since the start. Geometry is always `start + delta`, never `+=`.
- A tiled window leaves the strip only after being dragged `drag_threshold` pixels.
- If the button is released before `op_start_pointer`, river does not know about the operation and never
  sends `op_release`, so the operation is cancelled on the spot.
- If a window dies during an operation, the state goes `running → ending`, so `op_end` is still sent and
  the pointer is not left grabbed.
- Client requests (`pointer_move_requested` and so on) go through the same state machine.

## Focus and workspaces

- `onManage` resolves the focus target and calls `workspace.activate` on it before the layout runs, so a
  click or hover (which only requests focus) updates `strip.active` and the view follows the right column.
- Workspaces are modular. `workspace.setWorkspaceCount` only grows or shrinks the end of
  `Output.workspaces`, so addresses stay stable. `maintainDynamic` implements `dynamic_workspaces` once
  per manage pass.
- `reload_config` only sets `wm.reload_pending`; `onManage` reloads after the queued actions have run.

## Configuration

`config.zig` runs the built-in `default_config.lua` first and then the user's script, each in its own Lua
state (Lua 5.4 from ziglua, linked statically). Every global the script sets is an option; `bind`,
`unbind`, `include`, `theme`, `monitor` and `monitor_profile` are the functions it can call. A Lua error,
unknown option or bad value gives a warning and is skipped, so startup never fails because of the config.
`SIGHUP` reloads it (`main.reloadConfig`).

Dock and Clip options (`dock_edge`, `dock_offset`, `dock_on_top`, `dock_auto_raise`, `clip_corner`,
`clip_on_top`, `clip_collapsed`, `clip_auto_collapse`, `clip_auto_raise`) can also come from the saved
`WMState`. `Config.explicit` records which of them the user's `config.lua` sets itself (the built-in
defaults never count), and `main.applyDockState` lets the saved state fill only the others.

Key names are xkbcommon keysyms and follow the active keyboard layout. There used to be a QWERTZ
remapping; I removed it because river compares against the active layout and the extra remapping made
bindings wrong. `bind_layout` pins bindings to one layout if needed.

## Window Maker files

- `~/.config/wmaker-wl/{RootMenu,WMWindowAttributes}` win over `~/GNUstep/Defaults/{WMRootMenu,WMWindowAttributes}`
  (`$WMAKER_USER_ROOT` is respected). A broken file is reported with its line number and skipped.
- `enable_wmaker_compat = false` (the default) turns off reading from `~/GNUstep`.
- Attributes are looked up per `app_id` in `window.placeNew`. `StartWorkspace`, `Omnipresent`, `KeepOnTop`,
  `StartMaximized` and `Floating` decide the initial placement; `NoBorder` and `Unfocusable` apply
  continuously and are refreshed when the `app_id` arrives late.
- Omnipresent windows (`Window.isOmnipresent`) follow the user in `action.switchWorkspace`.

## Known limitations

- No title bars or other window decoration. Dragging a tiled window makes it float; there is no
  drag-reordering of columns.
- Dock and Clip are only on the primary output.
- Menu and Dock bind only the first `wl_seat`.
- Monitor hotplug is tested on the model, not yet against a river with real plugging and unplugging.