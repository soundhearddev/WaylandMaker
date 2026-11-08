# TODO

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
- [ ] **Window menus and the window list** (root menu is done): see section 4 of [TODO wlroots.md](TODO%20wlroots.md).

- [ ] Detect mirrored monitors (`monitors.mirrored` exists) and treat them as one.
- [ ] Workspace names per monitor.
- [ ] `wlr-output-management` (kanshi, wlr-randr). Done without it: `monitor()` rules set `mode`, `scale`, `x`/`y` and on/off directly (`output.zig`, not run). Still to do: the protocol, instead of only running
      an external command (kanshi, wlr-randr) from `monitor_profile`.
- [ ] Test hotplug against real plugging and unplugging. The model side is tested
      (debouncing, rules, windows returning). What needs checking is the order of the wlroots events.

- [ ] Measure Manage + Render p50/p99 with real clients, at 1, 10, and 50 windows, with and without animations. Current benchmarks only cover model-level performance in Debug builds.
- [ ] Add per-window probes for `applyManage` / `applyRender` and probes for `Ui.sync`, so 8 ms warnings can be traced to their source.
- [ ] Benchmark all configurations in `ReleaseFast` and `ReleaseSafe`. Debug timings are not representative of real-world frame performance.
- [ ] Make `Ui.sync` redraw only changed content. Check whether the menu, dock, and clip are redrawn on every manage sequence, even when nothing changes. If so, add per-panel dirty flags and row-/tile-level damage tracking instead of full redraws.
- [ ] Optimize the animation path so only changed windows receive requests. While `anim_active` is set, a frame runs every 16 ms, but stationary windows must not receive `set_position` or `propose_dimensions` requests. Check whether the 16 ms timer drifts relative to the actual refresh rate.
- [ ] Reduce idle costs to zero. When nothing is happening, `poll` should sleep without a timeout. Count wakeups per second with `strace -c` or `perf`. Autocollapse, monitor-settle, and animation timers must stop when no longer needed.
- [ ] Eliminate file I/O from the Manage/Render paths. Dock icons are now loaded at most 3 per pass (`dock_scene.zig`, `icons_per_pass`): the other tiles show without a picture for a few turns of the loop and get it in the next passes, so a Dock with many apps no longer holds the first pass; the first load of each icon still reads files inside a pass. Still open: SVG loading, `WMState` writes, the menu. Icon searches (themes and `.desktop` files), SVG loading, and `WMState` writes must never block a sequence. Cache results or defer work until outside the frame path.
- [ ] Investigate benchmark outliers. In the checked-in benchmark, `layout columns` with 100 windows reaches 2721 µs maximum against a 20 µs average, while `layout stacks of 4` reaches 360 µs against an 8 µs average. Allocator overhead or page faults may be responsible, but this needs verification.
- [ ] Run long-duration memory soak tests. Open and close windows, connect and disconnect monitors, and reload with `SIGHUP` for several hours while monitoring RSS. Check for leaks with Valgrind or the debug allocator.

- [ ] Count allocations in hot paths. Add an allocation counter to the benchmark and move Manage, Layout, and Render allocations to arenas or fixed-size buffers where appropriate.
- [ ] Cache Cairo/Pango resources. Reuse text measurements, layouts, and font maps instead of rebuilding them on every draw. Rebuild menu rows only when their contents change.
- [ ] Measure logging overhead. Ensure filtered log messages are never formatted in the first place. Measure the flight recorder and `info` logging separately in hot paths.
- [ ] Benchmark multiple monitors: test 3–4 outputs with animations and rapid hotplug sequences, including repeated connect/disconnect cycles within a second.
- [ ] Stress-test many clients. Open and close 100–200 terminals simultaneously. Measure time to first frame, frame time, and `move all windows`. The Debug benchmark currently shows around 10 ms for the latter with 1000 windows.
- [ ] Measure startup time until the WM is ready, including Lua configuration, icon directories, `WMState`, and autostart. Introduce lazy loading if necessary.
- [ ] Measure input latency from key press to the committed frame. The path runs through the queue, `manageDirty`, and one pass.
- [ ] Measure configuration reload latency from `SIGHUP` to completion using large configurations with many includes. Reloading must not block a frame.
- [ ] Investigate `process.spawn` overhead with large address spaces. Consider `posix_spawn` or `vfork` if they offer lower fork costs.

- [ ] Add benchmarks with animations and multiple outputs to `src/bench.zig`.
      *Multiple outputs: done (`layout 4 outputs`). Animations: not yet.*
- [ ] Run `bench -- --check` in CI against a stored baseline (CI runs the budgets; `--json` / `--baseline` exist, but a baseline from a hosted runner means little) to catch regressions. Current performance budgets are intentionally loose.
- [ ] Document reference numbers for fixed, real hardware rather than a container.
- [ ] Compare build configurations: `ReleaseSafe` vs. `ReleaseFast`, stripping, and LTO. If the performance difference is small, recommend `ReleaseSafe`.

- [ ] **Try the session for real**: from GDM, SDDM, greetd and ly, and from a TTY. With and without
      systemd (`WMAKER_NO_SYSTEMD=1`), with elogind and seatd. Check that `graphical-session.target`
      comes up, that `READY=1` arrives, and that `wmaker-wl-shutdown.target` stops what it should.
- [ ] A **crash** ends the whole session. At least write the last log lines and a state dump to
      `session.log` before dying, and show a short message on the TTY.
      *Partly done: `wmaker-wl-session` logs the exit status (and the last journal lines under systemd) and prints a message on the terminal. A state dump from the dying process itself is still missing.*
- [ ] **Packages**: `flake.nix` and `manifest.scm` are development shells only. Add a Nix package
      and NixOS module (`services.displayManager.sessionPackages`), a Guix package

- [ ] `ext-session-lock` (screen locker), idle notify and inhibit, `xdg-activation`
- [ ] Screen capture (`ext-image-copy-capture`, screencopy) for `grim` and screen sharing, and the
      matching portal; until then `wmaker-wl-portals.conf` only knows the GTK backend
- [ ] `wlr-output-management`, `wlr-foreign-toplevel-management`, gamma control (pointer constraints and relative pointer are in `cursor.zig`, not run)
- [ ] Touch, tablet, switches (only keyboard and pointer are used)
- [ ] XWayland (decide whether at all)
- [ ] Notifications, a wallpaper, a screenshot key and a lock key in the default config, once the
      protocols above exist

- [ ] `docs/KEYBINDS.md`/`README.md`: the key table and `--help` must stay in step; a test that
      compares them would do.
      *Done for the options: a test compares the README command-line block, the manual page and `--help`. The key table is not compared.*

- [ ] Nothing in `zig build test` runs a compositor. Add a nested smoke test
      (`WLR_BACKENDS=headless`): start, connect a client, open a window, exit.
- [ ] Tests of the example DockApps run only with `test-all`.

- [ ] **Profile expensive operations.** Investigate outliers in `invariants`, `outputs: order+primary`, and `monitors: rules+profile` to distinguish measurement noise from actual bottlenecks.
- [ ] **Benchmark the real compositor.** Measure manage and render paths with real Wayland clients at 1, 10, 50, and 100 windows, including p50/p95/p99 and maximum latency.
- [ ] **Measure end-to-end frame performance.** Track frame times and missed frame deadlines separately from internal model-operation timings.

- [ ] **Remove `protocol/`**: fetch `wlr-protocols` as a pinned dependency instead of keeping a copy of its XML, and prune
      the unused `scanner.generate` lines. Details: section 8 of [TODO wlroots.md](TODO%20wlroots.md).

- [ ] Better live config reload: a reload does not re-create the keymap (`XKB_DEFAULT_*`), and
      `environment` changes need a new session.
- [ ] libinput: the options (`accel_speed`, `accel_profile`, `click_method`, `left_handed`, `disable_while_typing`) are global;
      per-device settings (by name/vendor) are still open.
