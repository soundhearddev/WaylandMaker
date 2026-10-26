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

const Monitor = @import("output.zig").Monitor;
const View = @import("view.zig").View;
const Popup = @import("view.zig").Popup;
const Decoration = @import("view.zig").Decoration;
const Keyboard = @import("keyboard.zig").Keyboard;
const Cursor = @import("cursor.zig").Cursor;

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

    xdg_shell: *wlr.XdgShell,
    seat: *wlr.Seat,
    cursor: Cursor = undefined,
    keyboards: wl.list.Head(Keyboard, .link) = undefined,
    monitors: wl.list.Head(Monitor, .link) = undefined,

    /// The view that has the keyboard focus (the model's `seat.focused`, as
    /// the compositor last set it).
    focused: ?*View = null,
    manage_idle: ?*wl.EventSource = null,
    /// Wakes the loop when monitor changes have been quiet long enough to
    /// apply the rules (`outputs.settle`); armed only while one is pending.
    settle_timer: ?*wl.EventSource = null,
    quitting: bool = false,

    new_output: wl.Listener(*wlr.Output) = .init(onNewOutput),
    new_input: wl.Listener(*wlr.InputDevice) = .init(onNewInput),
    new_toplevel: wl.Listener(*wlr.XdgToplevel) = .init(onNewToplevel),
    new_popup: wl.Listener(*wlr.XdgPopup) = .init(onNewPopup),
    new_decoration: wl.Listener(*wlr.XdgToplevelDecorationV1) = .init(onNewDecoration),
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
            .layers = .{
                try scene.tree.createSceneTree(),
                try scene.tree.createSceneTree(),
                try scene.tree.createSceneTree(),
            },
            .xdg_shell = try wlr.XdgShell.create(wl_server, 6),
            .seat = try wlr.Seat.create(wl_server, "seat0"),
        };
        server.keyboards.init();
        server.monitors.init();

        try renderer.initServer(wl_server);
        _ = try wlr.Compositor.create(wl_server, 6, renderer);
        _ = try wlr.Subcompositor.create(wl_server);
        _ = try wlr.DataDeviceManager.create(wl_server);
        _ = try wlr.PrimarySelectionDeviceManagerV1.create(wl_server);
        const decoration = try wlr.XdgDecorationManagerV1.create(wl_server);

        // GPU clients hand over dmabufs; with this the scene can also show a
        // fullscreen client's buffer on the display plane directly (direct
        // scanout: no copy, no compositing, the biggest win for games and video).
        const dmabuf = try wlr.LinuxDmabufV1.createWithRenderer(wl_server, 4, renderer);
        scene.setLinuxDmabufV1(dmabuf);
        _ = try wlr.Viewporter.create(wl_server);
        _ = try wlr.SinglePixelBufferManagerV1.create(wl_server);
        _ = try wlr.XdgOutputManagerV1.create(wl_server, output_layout);

        try server.cursor.init(server);

        wlr_backend.events.new_output.add(&server.new_output);
        wlr_backend.events.new_input.add(&server.new_input);
        output_layout.events.change.add(&server.layout_change);
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
        server.wl_server.destroyClients();

        server.new_output.link.remove();
        server.new_input.link.remove();
        server.layout_change.link.remove();
        server.new_toplevel.link.remove();
        server.new_popup.link.remove();
        server.new_decoration.link.remove();
        server.request_set_cursor.link.remove();
        server.request_set_selection.link.remove();
        server.request_set_primary.link.remove();
        server.cursor.deinit();

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
        server.wl_server.run();
    }

    // ---- signals -----------------------------------------------------------------

    fn addSignals(server: *Server) !void {
        _ = try server.loop.addSignal(*Server, @intFromEnum(posix.SIG.INT), onTerminate, server);
        _ = try server.loop.addSignal(*Server, @intFromEnum(posix.SIG.TERM), onTerminate, server);
        _ = try server.loop.addSignal(*Server, @intFromEnum(posix.SIG.HUP), onHangup, server);
        _ = try server.loop.addSignal(*Server, @intFromEnum(posix.SIG.USR1), onDump, server);
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
        manage.run(server.wm, server.sink(), server.nowMs());
        // Something still moves: ask for the next frame. The pass after it is
        // paced by the monitor (see Monitor.onFrame), so an animation costs
        // one pass per displayed frame and nothing when it ends.
        if (server.wm.anim_active) server.requestFrames();
        server.armSettleTimer();
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

        const v = view orelse {
            server.seat.keyboardNotifyClearFocus();
            return;
        };
        const toplevel = v.toplevel orelse return;
        _ = toplevel.setActivated(true);
        server.enterKeyboard(toplevel.base.surface);
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
        server.scheduleManage();
    }

    fn onNewInput(listener: *wl.Listener(*wlr.InputDevice), device: *wlr.InputDevice) void {
        const server: *Server = @fieldParentPtr("new_input", listener);
        switch (device.type) {
            .keyboard => Keyboard.create(server, device) catch |err| {
                log.err("cannot use keyboard {?s}: {t}", .{ device.name, err });
                return;
            },
            .pointer => server.cursor.attach(device),
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
