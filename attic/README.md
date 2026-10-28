# attic

The river-era UI, kept as the source for porting. **Not built.** The files still `@import` the old `src/`
layout (`window.zig`, `seat.zig`, river protocol objects), so they do not compile as they are.

| file | what it is | port target |
|---|---|---|
| `ui.zig`, `fsmenu.zig` | root menu, window list | wlroots scene, see `docs/TODO wlroots.md` |
| `miniwin.zig` | drawing of miniwindows | scene |
| `shm.zig` | wl_shm buffers | not needed by the scene |
| `anim.zig` | miniaturize animation | scene |
| `window.zig`, `seat.zig` | river window and seat wrappers | replaced by `view.zig`, `keyboard.zig`, `cursor.zig` |

Delete a file here when its port is done.
