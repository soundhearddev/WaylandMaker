# TODO: wlroots backend (river -> own compositor)

Goal: wmaker-wl runs as its own compositor on wlroots instead of being a client of river.
Bindings: `zig-wlroots` 0.20.x (needs Zig 0.16, wlroots 0.20, zig-wayland, zig-xkbcommon, zig-pixman).

Rules while doing this:
- river backend keeps working until the wlroots backend is good enough to live in.
- Model code (`types`, `layout`, `workspace`, `action`, `config`, `dock*`, `wm_*`, `monitors`) must not import wlroots.

## 0. Probe (can wlroots be used from Zig here at all?)

- [x] Install system deps: wlroots 0.20 dev files, libinput, libevdev, pixman, xkbcommon, wayland-protocols, wayland-scanner
- [x] `zig fetch --save` zig-wlroots and zig-pixman into `build.zig.zon`
- [x] Separate target `wlr-probe` (own `src_wlr/probe.zig`), main exe untouched
- [x] Probe builds with Zig 0.16
- [x] Probe runs nested: `WLR_BACKENDS=wayland ./zig-out/bin/wlr-probe` opens a window inside the current river session
- [x] Copy the wiring from zig-wlroots `tinywl/build.zig` (scanner `generate` list, imports, system libs)
- [x] Decide: zig-wlroots bindings (works with Zig 0.16.0; xkbcommon 0.4.0 needs `switch (key) { .Escape => ... }` instead of the old u32 constants)

## 1. Split model from backend

Done so far: model handles go through the `backend` module.

- `src/backend_river.zig`: river build, aliases to the generated river types (no change at run time)
- `src_wlr/backend_wlr.zig`: placeholder with opaque handles and the same `Modifiers` bits
- `types.zig`, `config.zig`, `action.zig` no longer name `river`
- `src/model.zig`: the files that must stay river-free (types, layout, workspace, action, config, ...)
- `zig build wlr-model-check` compiles them with the wlroots placeholder

river use outside the model (this is what the wlroots backend replaces):

| File | `river`/`.obj`/`.node` uses |
|---|---|
| `ui.zig` | 45 |
| `window.zig` | 38 |
| `seat.zig` | 31 |
| `output.zig` | 18 |
| `main.zig` | 16 |
| `dockhost.zig` | 11 |

- [x] List every `river_*` use per file (table above)
- [x] Handle types behind `backend` (types, config, action)
- [x] `zig build` and `zig build test` still pass with the `backend` module (river build unchanged)
- [x] `zig build wlr-model-check` passes; fix whatever it still finds in the model
- [ ] Add `wm_dock.zig`, `dock.zig` (logic part) to `model.zig` and the check (`wm_files`, `log`, `trace`, `version` are in)
- [ ] Define the real backend interface (window, output, seat, shell surface) from the `window/seat/output` call sites
- [ ] Move `applyManage` / `applyRender` logic behind it
- [ ] `ui.zig`: separate drawing (cairo/pango, stays) from surface creation and input (changes)
- [ ] river backend still passes `zig build test` and runs

## 2. Minimal compositor (milestone A: can type in a terminal)

Status: written in `src_wlr/`, **compiled and linked against the zig-wlroots 0.20.1 bindings, not yet run**
(no wlroots 0.20 in the build sandbox). All 89 `wlr_*` symbols it uses exist in wlroots' headers. First real test:
`zig build wlr && WLR_BACKENDS=wayland ./zig-out/bin/wmaker-wlr` inside river, then from a TTY.
Build needs wayland-protocols >= 1.44 (or `-Dcolor-manager-version=1`).

Files: `main` (entry) `cli` `boot` (config/env, no wlroots) `server` (globals, loop, `Sink`) `output` `view` (xdg toplevel, popup)
`keyboard` `cursor` `keys` (bind matching, no wlroots) `manage` (the manage pass, no wlroots) `probe`.
`keys`, `manage`, `cli` have tests: `zig build wlr-model-check`.

- [x] `wl_server`, backend, renderer, allocator, scene, output layout
- [x] Outputs: add, remove, mode (preferred), `wlr_output_layout`, model `Output` rect kept in sync
- [x] `wl_compositor`, `wl_subcompositor`, `wl_shm` (via renderer), `wl_data_device_manager`, primary selection
- [x] xdg-shell: toplevels, popups (unconstrained to the monitor), configure/ack cycle, xdg-decoration (`prefer_no_csd`)
- [x] Seat: keyboard (xkb, env layout), pointer, cursor, xcursor theme, cursor-shape-v1
- [x] Focus: keyboard focus follows the model (`seat.focused`, decided in `manage.resolveFocus`)
- [x] Keybindings dispatched from the existing Lua config (`keys.find` -> `wm.commands` -> `action.run`)
- [x] Clean exit (`exit` command), SIGINT/SIGTERM, `SIGHUP` reload
- [x] VT switching (`XF86Switch_VT_n`), session via `Backend.autocreate`, libinput devices (keyboard, pointer)
- [ ] Run it: nested, then from a TTY (open until someone has wlroots 0.20)
- [ ] libinput settings (tap, natural scroll): no option in config.lua yet
- [ ] Only keyboard and pointer are used; touch, tablet, switches are ignored

Also done beyond the list: window placement, tiling, borders, fullscreen requests and multi-output migration
already work through the model (`manage.zig`), so milestone B starts from a working base.
Known gaps: DockApps (`dockapp:<n>`) are treated as normal windows until `dockhost` is split; no animations;
`request_move/resize` are ignored; `monitor()` rules/profiles are not applied; no layer-shell, so no panels yet.

## 3. Tiling parity (milestone B: replaces river for daily layout)

- [ ] Feed `layout.zig` results into scene nodes (position, size, borders)
- [ ] Column strip scrolling, floating, fullscreen, maximize
- [ ] Workspaces, omnipresent windows, minimize/restore
- [ ] Move/resize with pointer (state machine `idle -> requested -> running -> ending`)
- [ ] Client requests: move, resize, maximize, fullscreen, minimize, `set_app_id`, `set_title`
- [ ] `WMWindowAttributes` per `app_id` still applied on first placement
- [ ] Animations driven directly (no manage/render roundtrip)
- [ ] Layer-shell server (`wlr-layer-shell`): panels, exclusive zones, work area
- [ ] Multi-monitor: hotplug, rules, profiles, `focus/move to output`

## 4. Shell parts (milestone C: Window Maker feel)

- [ ] Root menu as scene buffers (cairo -> `wlr_scene_buffer`)
- [ ] Window list menu, window menus
- [ ] Dock and Clip surfaces, hit testing, drag
- [ ] DockApps: adopt `dockapp:<n>` toplevels, place in tile (`dockhost.zig`)
- [ ] Miniaturize animation with real window snapshots
- [ ] Title bars (own drawing) and the `No*` attributes; xdg-decoration (SSD vs CSD)
- [ ] Dock/Clip on every output; several seats

## 5. Desktop integration

- [ ] Clipboard and primary selection
- [ ] xdg-activation, idle-notify, idle-inhibit
- [ ] ext-session-lock (screen locker)
- [ ] wlr-output-management (kanshi, wlr-randr)
- [ ] Screencopy / ext-image-copy-capture (grim, screen sharing via portal)
- [ ] xdg-output, foreign-toplevel (taskbars), gamma control
- [ ] Pointer constraints, relative pointer (games)
- [ ] Tablet, text-input / input-method (only if needed)
- [ ] XWayland (optional, decide later)
- [ ] Portal config (`wlr` portal or own)

## 6. Switch-over

- [ ] Run as real session from TTY for a full week without river
- [ ] `zig build run` starts the wlroots backend, river backend behind an option
- [ ] Update README, `docs/ARCHITECTURE.md`, `docs/TODO.md`
- [ ] Remove `protocol/river-*.xml` and the river backend when no longer needed
- [ ] Re-run benchmarks, tick off the Performance items that became obsolete

## Open questions / risks

- zig-wlroots only binds what river needs; missing pieces mean own bindings or `@cImport`
- wlroots minor releases break API; zig-wlroots tracks one wlroots version at a time
- Distros may not ship wlroots 0.20 yet (build from source or pin via Nix)
- Own compositor means own crash handling: a crash kills the whole session
- Security-sensitive parts (lock screen, screencopy permissions) need care