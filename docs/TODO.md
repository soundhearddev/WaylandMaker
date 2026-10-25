# TODO

Roughly in the order I care about them. Nothing here is promised.

## Window manager

- [ ] **Title bars.** There are none; windows only have a border. Draw them as scene
      rectangles and text. It also unlocks the `NoTitlebar`, `NoResizebar`, `NoCloseButton` and `NoMiniaturizeButton`
      attributes (see [INTEGRATION.md](INTEGRATION.md)).
- [ ] **Docks: space and overlap.** Under some conditions tiles or windows overlap the Dock. I still need to
      pin down which edge, how many outputs and which tiles are involved, then fix it.
- [ ] **Dock and Clip on every output**, or selectable per output. For now they are on the primary monitor
      (`monitor(..., { primary = true })`).
- [ ] **Several seats.** Menu and Dock belong to the first bound `wl_seat`; other seats get no pointer and
      no keyboard for the menu.
- [ ] **Drag-reordering of columns.** Dragging a tiled window makes it float.
- [ ] **Save session** (`SAVE_SESSION`: windows, workspaces, columns). Only worthwhile if programs can be
      recognised and started again, which needs an `app_id` to start-command mapping first. The Dock
      entries already have the pieces for that.
- [ ] **`wmaker-wl --restart` / `RESTART` menu entry.** Re-executing the process would drop the existing
      compositor, which would end the session. `SIGHUP` reload
      (`pkill -HUP wmaker-wl`) covers the main need, new config without restarting the session.
- [ ] **Icons from `~/.local/share/icons` and `~/.icons`.** Only `/usr/share/icons` and
      `/usr/share/pixmaps` are searched.
- [ ] **`compatibility.zig`** is a leftover stub that nothing uses at run time. Delete it, or finish it.

## Monitors

See [MONITORS.md](MONITORS.md).

- [ ] Commands `focus_output_left/right/up/down` and `move_to_output_left/...`. The neighbour search
      (`types.outputToward`) is done; the commands still need entries in `types.Command`, `action.zig` and
      `wlprefs/src/actions.zig`.
- [ ] Release `wl_output` globals when they are removed (`global_remove`). Right now the entry stays in
      `wm.wl_outputs`.
- [ ] Detect mirrored monitors (`monitors.mirrored` exists) and treat them as one.
- [ ] Workspace names per monitor.
- [ ] Configure modes, scale and position directly through `wlr-output-management`, instead of only running
      an external command (kanshi, wlr-randr) from `monitor_profile`.
- [ ] Test hotplug against real plugging and unplugging. The model side is tested
      (debouncing, rules, windows returning). What needs checking is the order of the wlroots events.

## Performance

`zig build bench` and the probes in the running WM exist (`src/bench.zig`, `src/perf.zig`, [DEBUGGING.md](DEBUGGING.md)). Still open:

#### Must

- [ ] Measure Manage + Render p50/p99 with real clients, at 1, 10, and 50 windows, with and without animations. Current benchmarks only cover model-level performance in Debug builds.
- [ ] Add per-window probes for `applyManage` / `applyRender` and probes for `Ui.sync`, so 8 ms warnings can be traced to their source.
- [ ] Benchmark all configurations in `ReleaseFast` and `ReleaseSafe`. Debug timings are not representative of real-world frame performance.
- [ ] Make `Ui.sync` redraw only changed content. Check whether the menu, dock, and clip are redrawn on every manage sequence, even when nothing changes. If so, add per-panel dirty flags and row-/tile-level damage tracking instead of full redraws.
- [ ] Optimize the animation path so only changed windows receive requests. While `anim_active` is set, a frame runs every 16 ms, but stationary windows must not receive `set_position` or `propose_dimensions` requests. Check whether the 16 ms timer drifts relative to the actual refresh rate.
- [ ] Reduce idle costs to zero. When nothing is happening, `poll` should sleep without a timeout. Count wakeups per second with `strace -c` or `perf`. Autocollapse, monitor-settle, and animation timers must stop when no longer needed.
- [ ] Check the desktop catcher's `wl_shm` memory usage. It uses a transparent surface covering the full output size on each monitor. A single 4K buffer takes approximately 33 MB; double buffering doubles that. If confirmed, switch to a tiny buffer with a viewport or `wp_single_pixel_buffer`.
- [ ] Eliminate file I/O from the Manage/Render paths. Icon searches (themes and `.desktop` files), SVG loading, and `WMState` writes must never block a sequence. Cache results or defer work until outside the frame path.
- [ ] Investigate benchmark outliers. In the checked-in benchmark, `layout columns` with 100 windows reaches 2721 µs maximum against a 20 µs average, while `layout stacks of 4` reaches 360 µs against an 8 µs average. Allocator overhead or page faults may be responsible, but this needs verification.
- [ ] Run long-duration memory soak tests. Open and close windows, connect and disconnect monitors, and reload with `SIGHUP` for several hours while monitoring RSS. Check for leaks with Valgrind or the debug allocator.

#### Should

- [ ] Count allocations in hot paths. Add an allocation counter to the benchmark and move Manage, Layout, and Render allocations to arenas or fixed-size buffers where appropriate.
- [ ] Cache Cairo/Pango resources. Reuse text measurements, layouts, and font maps instead of rebuilding them on every draw. Rebuild menu rows only when their contents change.
- [ ] Measure logging overhead. Ensure filtered log messages are never formatted in the first place. Measure the flight recorder and `info` logging separately in hot paths.
- [ ] Throttle pointer operations. Super + mouse move/resize should perform work once per frame rather than once per motion event.
- [ ] Benchmark multiple monitors: test 3–4 outputs with animations and rapid hotplug sequences, including repeated connect/disconnect cycles within a second.
- [ ] Stress-test many clients. Open and close 100–200 terminals simultaneously. Measure time to first frame, frame time, and `move all windows`. The Debug benchmark currently shows around 10 ms for the latter with 1000 windows.
- [ ] Measure startup time until the WM is ready, including Lua configuration, icon directories, `WMState`, and autostart. Introduce lazy loading if necessary.
- [ ] Measure input latency from key press to the committed frame. The path runs through the queue, `manageDirty`, and one pass.
- [ ] Measure configuration reload latency from `SIGHUP` to completion using large configurations with many includes. Reloading must not block a frame.
- [ ] Investigate `process.spawn` overhead with large address spaces. Consider `posix_spawn` or `vfork` if they offer lower fork costs.

#### Nice to have

- [ ] Add benchmarks with animations and multiple outputs to `src/bench.zig`.
- [ ] Run `bench -- --check` in CI against a stored baseline to catch regressions. Current performance budgets are intentionally loose.
- [ ] Document reference numbers for fixed, real hardware rather than a container.
- [ ] Compare build configurations: `ReleaseSafe` vs. `ReleaseFast`, stripping, and LTO. If the performance difference is small, recommend `ReleaseSafe`.

## The Rest

- [ ] Better Live config reload

## wlprefs

The list is in `wlprefs/TODO.md`.