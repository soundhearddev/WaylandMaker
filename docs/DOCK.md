# The Dock: plan

Status: the model is done and tested (`dock_model.zig`, `dockhost.zig`, `dock_view.zig`). Nothing is drawn yet. This
document is the plan for drawing it, and for making it the cheapest part of the compositor to run.

## 1. What the river version did, and why not again

`attic/dock.zig` + `attic/ui.zig`:

- One `wl_shm` surface per dock (Dock, Clip, every Drawer), covering all its tiles plus a margin for drags.
- Every change (pointer enters a tile, a workspace switch, a program starts) redrew the whole surface with cairo: every
  gradient, every bevel, every icon, every label, then a full `wl_surface.commit`.
- Icons were loaded and decoded when the model was built, on the main thread. An SVG theme or a slow disk stalls the
  compositor.
- Pointer handling lived in the UI client, one round trip behind the compositor.

None of that is needed with wlroots: the Dock is part of the compositor, and wlroots' scene graph already does damage
tracking per node.

## 2. The design: three layers, only the last one knows about wlroots

```
dock_model.zig   what is in the Dock            (done, tested)
dock_view.zig    what each tile looks like      (done, tested)
dock_scene.zig   one scene node per tile        (compositor, to do)
```

### Model (done)

Tiles, grid, rows, running, launching, temporary tiles for DockApps and minimized windows, drawers, the Clip per
workspace. `dockhost.update` runs it once per manage pass and reports `changed`.

### View: `Look` is the contract (done)

`dock_view.plan` turns the model plus the interaction state (hover, drag, workspace) into a flat list of `Tile`s:
identity, position, and a `Look`. A `Look` is everything that decides the pixels of one tile and nothing else. Two
consequences the scene layer builds on:

1. **Pixels are cached by `Look.key()`.** The 64x64 frame with the "hot" gradient is rendered once, however many tiles
   share it. A tile that goes hot, cold and hot again costs one render in total.
2. **`dock_view.diff` tells what to touch.** Pointer from tile A to tile B: two `restyle`s. A drag: one `move` per
   motion event. Workspace switch: one `restyle`. A pass in which nothing happened: nothing, not even a cairo call.

### Scene (to do)

- One `wlr_scene_tree` per dock, with one `wlr_scene_buffer` per tile. A tile is a node, not a pixel region of a big
  surface.
- Buffers are `wlr_buffer`s wrapping cairo image data (a small custom `wlr_buffer_impl`, ~60 lines), created by the
  render cache and shared by every node with the same `Look.key()` (reference counted by wlroots).
- `add` creates a node, `remove` destroys it, `move` is `node.setPosition`, `restyle` is `sceneBuffer.setBuffer` with a
  cached buffer. No manual damage, no frame callbacks of our own.
- Render cache: `HashMap(u64 key -> *wlr_buffer)`, bounded (a few hundred entries, evicting the least recently used).
  Cleared when the tile size, the theme or the output scale changes.
- Icons: a second cache, keyed by `Look.icon_key` and size. A tile whose icon is not loaded yet is drawn with the
  placeholder and restyled when the icon arrives (the key then changes through an `icon_ready` flag). Decoding PNG/SVG/XPM
  runs off the main thread (one worker, a queue; the result is handed over through the event loop's pipe).
- Output scale: tiles are rendered at `size * scale` and shown with `setDestSize`. A scale change rebuilds the cache;
  nothing else is affected.
- Layers: Dock below DockApps below drawer popups; whether the whole Dock sits above or below normal windows is the
  existing `dock_on_top` / auto-raise level (`dock_model.levelFor`).

## 3. Input

Hit testing is pure (`dock_model.cellsOf`/`cellPx`/`clipArrowAt`), so the pointer path does not need scene picking:

1. The cursor handler asks "is the pointer inside a dock's rectangle?". Rectangles come from `dock_model.layout`.
2. If so, the dock handles it and the pointer does not reach the windows below.
3. A small state machine (`dock_input.zig`, pure, tested like `pointer_op.zig`) turns press/release/motion into
   actions: launch, focus the running program, raise it, start a drag, drop a tile, switch workspace (Clip arrows),
   open or close a Drawer, show the menu. The compositor applies the actions.

Timers: auto-collapse, auto-raise and the `launching` timeout share one timer armed from `launchWaitMs` and the dock's own
deadlines, like the monitor settle timer in `server.zig`.

## 4. What makes it Window Maker

niri-style tiling is the engine; the feel is these parts, in order of how much they carry it:

1. The Dock, the Clip and Drawers (this plan), with the miniwindows' tiles already modelled.
2. The root menu on a click on the empty desktop (`wm_menu.zig` parses `RootMenu`; its click actions are not on the
   model yet).
3. Window Maker's own window decoration: titlebar with the three buttons, the resizebar. Today windows only have a
   border. This is the part that changes the look most, and it fits the same scene approach (a `Look` for each
   decoration piece, cached by key).
4. Themes: `share/Themes` already holds colour sets; the tile frames, the titlebar and the menu should all be rendered
   from one theme object so a theme change is a cache clear.
5. Appicons for windows that are not docked (the little tile with the icon when a program is minimized).

## 5. Phases

| # | Step | Done when |
|---|---|---|
| 0 | `wlr-layer-shell` (and `wlr_scene_layer_surface_v1`) | `swaybg` starts and the wallpaper shows; usable for panels, launchers, lock screens |
| 1 | Static Dock: scene nodes, render cache, frame + logo + icons, `dock_shown = true` | the Dock is visible, windows keep out of its column, DockApps sit in their tiles |
| 2 | Hover, click, launch, running marks, launching raster | clicking a tile starts the program; a program's window raises on click |
| 3 | Drag and drop, drop-to-remove, keep-icon, save to `WMState` | tiles can be rearranged and the layout survives a restart |
| 4 | Clip (workspace tile, arrows, per-workspace tiles) | switching workspaces changes the tile; arrows work |
| 5 | Drawers and auto-collapse | a Drawer opens on hover and closes again |
| 6 | Minimized windows as tiles (model exists), window titlebars | minimize/restore from the Dock |

Each step comes with the tests that can run without a display (plan, diff, input state machine); the scene code stays
small enough to read in one go.

## 6. Open decisions

- **Icon formats and sources**: keep PNG + XPM + SVG (librsvg) as before, or read the icon theme through
  `freedesktop-icon-theme` lookup rules instead of the fixed `icon_dirs` list.
- **Pango vs cairo toy text** for tile labels: Pango is already linked for wlprefs; the compositor would link it too.
- **Where the render code lives**: `gfx.zig` from the attic is cairo-based and Wayland-free; moving it to `src/` as it is
  keeps the tests that exist for it.
- **Dock on every output or on the primary only**: today the model puts it on the primary output (as Window Maker's
  `Dock` is per screen). A per-output Dock would need one `Model` per output.