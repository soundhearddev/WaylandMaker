# TODO: wlroots compositor

wmaker-wl is its own compositor on wlroots; river is gone from the tree (branch `river_abandon_test`).
Bindings: `zig-wlroots` 0.20.x (needs Zig 0.16, wlroots 0.20, zig-wayland, zig-xkbcommon, zig-pixman).

Rules:
- Model code (`types`, `layout`, `workspace`, `action`, `config`, `manage`, `keys`, `wm_*`, `monitors`, ...) must not
  import wlroots. Only `main`, `server`, `output`, `view`, `keyboard`, `cursor`, `probe` do.
- `zig build test` must pass on a machine without wlroots.

## 0. Probe

- [x] `zig build probe` runs on real wlroots 0.20.2 (backend, renderer, allocator come up)

## 1. River removed, model split from the compositor

- [x] `main`, `window`, `output`, `seat`, `backend_river`, `protocol/river-*.xml` deleted
- [x] The river-bound UI (root menu, window list, Dock, Clip, miniaturize animation, drawing code) moved to `attic/`;
      it is not built. It is what section 4 ports.
- [x] Tests that needed river or the UI code were dropped (7 in `model_test.zig`: Dock/DockApp adoption,
      `hide_others`; 2 fuzz tests for XPM and OPEN_MENU specs); the ones about placement, focus and floating
      now run against `manage.zig`
- [x] `types.zig` lost the river-shaped parts (`XkbBinding`, `PointerBinding`, `WlOutput`, `ui`, `layer_shell`)
- [x] One module, one build: `zig build` (wmaker-wl + wlprefs), `zig build test`, `zig build probe`, `zig build run`
- [x] The Dock model (`dock_model.zig`) and the DockApp adoption (`dockhost.zig`) are on the model and tested; `manage.run` adopts,
      updates and places them every pass. The compositor has to set `wm.dock_shown` once it draws the Dock (until then it reserves no room)
- [x] `compatibility.zig` deleted; `obj_version` and `UiAction` (river leftovers) removed
- [x] Monitor rules, profiles and window homes are back as `outputs.zig` (model, tested in `manage.zig` and `diag_test.zig`); the
      compositor still has to apply what they decide to the wlroots outputs (on/off, mode, scale, position)

## 2. Minimal compositor (milestone A: can type in a terminal)

Status: written in `src/`, **compiled and linked against the zig-wlroots 0.20.1 bindings, not yet run**
(no wlroots 0.20 in the build sandbox). All 89 `wlr_*` symbols it uses exist in wlroots' headers. First real test:
`zig build run` nested in a running session (or `WLR_BACKENDS=wayland ./zig-out/bin/wmaker-wl`), then from a TTY.
Build needs wayland-protocols >= 1.44 (or `-Dcolor-manager-version=1`).

Files: `main` (entry) `cli` `boot` (config/env, no wlroots) `server` (globals, loop, `Sink`) `output` `view` (xdg toplevel, popup)
`keyboard` `cursor` `keys` (bind matching, no wlroots) `manage` (the manage pass, no wlroots) `probe`.
`keys`, `manage`, `pointer_op`, `cli` have tests: `zig build test`.

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
`request_move/resize` are ignored; `monitor()` rules/profiles are decided in the model (`outputs.zig`) but not yet applied to the wlroots outputs; no layer-shell, so no panels yet.

## 3. Tiling parity (milestone B: daily layout)

- [x] Feed `layout.zig` results into scene nodes (position, size, borders)  (code + tests, not run)
- [x] Column strip scrolling, floating, fullscreen, maximize  (code + tests, not run)
- [x] Workspaces, omnipresent windows, minimize/restore  (code + tests, not run)
- [x] Move/resize with pointer (state machine `idle -> requested -> running -> ending`): `pointer_op.zig`, mouse_mod + button, and client requests
- [x] Client requests: move, resize, maximize, fullscreen, minimize, `set_app_id`, `set_title`
- [x] `WMWindowAttributes` per `app_id` applied on first placement (and when app_id changes later)
- [x] Animations driven directly: `src/motion.zig` (shared model code), one pass per displayed frame (`Monitor.onFrame`), nothing when idle
- [ ] Layer-shell server (`wlr-layer-shell`): panels, exclusive zones, work area
- [ ] Multi-monitor: hotplug, rules, profiles, `focus/move to output`

Performance notes (the priority): a pass places only what changed (`View.last` skips unchanged windows);
animations cost one pass per displayed frame and nothing afterwards; the cursor sets its image only on change;
linux-dmabuf is connected to the scene, so a fullscreen client can be scanned out directly.
Still open: layer-shell (`wlr-layer-shell` XML is not in wayland-protocols; needs the protocol file in `protocol/`),
monitor rules/profiles, focus/move to output with the wlroots outputs.

## 4. Shell parts (milestone C: Window Maker feel)

- [ ] Root menu as scene buffers (cairo -> `wlr_scene_buffer`)
- [ ] Window list menu, window menus
- [ ] Dock and Clip surfaces, hit testing, drag
- [x] DockApps: adopted and placed in their tile by the model (`dockhost.zig`); the Dock around them is still to be drawn
- [ ] Miniaturize animation with real window snapshots
- [ ] Title bars (own drawing) and the `No*` attributes; xdg-decoration (SSD vs CSD)
- [ ] Dock/Clip on every output; several seats

## 5. Desktop integration

- [ ] Clipboard and primary selection
- [ ] xdg-activation, idle-notify, idle-inhibit
- [ ] ext-session-lock (screen locker)
- [ ] wlr-output-management (kanshi, wlr-randr)
- [ ] Screencopy / ext-image-copy-capture (grim, screen sharing via portal)
- [ ] foreign-toplevel (taskbars), gamma control  (xdg-output done)
- [ ] Pointer constraints, relative pointer (games)
- [ ] Tablet, text-input / input-method (only if needed)
- [ ] XWayland (optional, decide later)
- [ ] Portal config (`wlr` portal or own)

## 6. Switch-over

- [ ] Run as a real session from a TTY for a full week
- [x] `zig build run` starts the compositor
- [x] README, `docs/ARCHITECTURE.md` and the other docs describe the wlroots build
- [x] `protocol/river-*.xml` and the river backend removed
- [ ] Re-run benchmarks, tick off the Performance items in `docs/TODO.md` that became obsolete

## Open questions / risks

- zig-wlroots binds most of wlroots, but not `wlr-layer-shell`'s protocol XML (it is not in wayland-protocols): it has to be added under `protocol/`
- wlroots minor releases break API; zig-wlroots tracks one wlroots version at a time
- Distros may not ship wlroots 0.20 yet (build from source or pin via Nix)
- Own compositor means own crash handling: a crash kills the whole session
- Security-sensitive parts (lock screen, screencopy permissions) need care