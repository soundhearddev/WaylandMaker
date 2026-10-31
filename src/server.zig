// SPDX-License-Identifier: GPL-3.0
//
// The compositor: owns the wlroots objects, the protocol globals and the
// event loop, and is the `Sink` the manage pass (manage.zig) talks to.
//
// Everything that happens is one of two things: an event handler edits the
// model and calls `backend.manageDirty`, or the manage pass runs (once per
// turn of the loop, from an idle callback) and tells this file what to do.

const std = @import("std");
const posix = std.posix;
const log = std.log.scoped(.server);

const wayland = @import("wayland");
const wl = wayland.server.wl;
const wlr = @import("wlroots");

const model = @import("model.zig");
const types = model.types;
const backend = @import("backend.zig");
const manage = @import("manage.zig");
const boot = @import("boot.zig");
const diag = @import("diag.zig");
const perf = @import("perf.zig");

const Monitor = @import("output.zig").Monitor;
const View = @import("view.zig").View;
const Popup = @import("view.zig").Popup;
const Decoration = @import("view.zig").Decoration;
const Keyboard = @import("keyboard.zig").Keyboard;
const Cursor = @import("cursor.zig").Cursor;
const DockUi = @import("dock_scene.zig").DockUi;
const layer = @import("layer.zig");
const LayerSurface = layer.LayerSurface;
const libinput = @import("libinput.zig");

pub const Server = struct {
    gpa: std.mem.Allocator,
    wm: *types.WindowManager,

    wl_server: *wl.Server,
    loop: *wl.EventLoop,
    backend: *wlr.Backend,
    /// Null on the nested (wayland/x11) and headless backends.
    session: ?*wlr.Session = null,
    renderer: *wlr.Renderer,
    allocator: *wlr.Allocator,

    scene: *wlr.Scene,
    output_layout: *wlr.OutputLayout,
    scene_output_layout: *wlr.SceneOutputLayout,
    /// Bottom to top: tiled windows, floating windows, fullscreen windows.
    layers: [3]*wlr.SceneTree,
    /// Where the Dock, the Clip and the Drawers are, by their level: `below`
    /// under every window, `above` over the tiled and floating ones but
    /// under a fullscreen window (dock_scene.zig).
    dock_below: *wlr.SceneTree,
    dock_above: *wlr.SceneTree,
    dock_ui: *DockUi = undefined,

    /// wlr-layer-shell: one scene tree per layer (background, bottom, top,
    /// overlay). Background and bottom lie under the windows, top over the
    /// windows but under a fullscreen one, overlay over everything.
    layer_trees: [layer.layer_count]*wlr.SceneTree,
    /// Popups of layer surfaces, above all of it.
    layer_popups: *wlr.SceneTree,
    layer_shell: *wlr.LayerShellV1,
    layer_surfaces: wl.list.Head(LayerSurface, .link) = undefined,
    /// The layer surface that holds the keyboard (a launcher), if any. While
    /// it does, the model's focused window stays `focused` but is not given
    /// the keyboard.
    layer_focus: ?*LayerSurface = null,

    xdg_shell: *wlr.XdgShell,
    seat: *wlr.Seat,
    cursor: Cursor = undefined,
    keyboards: wl.list.Head(Keyboard, .link) = undefined,
    monitors: wl.list.Head(Monitor, .link) = undefined,

    /// The view that has the keyboard focus (the model's `seat.focused`, as
    /// the compositor last set it).
    focused: ?*View = null,
    manage_idle: ?*wl.EventSource = null,
    /// `wm.config_gen` as last applied to the devices (see `applyConfig`).
    applied_config_gen: u32 = 0,
    /// Wakes the loop when monitor changes have been quiet long enough to
    /// apply the rules (`outputs.settle`); armed only while one is pending.
    settle_timer: ?*wl.EventSource = null,
    /// Safety net of the start-up (`beginStartup`): if the environment import
    /// never reports back, the session starts anyway.
    startup_timer: ?*wl.EventSource = null,
    startup_done: bool = false,
    quitting: bool = false,

    new_output: wl.Listener(*wlr.Output) = .init(onNewOutput),
    new_input: wl.Listener(*wlr.InputDevice) = .init(onNewInput),
    new_toplevel: wl.Listener(*wlr.XdgToplevel) = .init(onNewToplevel),
    new_popup: wl.Listener(*wlr.XdgPopup) = .init(onNewPopup),
    new_decoration: wl.Listener(*wlr.XdgToplevelDecorationV1) = .init(onNewDecoration),
    new_layer_surface: wl.Listener(*wlr.LayerSurfaceV1) = .init(onNewLayerSurface),
    layout_change: wl.Listener(*wlr.OutputLayout) = .init(onLayoutChange),
    request_set_cursor: wl.Listener(*wlr.Seat.event.RequestSetCursor) = .init(onRequestSetCursor),
    request_set_selection: wl.Listener(*wlr.Seat.event.RequestSetSelection) = .init(onRequestSetSelection),
    request_set_primary: wl.Listener(*wlr.Seat.event.RequestSetPrimarySelection) = .init(onRequestSetPrimary),

    // ---- life cycle ------------------------------------------------------------

    pub fn create(gpa: std.mem.Allocator, wm: *types.WindowManager) !*Server {
        const server = try gpa.create(Server);
        errdefer gpa.destroy(server);

        const wl_server = try wl.Server.create();
        errdefer wl_server.destroy();
        const loop = wl_server.getEventLoop();

        var session: ?*wlr.Session = null;
        const wlr_backend = try wlr.Backend.autocreate(loop, &session);
        errdefer wlr_backend.destroy();
        const renderer = try wlr.Renderer.autocreate(wlr_backend);
        const output_layout = try wlr.OutputLayout.create(wl_server);
        const scene = try wlr.Scene.create();
        // Created first, so they lie under everything else.
        const layer_background = try scene.tree.createSceneTree();
        const layer_bottom = try scene.tree.createSceneTree();

        server.* = .{
            .gpa = gpa,
            .wm = wm,
            .wl_server = wl_server,
            .loop = loop,
            .backend = wlr_backend,
            .session = session,
            .renderer = renderer,
            .allocator = try wlr.Allocator.autocreate(wlr_backend, renderer),
            .scene = scene,
            .output_layout = output_layout,
            .scene_output_layout = try scene.attachOutputLayout(output_layout),
            .dock_below = try scene.tree.createSceneTree(),
            .layers = .{
                try scene.tree.createSceneTree(),
                try scene.tree.createSceneTree(),
                try scene.tree.createSceneTree(),
            },
            .dock_above = try scene.tree.createSceneTree(),
            .layer_trees = .{
                layer_background,
                layer_bottom,
                try scene.tree.createSceneTree(),
                try scene.tree.createSceneTree(),
            },
            .layer_popups = try scene.tree.createSceneTree(),
            .layer_shell = try wlr.LayerShellV1.create(wl_server, 4),
            .xdg_shell = try wlr.XdgShell.create(wl_server, 6),
            .seat = try wlr.Seat.create(wl_server, "seat0"),
        };
        server.keyboards.init();
        server.monitors.init();
        server.layer_surfaces.init();

        try renderer.initServer(wl_server);
        _ = try wlr.Compositor.create(wl_server, 6, renderer);
        _ = try wlr.Subcompositor.create(wl_server);
        _ = try wlr.DataDeviceManager.create(wl_server);
        _ = try wlr.PrimarySelectionDeviceManagerV1.create(wl_server);
        const decoration = try wlr.XdgDecorationManagerV1.create(wl_server);

        // GPU clients hand over dmabufs; with this the scene can also show a
        // fullscreen client's buffer on the display plane directly (direct
        // scanout: no copy, no compositing, the biggest win for games and video).
        // A renderer without a DRM device (pixman, a VM without a GPU) cannot
        // offer it: that is not a reason to refuse to start, clients then
        // share memory (wl_shm) only.
        if (wlr.LinuxDmabufV1.createWithRenderer(wl_server, 4, renderer)) |dmabuf| {
            scene.setLinuxDmabufV1(dmabuf);
        } else |err| {
            log.warn("no linux-dmabuf ({t}): clients can only share memory", .{err});
        }
        _ = try wlr.Viewporter.create(wl_server);
        _ = try wlr.SinglePixelBufferManagerV1.create(wl_server);
        _ = try wlr.XdgOutputManagerV1.create(wl_server, output_layout);

        try server.cursor.init(server);
        // Created last in the scene, so raised into its place: above the
        // floating windows, below the fullscreen ones.
        server.dock_above.node.placeAbove(&server.layers[1].node);
        // The top layer (panels) is over the windows and the Dock but under
        // a fullscreen window; the overlay layer and the popups stay on top.
        server.layer_trees[2].node.placeAbove(&server.dock_above.node);
        server.dock_ui = try DockUi.create(server);

        wlr_backend.events.new_output.add(&server.new_output);
        wlr_backend.events.new_input.add(&server.new_input);
        output_layout.events.change.add(&server.layout_change);
        server.layer_shell.events.new_surface.add(&server.new_layer_surface);
        server.xdg_shell.events.new_toplevel.add(&server.new_toplevel);
        server.xdg_shell.events.new_popup.add(&server.new_popup);
        decoration.events.new_toplevel_decoration.add(&server.new_decoration);
        server.seat.events.request_set_cursor.add(&server.request_set_cursor);
        server.seat.events.request_set_selection.add(&server.request_set_selection);
        server.seat.events.request_set_primary_selection.add(&server.request_set_primary);

        // The model's view of the compositor.
        wm.obj = backend.handle(backend.WindowManager, server);
        backend.hooks = .{ .manage_dirty = hookManageDirty, .close_window = hookCloseWindow };
        _ = try manage.createSeat(wm, backend.handle(backend.Seat, server));

        try server.addSignals();
        return server;
    }

    /// Order matters: clients first (their windows close in the model), then the
    /// devices and outputs while the model still exists (their destroy handlers
    /// edit it), and only then the model's objects.
    pub fn destroy(server: *Server) void {
        if (server.manage_idle) |s| s.remove();
        server.manage_idle = null;
        if (server.settle_timer) |t| t.remove();
        server.settle_timer = null;
        if (server.startup_timer) |t| t.remove();
        server.startup_timer = null;
        server.wl_server.destroyClients();

        server.new_output.link.remove();
        server.new_input.link.remove();
        server.layout_change.link.remove();
        server.new_toplevel.link.remove();
        server.new_popup.link.remove();
        server.new_decoration.link.remove();
        server.new_layer_surface.link.remove();
        server.request_set_cursor.link.remove();
        server.request_set_selection.link.remove();
        server.request_set_primary.link.remove();
        server.cursor.deinit();

        server.dock_ui.destroy();
        server.scene.tree.node.destroy();
        server.backend.destroy();

        manage.shutdown(server.wm, server.sink());
        server.wl_server.destroy();
        const gpa = server.gpa;
        gpa.destroy(server);
    }

    /// Open the socket clients connect to and export what they (and the
    /// programs we start) need to find it.
    pub fn listen(server: *Server) ![:0]const u8 {
        var buf: [11]u8 = undefined;
        const name = try server.wl_server.addSocketAuto(&buf);
        const stored = try server.gpa.dupeZ(u8, name);
        boot.exportVar("WAYLAND_DISPLAY", stored);
        boot.exportVar("XDG_SESSION_TYPE", "wayland");
        boot.exportVar("XDG_CURRENT_DESKTOP", "wmaker-wl");
        return stored;
    }

    pub fn run(server: *Server) !void {
        try server.backend.start();
        server.scheduleManage();
        server.beginStartup();
        server.wl_server.run();
    }

    // ---- start-up ----------------------------------------------------------------

    /// How long the session waits for the environment import before it starts
    /// without it (the shell has its own `timeout 5`).
    const startup_timeout_ms: i32 = 6000;

    /// The backend is running: the outputs are coming up and the first frame
    /// is on its way. Only now does the D-Bus / systemd environment import
    /// start, in a shell of its own; this process goes on to the event loop
    /// instead of waiting for it. `spawn_at_startup` and READY=1 follow when
    /// it reports back (SIGUSR2, `onStartupDone`), or when
    /// `startup_timeout_ms` has passed.
    fn beginStartup(server: *Server) void {
        if (server.wm.cfg.import_environment and boot.beginEnvironmentImport(server.wm)) {
            const timer = server.loop.addTimer(*Server, onStartupTimer, server) catch {
                // No safety net: the signal is all there is.
                return;
            };
            server.startup_timer = timer;
            timer.timerUpdate(startup_timeout_ms) catch |err| log.warn("start-up timer: {t}", .{err});
            return;
        }
        server.finishStartup();
    }

    /// Once: the programs of `spawn_at_startup`, then READY=1.
    fn finishStartup(server: *Server) void {
        if (server.startup_done) return;
        server.startup_done = true;
        if (server.startup_timer) |t| t.remove();
        server.startup_timer = null;
        boot.finishStartup(server.wm);
    }

    fn onStartupDone(_: c_int, server: *Server) c_int {
        server.finishStartup();
        return 0;
    }

    fn onStartupTimer(server: *Server) c_int {
        if (!server.startup_done) log.warn("the environment import did not report back in {d} ms, starting anyway", .{startup_timeout_ms});
        server.finishStartup();
        return 0;
    }

    // ---- signals -----------------------------------------------------------------

    fn addSignals(server: *Server) !void {
        _ = try server.loop.addSignal(*Server, @intFromEnum(posix.SIG.INT), onTerminate, server);
        _ = try server.loop.addSignal(*Server, @intFromEnum(posix.SIG.TERM), onTerminate, server);
        _ = try server.loop.addSignal(*Server, @intFromEnum(posix.SIG.HUP), onHangup, server);
        _ = try server.loop.addSignal(*Server, @intFromEnum(posix.SIG.USR1), onDump, server);
        // The environment import (boot.beginEnvironmentImport) is done.
        _ = try server.loop.addSignal(*Server, @intFromEnum(posix.SIG.USR2), onStartupDone, server);
    }

    fn onTerminate(_: c_int, server: *Server) c_int {
        log.info("terminating", .{});
        server.wl_server.terminate();
        return 0;
    }

    /// `pkill -HUP wmaker-wl`: reload config.lua in the next manage pass.
    fn onHangup(_: c_int, server: *Server) c_int {
        server.wm.reload_pending = true;
        server.scheduleManage();
        return 0;
    }

    /// `pkill -USR1 wmaker-wl`: write a state dump in the next manage pass.
    fn onDump(_: c_int, server: *Server) c_int {
        diag.requestDump();
        server.scheduleManage();
        return 0;
    }

    // ---- the manage pass ---------------------------------------------------------

    /// At most one pass per turn of the event loop, after the events of that
    /// turn have all been seen.
    pub fn scheduleManage(server: *Server) void {
        if (server.manage_idle != null) return;
        server.manage_idle = server.loop.addIdle(*Server, runManage, server) catch {
            log.err("out of memory: cannot schedule a manage pass", .{});
            return;
        };
    }

    fn runManage(server: *Server) void {
        server.manage_idle = null;
        // The whole pass, what the user waits for: the model (layout and
        // all), the config, the Dock. Feeds `perf` (SIGUSR1 dump) and the
        // slow-pass warning, which had no caller until now.
        const span = perf.start(server.wm.io, .manage);
        defer _ = perf.stop(server.wm.io, span);
        manage.run(server.wm, server.sink(), server.nowMs());
        server.applyConfig();
        // The Dock shows what the pass decided (tiles, workspace, config).
        server.dock_ui.update();
        // Something still moves: ask for the next frame. The pass after it is
        // paced by the monitor (see Monitor.onFrame), so an animation costs
        // one pass per displayed frame and nothing when it ends.
        if (server.wm.anim_active) server.requestFrames();
        server.armSettleTimer();
    }

    /// What of config.lua lives in the devices and not in the model: the key
    /// repeat the clients are told about. Runs after every pass, but does
    /// something only when a (re)load happened since the last time.
    fn applyConfig(server: *Server) void {
        if (server.applied_config_gen == server.wm.config_gen) return;
        server.applied_config_gen = server.wm.config_gen;
        var it = server.keyboards.iterator(.forward);
        while (it.next()) |kb| kb.applyRepeatInfo();
    }

    /// Monitor changes wait for a quiet time before the rules apply: sleep
    /// until then, and nothing at all when no change is pending.
    fn armSettleTimer(server: *Server) void {
        const ms = model.outputs.settleWaitMs(server.wm, server.nowMs()) orelse return;
        const timer = server.settle_timer orelse blk: {
            const t = server.loop.addTimer(*Server, onSettleTimer, server) catch {
                log.err("out of memory: cannot arm the monitor timer", .{});
                return;
            };
            server.settle_timer = t;
            break :blk t;
        };
        // A delay of 0 would disarm the timer.
        timer.timerUpdate(@max(ms, 1)) catch |err| log.warn("monitor timer: {t}", .{err});
    }

    fn onSettleTimer(server: *Server) c_int {
        server.scheduleManage();
        return 0;
    }

    fn requestFrames(server: *Server) void {
        var it = server.monitors.iterator(.forward);
        while (it.next()) |m| m.wlr_output.scheduleFrame();
    }

    fn hookManageDirty(wm_handle: *backend.WindowManager) void {
        backend.from(Server, wm_handle).scheduleManage();
    }

    fn hookCloseWindow(w: *backend.Window) void {
        const view = backend.from(View, w);
        if (view.toplevel) |t| t.sendClose();
    }

    pub fn nowMs(server: *const Server) u64 {
        _ = server;
        var ts: posix.timespec = undefined;
        _ = posix.system.clock_gettime(posix.CLOCK.MONOTONIC, &ts);
        return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / 1_000_000;
    }

    // ---- Sink ----------------------------------------------------------------------

    pub fn sink(server: *Server) manage.Sink {
        return .{ .ctx = server, .vtable = &sink_vtable };
    }

    const sink_vtable: manage.Sink.VTable = .{
        .configure = sinkConfigure,
        .place = sinkPlace,
        .focus = sinkFocus,
        .release = sinkRelease,
        .quit = sinkQuit,
        .warp = sinkWarp,
    };

    fn sinkConfigure(_: *anyopaque, win: *types.Window, c: manage.Configure) void {
        backend.from(View, win.obj).configure(c);
    }

    fn sinkPlace(ctx: *anyopaque, win: *types.Window, p: manage.Placement) void {
        const server: *Server = @ptrCast(@alignCast(ctx));
        backend.from(View, win.obj).place(&server.wm.cfg, p);
    }

    fn sinkFocus(ctx: *anyopaque, win: ?*types.Window) void {
        const server: *Server = @ptrCast(@alignCast(ctx));
        server.focusView(if (win) |w| backend.from(View, w.obj) else null);
    }

    /// The model let go of the window. The view stays: it belongs to the
    /// client's toplevel, which may map again.
    fn sinkRelease(_: *anyopaque, _: *types.Window) void {}

    fn sinkWarp(ctx: *anyopaque, x: i32, y: i32) void {
        const server: *Server = @ptrCast(@alignCast(ctx));
        server.cursor.warpTo(@floatFromInt(x), @floatFromInt(y));
    }

    fn sinkQuit(ctx: *anyopaque) void {
        const server: *Server = @ptrCast(@alignCast(ctx));
        if (server.quitting) return;
        server.quitting = true;
        server.wl_server.terminate();
    }

    /// Keyboard focus to `view` (or nobody), and the activated state of the
    /// toplevels that goes with it.
    pub fn focusView(server: *Server, view: ?*View) void {
        if (server.focused == view) return;
        if (server.focused) |old| {
            if (old.toplevel) |t| _ = t.setActivated(false);
        }
        server.focused = view;

        // A launcher holding the keyboard keeps it; the window is only
        // remembered (and given the keyboard when the launcher goes).
        if (server.layer_focus != null) return;

        const v = view orelse {
            server.seat.keyboardNotifyClearFocus();
            return;
        };
        const toplevel = v.toplevel orelse return;
        _ = toplevel.setActivated(true);
        server.enterKeyboard(toplevel.base.surface);
    }

    /// A layer surface takes the keyboard (null: it lets go and the focused
    /// window gets it back).
    pub fn setLayerFocus(server: *Server, ls: ?*LayerSurface) void {
        if (server.layer_focus == ls) return;
        server.layer_focus = ls;
        if (ls) |l| {
            if (server.focused) |v| if (v.toplevel) |t| {
                _ = t.setActivated(false);
            };
            server.enterKeyboard(l.surface.surface);
            return;
        }
        const v = server.focused orelse {
            server.seat.keyboardNotifyClearFocus();
            return;
        };
        const toplevel = v.toplevel orelse {
            server.seat.keyboardNotifyClearFocus();
            return;
        };
        _ = toplevel.setActivated(true);
        server.enterKeyboard(toplevel.base.surface);
    }

    /// Clicking a window ends a keyboard focus a layer surface was given by a
    /// click; an exclusive grab (launcher, lock) stays.
    pub fn releaseOnDemandFocus(server: *Server) void {
        const ls = server.layer_focus orelse return;
        if (ls.surface.current.keyboard_interactive == .exclusive) return;
        server.setLayerFocus(null);
    }

    /// Hand the keyboard to `surface` (also when a keyboard appears after the
    /// focus was decided).
    pub fn enterKeyboard(server: *Server, surface: *wlr.Surface) void {
        const kb = server.seat.getKeyboard() orelse return;
        server.seat.keyboardNotifyEnter(surface, kb.keycodes[0..kb.num_keycodes], &kb.modifiers);
    }

    // ---- outputs, input, shell -------------------------------------------------------

    fn onNewOutput(listener: *wl.Listener(*wlr.Output), wlr_output: *wlr.Output) void {
        const server: *Server = @fieldParentPtr("new_output", listener);
        Monitor.create(server, wlr_output) catch |err| {
            log.err("cannot use output {s}: {t}", .{ wlr_output.name, err });
        };
    }

    /// The desk changed (output added, removed, moved): tell the model.
    fn onLayoutChange(listener: *wl.Listener(*wlr.OutputLayout), _: *wlr.OutputLayout) void {
        const server: *Server = @fieldParentPtr("layout_change", listener);
        server.syncOutputRects();
    }

    pub fn syncOutputRects(server: *Server) void {
        var it = server.monitors.iterator(.forward);
        while (it.next()) |m| m.syncRect();
        // Where an output lies changed: bars and panels follow.
        layer.arrangeAll(server);
        server.scheduleManage();
    }

    fn onNewInput(listener: *wl.Listener(*wlr.InputDevice), device: *wlr.InputDevice) void {
        const server: *Server = @fieldParentPtr("new_input", listener);
        switch (device.type) {
            .keyboard => Keyboard.create(server, device) catch |err| {
                log.err("cannot use keyboard {?s}: {t}", .{ device.name, err });
                return;
            },
            .pointer => {
                server.cursor.attach(device);
                libinput.configure(&server.wm.cfg, device);
            },
            else => return,
        }
        server.seat.setCapabilities(.{
            .pointer = true,
            .keyboard = server.keyboards.length() > 0,
        });
    }

    fn onNewToplevel(listener: *wl.Listener(*wlr.XdgToplevel), toplevel: *wlr.XdgToplevel) void {
        const server: *Server = @fieldParentPtr("new_toplevel", listener);
        View.create(server, toplevel) catch |err| log.err("cannot create a window: {t}", .{err});
    }

    fn onNewLayerSurface(listener: *wl.Listener(*wlr.LayerSurfaceV1), wlr_ls: *wlr.LayerSurfaceV1) void {
        const server: *Server = @fieldParentPtr("new_layer_surface", listener);
        layer.create(server, wlr_ls);
    }

    fn onNewPopup(listener: *wl.Listener(*wlr.XdgPopup), popup: *wlr.XdgPopup) void {
        const server: *Server = @fieldParentPtr("new_popup", listener);
        Popup.create(server, popup) catch |err| log.err("cannot create a popup: {t}", .{err});
    }

    /// `prefer_no_csd`: we draw the (border) decoration; otherwise the client does.
    fn onNewDecoration(listener: *wl.Listener(*wlr.XdgToplevelDecorationV1), decoration: *wlr.XdgToplevelDecorationV1) void {
        const server: *Server = @fieldParentPtr("new_decoration", listener);
        Decoration.create(server, decoration) catch |err| log.err("cannot create a decoration: {t}", .{err});
    }

    fn onRequestSetCursor(listener: *wl.Listener(*wlr.Seat.event.RequestSetCursor), event: *wlr.Seat.event.RequestSetCursor) void {
        const server: *Server = @fieldParentPtr("request_set_cursor", listener);
        server.cursor.clientSetsCursor(event);
    }

    fn onRequestSetSelection(listener: *wl.Listener(*wlr.Seat.event.RequestSetSelection), event: *wlr.Seat.event.RequestSetSelection) void {
        const server: *Server = @fieldParentPtr("request_set_selection", listener);
        server.seat.setSelection(event.source, event.serial);
    }

    fn onRequestSetPrimary(listener: *wl.Listener(*wlr.Seat.event.RequestSetPrimarySelection), event: *wlr.Seat.event.RequestSetPrimarySelection) void {
        const server: *Server = @fieldParentPtr("request_set_primary", listener);
        server.seat.setPrimarySelection(event.source, event.serial);
    }
};
