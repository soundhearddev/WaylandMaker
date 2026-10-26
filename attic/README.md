# attic

The river-era UI, kept as the source for porting. **Not built.** The files still `@import` the old `src/`
layout (`window.zig`, `seat.zig`, river protocol objects), so they do not compile as they are.

| file | what it is | port target |
|---|---|---|
| `ui.zig`, `fsmenu.zig` | root menu, window list | wlroots scene, see `docs/TODO wlroots.md` |
| `dock.zig`, `miniwin.zig` | drawing of the Dock, Clip, Drawers and miniwindows (their model is `src/dock_model.zig`, DockApp hosting `src/dockhost.zig`) | scene |
| `gfx.zig`, `svg.zig`, `xpm.zig`, `appicon.zig`, `scale.zig`, `shm.zig`, `wm_text.c/h` | drawing, icons, scaling | reuse nearly as is |
| `anim.zig` | miniaturize animation | scene |
| `window.zig`, `seat.zig` | river window and seat wrappers | replaced by `view.zig`, `keyboard.zig`, `cursor.zig` |

Delete a file here when its port is done.
