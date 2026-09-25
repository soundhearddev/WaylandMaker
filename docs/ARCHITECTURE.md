# wmaker-wl – Architecture

`wmaker-wl` is a window-manager client for [river](https://codeberg.org/river/river) using `river_window_management_v1`. river handles compositing and input; wmaker-wl handles layout, focus, interaction, and the root menu.

## Files

| File | Purpose | Sends Wayland requests? |
|---|---|---|
| `config.zig` + `default_config.conf` | Settings and keybindings, single source of truth | no |
| `types.zig` | Data model and invariants | no |
| `layout.zig` | Pure geometry (columns, scrolling, floating) | no |
| `workspace.zig` | All window-tree mutations | no |
| `action.zig` | Parse and execute commands | only `close` |
| `window.zig` | Window events, `applyManage`, `applyRender` | yes |
| `seat.zig` | Bindings, focus, mouse operations | yes |
| `output.zig` | Outputs, layer-shell work area | yes |
| `main.zig` | Startup, registry, manage/render loop | yes |
| `plist.zig` | Window Maker/GNUstep property-list parser | no |
| `wm_menu.zig` | Root menu model, Plist and text format, depth/item/warning limits | no |
| `wm_attr.zig` | `WMWindowAttributes`: per-`app_id` rules | no |
| `wm_files.zig` | Search paths and loading Window Maker files | no |
| `process.zig` | Spawns commands (`EXEC`/`SHEXEC`, autostart) detached from the WM | no |
| `gfx.zig` | Cairo/Pango canvas: clear, fill, gradient, bevel, text, measure | no |
| `shm.zig` | `wl_shm` buffer (memfd), with a checked, overflow-safe size cap | yes |
| `ui.zig` | Root menu and window list: desktop catcher surfaces, cascading menu surfaces, cairo drawing, pointer/keyboard handling | yes |
| `wm_text.c`/`.h` | Small C helper around Pango's font-description macros, called from `gfx.zig` | no |
| `compatibility.zig` | Unused legacy stub, not imported anywhere except `root.zig` | no |
| `root.zig` | Re-exports every module so `main.zig` and tests can reach them by name | no |
| `model_test.zig` | Invariant tests without a compositor | – |

Everything that modifies the model can be tested without a compositor with `zig build test` (102 tests as of this writing).

## Protocol Flow

```text
Events ─▶ manage_start ─▶ [Requests] ─▶ manage_finish ─▶ river configures clients
                                                              │
                          render_finish ◀─ [Requests] ◀─ render_start
```

- **Management state** (`propose_dimensions`, `set_tiled`, `fullscreen`, focus, `op_start_pointer`, `op_end`, `close`) may **only** be sent between `manage_start` and `manage_finish`. All of this runs from `main.onManage`.
- **Rendering state** (`set_position`, `place_top`, `set_borders`, `show`, `hide`) may be sent in **either** sequence and takes effect with `render_finish`. Position is therefore set during `manage_start` alongside `propose_dimensions` for frame-perfect placement; `render_start` only corrects windows that changed their own size.
- Every `manage_start` is answered with `manage_finish` on **every** path (`defer` in `onManage`), otherwise river waits indefinitely.
- Key presses arrive **outside** a manage sequence. `pressed` only queues the command and calls `manage_dirty`; it is executed in `onManage`.

## Data Model

```text
Output ─ workspaces[N] ─ Workspace
                          ├─ strip    ─ Column ─ Window      (tiled)
                          ├─ floating ─ Window ...            (Z-order, top = most recent)
                          └─ fullscreen: ?*Window
```

Invariants (enforced in `workspace.zig`, checked in `model_test.zig`):

1. Every window belongs to exactly one container (`Window.mode`).
2. A column is never empty; it is destroyed with its last window.
3. A window switches between Tiling and Floating only through `floatWindow`/`tileWindow`. Restoration uses **index and width**, never a pointer to a potentially freed column.
4. Fullscreen is a display state *over* the container; the window remains a member of its column and the strip retains its shape.
5. `wl.list.Link.remove()` dereferences `prev`/`next`. Unlinked links have `null`; removal is only performed through `types.unlink()`.

## Layout

- Column width: `w = f·(avail + gap) − gap`, so 1/2+1/2 and 1/3+1/3+1/3 fit exactly.
- Windows in a column fill the height exactly; remaining pixels are distributed.
- The viewport (`scroll_x`) is clamped on **every** layout pass; when focus changes, it follows the active column (`center_focused_column`).
- Borders are outside the content area; the layout subtracts them from the slot.
- Windows use the layer-shell `non_exclusive_area` so panels do not overlap them.

## Mouse (Super+Left = move, Super+Right = resize)

States: `idle → requested → running → ending → idle` (see `types.OpState`).

- `op_delta` is **cumulative** since the start: geometry is always `start + delta`, never `+=`.
- A tiled window leaves the strip only after moving `drag_threshold` pixels.
- Releasing **before** `op_start_pointer`: river does not know about the operation and never sends `op_release`; the operation is cancelled immediately.
- If a window dies during the operation: `running → ending`, so `op_end` is still sent and the pointer is not left grabbed.
- Client requests (`pointer_move_requested`, etc.) go through the same state machine.

## Configuration

`~/.config/wmaker-wl/config.conf`, format defined in `src/default_config.conf`.

Invalid lines produce a warning and are skipped; startup never fails because of the config.

Key names are xkbcommon keysyms and follow the **active keyboard layout**. The old QWERTZ remapping was removed: river compares against the active layout, and additional remapping made bindings incorrect.

## Window Maker Compatibility

- Files: `~/.config/wmaker-wl/{RootMenu,WMWindowAttributes}` take precedence over `~/GNUstep/Defaults/{WMRootMenu,WMWindowAttributes}` (`$WMAKER_USER_ROOT` is respected). A broken file is reported with its line number and skipped; startup never fails because of it.
- `enable_wmaker_compat = no` disables reading from `~/GNUstep`.
- Attributes are resolved in `window.placeNew` (`Table.lookup(app_id)`): `StartWorkspace`, `Omnipresent`, `KeepOnTop`, `StartMaximized`, and `Floating` determine the initial placement; `NoBorder` and `Unfocusable` apply continuously (`Window.attrs`, updated when `app_id` arrives later).
- Omnipresent windows (`Window.isOmnipresent`: `sticky` and floating) move with the user to the new workspace in `action.switchWorkspace`.

## Root Menu (`ui.zig`)

The root menu, window list, and the transparent desktop-catcher surfaces that receive right/middle clicks
on the empty desktop are implemented in `ui.zig`, drawn with `gfx.zig` (cairo/pango) into `wl_shm` buffers
managed by `shm.zig`. See `docs/INTEGRATION.md` for the Window Maker-specific menu format and behaviour;
this section only covers the client-side protocol discipline:

- Input callbacks (`wl_pointer`/`wl_keyboard` listeners) run **outside** a manage/render sequence, where
  river forbids both rendering state (`node.set_position`, `place_top`/`place_bottom`) and management state
  (`seat.focus_shell_surface`). Callbacks therefore only mutate plain data (hover index, which levels are
  open, a pending `Request`) and call `manage_dirty()`.
- Everything that actually talks to river — creating/destroying shell surfaces, positioning, stacking,
  drawing, committing buffers, taking keyboard focus — happens in `Ui.sync()`, called once from
  `main.onManage()`. This is the single place that is allowed to do so.
- Shell surfaces that are no longer needed (a closed submenu, an output that disappeared) are queued in a
  graveyard and only actually destroyed at the **end** of `sync()`, after drawing and positioning for that
  sequence are done — not at the start of the *next* `sync()`, which previously left a closed submenu
  visible with its last frame for one extra cycle.
- Buffers are double-buffered per surface (`Panel.slots`): a `wl_buffer` river has not yet released is
  never drawn into again.
- `shm.checkedSize()` validates width/height before any `memfd`/`mmap`/Wayland call: rejects zero or
  negative sizes, catches `i32` overflow in `width * 4`, and caps both the per-side size (16384 px) and the
  total byte size (256 MiB). `wm_menu.zig` separately caps menu nesting depth, item count per menu, and the
  number of parse warnings, so a broken or hostile `RootMenu` file cannot exhaust memory or the stack.

## Known Limitations

- Title bars and the dock are not implemented yet (see `docs/TODO.md`).
- Drag-reordering windows within the strip is not implemented; dragging makes windows floating.
- The root menu currently binds only the first `wl_seat` that appears; additional seats get no pointer or
  keyboard for the menu.
- Two small root-menu fixes (pointer cursor shape, a menu-overlap timing issue) are written and tested but
  not yet merged into `main`; see `docs/TODO.md`.
- Running against a real river has not been verified for the UI layer (`ui.zig`, `shm.zig`, `gfx.zig`);
  only `zig build` and `zig build test` are confirmed so far.