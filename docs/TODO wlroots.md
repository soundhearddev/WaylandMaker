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
- [x] libinput settings (tap, natural scroll): `tap_to_click`, `natural_scroll` in config.lua (`libinput.zig`)
- [ ] More libinput settings: acceleration profile and speed, click method, disable-while-typing, per device
- [ ] Only keyboard and pointer are used; touch, tablet, switches are ignored

Also done beyond the list: window placement, tiling, borders, fullscreen requests and multi-output migration
already work through the model (`manage.zig`), so milestone B starts from a working base.
Known gaps (the list above was longer; DockApps, animations, client move/resize and layer-shell are done now):
`monitor()` rules/profiles are decided in the model (`outputs.zig`) but not yet applied to the wlroots outputs (on/off, mode, scale, position).

## 3. Tiling parity (milestone B: daily layout)

- [x] Feed `layout.zig` results into scene nodes (position, size, borders)  (code + tests, not run)
- [x] Column strip scrolling, floating, fullscreen, maximize  (code + tests, not run)
- [x] Workspaces, omnipresent windows, minimize/restore  (code + tests, not run)
- [x] Move/resize with pointer (state machine `idle -> requested -> running -> ending`): `pointer_op.zig`, mouse_mod + button, and client requests
- [x] Client requests: move, resize, maximize, fullscreen, minimize, `set_app_id`, `set_title`
- [x] `WMWindowAttributes` per `app_id` applied on first placement (and when app_id changes later)
- [x] Animations driven directly: `src/motion.zig` (shared model code), one pass per displayed frame (`Monitor.onFrame`), nothing when idle
- [x] Layer-shell server (`wlr-layer-shell`, `layer.zig`): panels, exclusive zones, work area, keyboard interactivity  (not run)
- [ ] Multi-monitor: hotplug, rules, profiles, `focus/move to output`

Performance notes (the priority): a pass places only what changed (`View.last` skips unchanged windows);
animations cost one pass per displayed frame and nothing afterwards; the cursor sets its image only on change;
linux-dmabuf is connected to the scene, so a fullscreen client can be scanned out directly.
Still open: monitor rules/profiles and focus/move to output with the wlroots outputs. (The layer-shell XML is vendored in `protocol/`.)

## 4. Shell parts (milestone C: Window Maker feel)

- [ ] Root menu as scene buffers (cairo -> `wlr_scene_buffer`): the model (`wm_menu.zig`) and the `RootMenu` loader are there, nothing draws or opens it yet. This is the biggest hole of "Window Maker feel"; do it before the title bars
- [ ] Menu input: pointer and keyboard navigation, submenus, `OPEN_MENU` from a file or a command, closing on a click outside
- [ ] Window list menu, window menus
- [x] Dock and Clip surfaces, hit testing, drag (`dock_scene.zig`, `dock_input.zig`, `dock_sync.zig`; not run)
- [x] DockApps: adopted and placed in their tile by the model (`dockhost.zig`); the Dock around them is drawn by `dock_scene.zig`
- [ ] Miniaturize animation with real window snapshots
- [ ] Title bars (own drawing) and the `No*` attributes; xdg-decoration (SSD vs CSD)
- [ ] Dock/Clip on every output; several seats

## 5. Desktop integration

- [x] Clipboard and primary selection (`wl_data_device_manager`, `primary-selection`)
- [ ] A clipboard that survives the source client (needs a manager such as `wl-clip-persist`, or our own)
- [ ] xdg-activation, idle-notify, idle-inhibit
- [ ] ext-session-lock (screen locker)
- [ ] wlr-output-management (kanshi, wlr-randr)
- [ ] Screencopy / ext-image-copy-capture (grim, screen sharing via portal)
- [ ] foreign-toplevel (taskbars), gamma control  (xdg-output done)
- [ ] Pointer constraints, relative pointer (games)
- [ ] Tablet, text-input / input-method (only if needed)
- [ ] XWayland (optional, decide later)
- [x] Portal config: `wmaker-wl-portals.conf` (GTK backend), installed with the session
- [ ] Portal config for screen capture (`wlr` portal) once capture exists

## 6. Switch-over

- [ ] Run as a real session from a TTY for a full week (the session itself: [SESSION.md](SESSION.md), [TODO.md](TODO.md))
- [ ] Run it at all with wlroots 0.20: nothing in this file has been seen on a screen
- [x] `zig build run` starts the compositor
- [x] README, `docs/ARCHITECTURE.md` and the other docs describe the wlroots build
- [x] `protocol/river-*.xml` and the river backend removed
- [ ] Re-run benchmarks, tick off the Performance items in `docs/TODO.md` that became obsolete

## Open questions / risks

- `protocol/wlr-layer-shell-unstable-v1.xml` is a copy of someone else's file that has to be kept in step by hand: replace it, see section 8
- wlroots minor releases break API; zig-wlroots tracks one wlroots version at a time
- Distros may not ship wlroots 0.20 yet (build from source or pin via Nix)
- Own compositor means own crash handling: a crash kills the whole session
- Security-sensitive parts (lock screen, screencopy permissions) need care
- `wp_color_manager_v1` needs wayland-protocols >= 1.44 (`-Dcolor-manager-version`): that version choice is a build option nobody should have to know; probe it, or drop the protocol until something uses it
- The build is not reproducible offline: the dependencies come from codeberg and github; vendor them or give `zig fetch` hashes a mirror

## 7. Hardening and missing basics (found in review)

Not in any list above, and the first things real programs and real hardware will hit:

- [ ] **Fractional scale** (`wp_fractional_scale_v1`) and `wp_presentation`: not created in `server.zig`. HiDPI clients render blurry or at the wrong size, and video players lose frame timing. `scale.zig` has the model side
- [ ] **VT switch, suspend and resume**: outputs and input must come back after `Ctrl+Alt+F<N>` and after sleep (libseat session active/inactive; no handler in `server.zig`)
- [ ] **GPU**: multi-GPU, a GPU that disappears, `WLR_RENDERER`/`WLR_DRM_DEVICES` documented
- [ ] **Output power and DPMS**: blank the screen on idle, wake on input (needs idle-notify first)
- [ ] `xdg-dialog`, `xdg-toplevel-icon`, `xdg-foreign`, `content-type`, `tearing-control` (games), `alpha-modifier`, `ext-data-control` (clipboard managers): none served; check which real programs need them
- [ ] `security-context` and who may use which protocol: screencopy, input injection and the layer-shell keyboard grab must not be open to every client
- [ ] **Client misbehaviour**: a client that does not answer a configure, ignores `ack`, or floods requests must not stall the manage pass (timeouts, per-client limits)
- [ ] **Frame pacing**: the 16 ms animation timer should follow the output's refresh (`wlr_output` presentation time), not a constant
- [ ] **Cursor**: hide while typing, theme and size from `XCURSOR_*`/config, per-output scale
- [ ] **Error paths**: `Server.create` and `Monitor.create` failures leave the session without a screen; log the reason on the TTY and exit with a code the session script can name
- [ ] A **headless test** (`WLR_BACKENDS=headless`) that opens an output and a client: the compositor half of the code has no test at all, only the model does

## 8. Protocol files: no copies in the tree

Today `protocol/` holds a copy of `wlr-layer-shell-unstable-v1.xml`, and `build.zig` runs the zig-wayland scanner over
it plus a dozen system XML files, generating a binding layer on top of the one zig-wlroots already is. The copy is the
ugly part: it can drift from upstream and from the wlroots we link, and nobody notices until a protocol version
mismatch shows up at runtime. Options, best first:

- [ ] **Take the XML from where it lives, pinned, and delete `protocol/`.** `wlr-protocols` is a normal repository: add it
      to `build.zig.zon` like zig-wlroots (`zig fetch --save <tarball-url>` writes the hash) and use
      `b.dependency("wlr_protocols", .{}).path("unstable/wlr-layer-shell-unstable-v1.xml")` in
      `scanner.addCustomProtocol`. Nothing is copied, the version is a line in the `.zon`, an update is one command.
      Every other protocol already comes from the system's wayland-protocols, so this is the same idea.
- [ ] Alternative without a dependency: read it from the distro package (`wlr-protocols`, `pkg-config --variable=pkgdatadir
      wlr-protocols`) like the other XML files. Cheaper, but it adds a system package that Debian-based systems do not
      always have and ties the build to whatever version is installed. Only if the `.zon` route is unwanted.
- [ ] **Ask zig-wlroots to export what it needs.** The Zig types of `wlr.LayerShellV1` refer to the generated
      `zwlr_layer_*` types, so the XML is required only to name them. If the binding generated those itself (or took the
      scanner from the same place), the application would need no protocol list at all. Worth an upstream issue or patch,
      and it would also drop the long `scanner.generate(...)` block in `build.zig`.
- [ ] Check which of the `scanner.generate` lines are still used by code (`wp_color_manager_v1`, `zwp_tablet_manager_v2`,
      `wp_single_pixel_buffer_manager_v1`, ...) and remove the rest: every line is generated code to compile and a
      protocol version to keep in step.
- [ ] Not recommended: dropping the scanner and importing the wlroots C headers directly (translate-c). It removes the
      generated layer but replaces it with C types and manual wrappers everywhere.

