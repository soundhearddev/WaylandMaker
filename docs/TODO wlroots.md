# TODO: wlroots compositor

- [ ] Run it: nested, then from a TTY (open until someone has wlroots 0.20)
- [ ] Touch is forwarded to clients (`cursor.zig`: down/up/motion/cancel/frame, up to 10 fingers, a finger keeps reporting to the surface it began on; no gestures, not run). Still ignored: tablets, switches

Also done beyond the list: window placement, tiling, borders, fullscreen requests and multi-output migration
already work through the model (`manage.zig`), so milestone B starts from a working base.
Known gaps (the list above was longer; DockApps, animations, client move/resize and layer-shell are done now):
`monitor()` rules are decided in the model (`outputs.zig`) and applied to the wlroots outputs in `output.zig` (on/off, mode, scale, position; not run).

Performance notes (the priority): a pass places only what changed (`View.last` skips unchanged windows);
animations cost one pass per displayed frame and nothing afterwards; the cursor sets its image only on change;
linux-dmabuf is connected to the scene, so a fullscreen client can be scanned out directly.
Still open: running it on real monitors. (The layer-shell XML is vendored in `protocol/`.)

- [ ] Root menu as scene buffers (cairo -> `wlr_scene_buffer`): the model (`wm_menu.zig`) and the `RootMenu` loader are there, nothing draws or opens it yet. This is the biggest hole of "Window Maker feel"; do it before the title bars
- [ ] Menu input: pointer and keyboard navigation, submenus, `OPEN_MENU` from a file or a command, closing on a click outside
- [ ] Window list menu, window menus
- [ ] Miniaturize animation with real window snapshots (instead of the outline)
- [ ] Title bars (own drawing) and the `No*` attributes; xdg-decoration (SSD vs CSD)
- [ ] Dock/Clip on every output; several seats

- [ ] A clipboard that survives the source client (needs a manager such as `wl-clip-persist`, or our own)
- [ ] wlr-output-management (kanshi, wlr-randr)
- [ ] Screencopy / ext-image-copy-capture (grim, screen sharing via portal): `ext-image-copy-capture` with output sources is served (`protocols.zig`, not run); `wlr-screencopy` and export-dmabuf wait for the wlr-protocols dependency (section 8)
- [ ] foreign-toplevel (taskbars), gamma control  (xdg-output done). `ext-foreign-toplevel-list` is served (title and app_id, `view.zig`, not run); activate/close/minimize from a taskbar need `wlr-foreign-toplevel-management` (wlr-protocols XML, section 8), gamma control too
- [ ] Tablet, text-input / input-method (only if needed)
- [ ] XWayland (optional, decide later)
- [ ] Portal config for screen capture (`wlr` portal) once capture exists

- [ ] **VT switch, suspend and resume**: outputs and input must come back after `Ctrl+Alt+F<N>` and after sleep. `server.zig` now listens to the session's active signal (redraw, manage pass, idle reset); wlroots restores the devices itself. Still to test on a TTY and after suspend
- [ ] **GPU**: multi-GPU, a GPU that disappears, `WLR_RENDERER`/`WLR_DRM_DEVICES` documented
- [ ] **Output power and DPMS**: blank the screen on idle, wake on input (needs idle-notify first)
- [ ] `xdg-dialog`, `xdg-toplevel-icon`, `tearing-control` (games): not served; check which real programs need them. Served now (`protocols.zig`, not run): `xdg-foreign`, `content-type`, `alpha-modifier`, `ext-data-control`
- [ ] `security-context` and who may use which protocol: the manager and a global filter are in `protocols.zig` (sandboxed clients do not see capture, data-control, idle-notify, layer-shell, security-context). Open: input injection, and the wlr-protocols ones once they exist; not run
- [ ] **Client misbehaviour**: a client that does not answer a configure, ignores `ack`, or floods requests must not stall the manage pass (timeouts, per-client limits)
- [ ] A **headless test** (`WLR_BACKENDS=headless`) that opens an output and a client: the compositor half of the code has no test at all, only the model does

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