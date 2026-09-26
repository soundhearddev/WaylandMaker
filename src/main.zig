// SPDX-License-Identifier: 0BSD
//
// wmaker-wl: a scrollable-tiling window manager client for river.
//
// The protocol loop (river-window-management-v1):
//
//   events ... -> manage_start -> [management + rendering requests]
//              -> manage_finish -> (river configures clients)
//              -> render_start -> [rendering requests] -> render_finish
//
// Rendering state may be sent in BOTH sequences; it only takes effect at
// render_finish. So position and borders are sent in manage_start next to
// propose_dimensions, which gives frame-perfect updates. render_start only
// has to correct windows whose size the client changed on its own.
//
// Rules this file enforces:
//   * every manage_start is answered with manage_finish, on every path;
//   * every render_start is answered with render_finish;
//   * management requests are only made from onManage().

const std = @import("std");
const wayland = @import("wayland");
const wl = wayland.client.wl;
const river = wayland.client.river;
const wp = wayland.client.wp;

const root = @import("root.zig");

const types = root.types;
const config = root.config;
const layout = root.layout;
const workspace = root.workspace;
const window_mod = root.window;
const output_mod = root.output;
const seat_mod = root.seat_mod;
const action = root.action;
const wm_files = root.wm_files;
const proc = root.proc;
const ui_mod = root.ui;

const WindowManager = types.WindowManager;

test {
    // Pull in the test blocks of every module.
    _ = config;
    _ = layout;
    _ = workspace;
    _ = window_mod;
    _ = seat_mod;
    _ = output_mod;
    _ = action;
    _ = @import("plist.zig");
    _ = @import("wm_menu.zig");
    _ = @import("wm_attr.zig");
    _ = wm_files;
    _ = @import("model_test.zig");
    _ = @import("gfx.zig");
    _ = @import("shm.zig");
    _ = ui_mod;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    ignoreSigchld();

    const wm = try gpa.create(WindowManager);
    defer gpa.destroy(wm);

    var cfg = try config.load(io, gpa);
    wm.* = .{
        .gpa = gpa,
        .io = io,
        .cfg = cfg,
        .obj = undefined,
        .obj_version = 0,
        .outputs = undefined,
        .windows = undefined,
        .seats = undefined,
    };
    // `cfg` was copied into `wm`; from here on only wm.cfg owns the arena.
    cfg = undefined;
    defer wm.cfg.deinit();
    wm.outputs.init();
    wm.windows.init();
    wm.seats.init();
    defer wm.pending.deinit(gpa);
    action.global = wm;

    // Key-binding commands, root menu, and per-application rules: parsed
    // together because they share wm.cfg's arena (see reloadConfig's
    // loadFromConfig doc comment, which this also uses on SIGHUP).
    const autostart_path = loadStartup(wm) catch return error.ConfigLoadFailed;

    const display = wl.Display.connect(null) catch {
        std.log.err("cannot connect to the wayland display. wmaker-wl is not started " ++
            "directly: run `river -c wmaker-wl`", .{});
        std.process.exit(1);
    };
    defer display.disconnect();

    const registry = try display.getRegistry();
    var bound_wm = false;
    var ctx: RegistryCtx = .{ .wm = wm, .bound_wm = &bound_wm };
    registry.setListener(*RegistryCtx, registryListener, &ctx);

    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;
    if (!bound_wm) {
        std.log.err("this compositor does not offer river_window_manager_v1. " ++
            "wmaker-wl needs river >= 0.4 with the window management protocol: " ++
            "run `river -c wmaker-wl`", .{});
        std.process.exit(1);
    }
    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

    var ui_state: ui_mod.Ui = undefined;
    if (ctx.compositor != null and ctx.shm != null) {
        ui_state = ui_mod.Ui.init(wm, ctx.compositor.?, ctx.shm.?);
        ui_state.cursor_shape_manager = ctx.cursor_shape_manager;
        if (ctx.cursor_shape_manager == null) {
            std.log.warn("no wp_cursor_shape_manager_v1: the pointer will not switch to an arrow over the menu", .{});
        }
        if (ctx.seat) |sd| {
            ui_state.setSeat(sd);
            ctx.ui = &ui_state;
            // Capabilities that arrived before the Ui existed.
            ui_state.onCapabilities(ctx.seat_pointer, ctx.seat_keyboard);
        } else {
            std.log.warn("no wl_seat: root menu cannot receive clicks", .{});
        }
        wm.ui = &ui_state;
        std.log.info("root menu ready: right click on the empty desktop", .{});
    } else {
        std.log.warn("root menu disabled: wl_compositor={} wl_shm={}", .{ ctx.compositor != null, ctx.shm != null });
    }
    defer if (wm.ui) |u| u.deinit();

    std.log.info("wmaker-wl running (config: {s})", .{wm.cfg.config_file});
    // Window Maker's autostart: one script, run once, detached. Run through
    // /bin/sh so it works whether or not the file is marked executable; a
    // shebang line is just a `#` comment to sh and is harmless either way.
    if (autostart_path) |p| {
        std.log.info("autostart: running {s}", .{p});
        proc.spawn(wm, &.{ "/bin/sh", p });
    }

    installSighupHandler();
    while (!wm.quit) {
        const err = display.dispatch();
        if (err == .INTR) {
            // A signal interrupted the blocking read. SIGCHLD is ignored
            // and needs nothing; SIGHUP only set a flag (see
            // installSighupHandler's doc comment) and needs a manage
            // sequence to actually apply it. manage_dirty() is a normal
            // Wayland request, so it must be sent from here, not from the
            // signal handler itself.
            if (reload_requested.load(.monotonic)) wm.obj.manageDirty();
            continue;
        }
        if (err != .SUCCESS) break;
    }

    if (wm.quit) {
        // exit_session needs protocol version 4; older river versions only
        // support stopping the window manager.
        if (wm.obj_version >= 4) wm.obj.exitSession() else wm.obj.stop();
        _ = display.flush();
    }
}

fn ignoreSigchld() void {
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.CHLD, &act, null);
}

// ----------------------------------------------------------------------------
// Config reload (SIGHUP)
// ----------------------------------------------------------------------------
//
// The handler itself must be async-signal-safe, so it only sets a flag; the
// actual reload (re-parsing the file, replacing bindings) needs allocation
// and river requests, neither of which is safe or legal inside a signal
// handler (`enable`/`destroy` on a binding is management state: manage
// sequence only, same rule as everywhere else in this file).
//
// Without `SA_RESTART`, the blocking syscall inside display.dispatch()
// returns EINTR when the signal arrives, so the main loop wakes up on its
// own; it just has to not treat EINTR as a fatal error (see the loop below).

var reload_requested = std.atomic.Value(bool).init(false);

fn onSighup(_: std.os.linux.SIG) callconv(.c) void {
    reload_requested.store(true, .monotonic);
}

fn installSighupHandler() void {
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = onSighup },
        .mask = std.posix.sigemptyset(),
        .flags = 0, // no SA_RESTART: dispatch() must see EINTR
    };
    std.posix.sigaction(.HUP, &act, null);
}

/// Re-read the config file and swap it into `wm`, replacing every seat's key
/// bindings. Layout, running windows, and the root menu are untouched: this
/// only affects what config.zig actually owns (see its doc comment) plus the
/// bindings derived from it. Must run inside a manage sequence: it destroys
/// and (re)creates `river_xkb_binding_v1` objects, which `enable`/`destroy`
/// require.
///
/// A parse failure never touches the running config: config.load() itself
/// only fails on OOM, and a broken user file already falls back to the
/// built-in defaults with a warning (see config.zig), so there is nothing
/// further to roll back here.
fn reloadConfig(wm: *WindowManager) void {
    const new_cfg = config.load(wm.io, wm.gpa) catch |err| {
        std.log.err("config reload: {t}, keeping the current configuration", .{err});
        return;
    };

    // A key press just before the SIGHUP arrived queues a Command (see
    // seat.xkbListener) before returning to onManage(), which runs THIS
    // function before it gets to runPending(). A `.spawn` command holds
    // `[]const []const u8` argv slices allocated from the CURRENT config's
    // arena. Once that arena is freed below, those slices would dangle
    // while still queued. Running the queue now, on the config that
    // produced it, avoids that; runPending() later in onManage() then
    // simply finds nothing left.
    runPending(wm);

    var sit = wm.seats.first();
    while (sit) |s| : (sit = types.nextSeat(s, wm)) {
        seat_mod.teardownBindings(wm, s);
    }

    var old_cfg = wm.cfg;
    wm.cfg = new_cfg;
    if (loadFromConfig(wm)) {
        old_cfg.deinit();
        rebind(wm);
        std.log.info("config reloaded: {s} ({d} binds)", .{ wm.cfg.config_file, wm.cfg.binds.len });
    } else {
        // Something under the new config's arena failed (OOM, most likely):
        // revert wholesale rather than leave wm.commands/root_menu/attrs
        // partially pointing into an arena we're about to free.
        wm.cfg.deinit();
        wm.cfg = old_cfg;
        _ = loadFromConfig(wm); // best effort; wm.commands defaults to &.{} below if even this fails
        rebind(wm);
    }
}

/// Everything derived from `wm.cfg` that must be (re)built together,
/// because it all lives in `wm.cfg.arena` and `main()` and `reloadConfig()`
/// both need the exact same steps. `wm.root_menu` and `wm.attrs` are
/// included even though they come from separate files (`RootMenu`,
/// `WMWindowAttributes`): `wm_files.load()` allocates them from the same
/// arena as `wm.commands`, so leaving them behind on reload would turn them
/// into dangling pointers the moment the old arena is freed. An already
/// open menu is unaffected: opening a menu deep-copies it into `Ui`'s own
/// arena (see ui.zig's buildLevel/zdup), it never keeps `wm.root_menu`
/// itself around.
///
/// Returns false (leaving `wm.commands` as `&.{}`) on failure, so the
/// caller can decide whether to revert instead of running with an empty or
/// half-built config.
fn loadFromConfig(wm: *WindowManager) bool {
    _ = loadFromConfigImpl(wm) catch |err| {
        std.log.err("config reload: {t}", .{err});
        wm.commands = &.{};
        return false;
    };
    return true;
}

/// Startup-only counterpart of `loadFromConfig`: same arena-sharing rule,
/// plus the autostart file path, which only `main()` needs (a reload must
/// not relaunch the terminal/panel/etc. a second time).
fn loadStartup(wm: *WindowManager) !?[]const u8 {
    return try loadFromConfigImpl(wm);
}

fn loadFromConfigImpl(wm: *WindowManager) !?[]const u8 {
    const arena = wm.cfg.arena.allocator();
    wm.commands = try action.parseAll(arena, &wm.cfg);
    const files = try wm_files.load(wm.io, arena, &wm.cfg);
    wm.root_menu = files.root_menu;
    wm.attrs = files.attributes;
    return files.autostart;
}

fn rebind(wm: *WindowManager) void {
    var sit = wm.seats.first();
    while (sit) |s| : (sit = types.nextSeat(s, wm)) {
        if (wm.xkb_bindings != null) seat_mod.setupBindings(wm, s);
    }
}

// ----------------------------------------------------------------------------
// Registry
// ----------------------------------------------------------------------------

const RegistryCtx = struct {
    wm: *WindowManager,
    bound_wm: *bool,
    compositor: ?*wl.Compositor = null,
    shm: ?*wl.Shm = null,
    seat: ?*wl.Seat = null,
    cursor_shape_manager: ?*wp.CursorShapeManagerV1 = null,
    /// Set once the Ui exists; capability changes are forwarded to it.
    ui: ?*ui_mod.Ui = null,
    seat_pointer: bool = false,
    seat_keyboard: bool = false,
};

/// Listens from the moment the seat is bound: the `capabilities` event is
/// sent immediately and would be lost with a listener set after roundtrip().
fn seatListener(_: *wl.Seat, event: wl.Seat.Event, ctx: *RegistryCtx) void {
    switch (event) {
        .capabilities => |c| {
            ctx.seat_pointer = c.capabilities.pointer;
            ctx.seat_keyboard = c.capabilities.keyboard;
            if (ctx.ui) |u| u.onCapabilities(ctx.seat_pointer, ctx.seat_keyboard);
        },
        else => {},
    }
}

fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, ctx: *RegistryCtx) void {
    const wm = ctx.wm;
    switch (event) {
        .global => |g| {
            const name = std.mem.span(g.interface);
            const eql = std.mem.eql;

            if (eql(u8, name, std.mem.span(river.WindowManagerV1.interface.name))) {
                const version = @min(g.version, 6);
                const obj = registry.bind(g.name, river.WindowManagerV1, version) catch |err| {
                    std.log.err("bind river_window_manager_v1: {t}", .{err});
                    return;
                };
                wm.obj = obj;
                wm.obj_version = version;
                ctx.bound_wm.* = true;
                obj.setListener(*WindowManager, wmListener, wm);
            } else if (eql(u8, name, std.mem.span(river.XkbBindingsV1.interface.name))) {
                wm.xkb_bindings = registry.bind(g.name, river.XkbBindingsV1, 1) catch |err| {
                    std.log.err("bind river_xkb_bindings_v1: {t}", .{err});
                    return;
                };
            } else if (eql(u8, name, std.mem.span(river.LayerShellV1.interface.name))) {
                const ls = registry.bind(g.name, river.LayerShellV1, 1) catch |err| {
                    std.log.err("bind river_layer_shell_v1: {t}", .{err});
                    return;
                };
                wm.layer_shell = ls;
                // Outputs that were announced before this global.
                var it = wm.outputs.first();
                while (it) |o| : (it = types.nextOutput(o, wm)) output_mod.bindLayerShell(wm, ls, o);
            } else if (eql(u8, name, std.mem.span(wl.Compositor.interface.name))) {
                // createSurface exists since version 1; 4 adds damage_buffer.
                ctx.compositor = registry.bind(g.name, wl.Compositor, @min(g.version, 4)) catch |err| {
                    std.log.err("bind wl_compositor: {t}", .{err});
                    return;
                };
            } else if (eql(u8, name, std.mem.span(wl.Shm.interface.name))) {
                ctx.shm = registry.bind(g.name, wl.Shm, 1) catch |err| {
                    std.log.err("bind wl_shm: {t}", .{err});
                    return;
                };
            } else if (eql(u8, name, std.mem.span(wl.Seat.interface.name))) {
                // First seat only: one pointer/keyboard for the menu.
                if (ctx.seat == null) {
                    const seat = registry.bind(g.name, wl.Seat, @min(g.version, 5)) catch |err| {
                        std.log.err("bind wl_seat: {t}", .{err});
                        return;
                    };
                    seat.setListener(*RegistryCtx, seatListener, ctx);
                    ctx.seat = seat;
                }
            } else if (eql(u8, name, std.mem.span(wp.CursorShapeManagerV1.interface.name))) {
                // Optional: without it the pointer keeps whatever image it
                // last had (usually a plain arrow from the last window).
                ctx.cursor_shape_manager = registry.bind(g.name, wp.CursorShapeManagerV1, @min(g.version, 1)) catch |err| blk: {
                    std.log.warn("bind wp_cursor_shape_manager_v1: {t}", .{err});
                    break :blk null;
                };
            }
        },
        else => {},
    }
}

// ----------------------------------------------------------------------------
// Window manager events
// ----------------------------------------------------------------------------

fn wmListener(_: *river.WindowManagerV1, event: river.WindowManagerV1.Event, wm: *WindowManager) void {
    switch (event) {
        .unavailable => {
            std.log.err("another window manager is already running", .{});
            std.process.exit(1);
        },
        .finished => {
            std.log.info("river finished; exiting", .{});
            std.process.exit(0);
        },
        .window => |ev| {
            _ = window_mod.create(wm, ev.id) catch |err| {
                std.log.err("cannot track new window: {t}", .{err});
                ev.id.destroy();
            };
        },
        .output => |ev| {
            _ = output_mod.create(wm, ev.id) catch |err| {
                std.log.err("cannot track new output: {t}", .{err});
                ev.id.destroy();
            };
        },
        .seat => |ev| {
            _ = seat_mod.create(wm, ev.id) catch |err| {
                std.log.err("cannot track new seat: {t}", .{err});
                ev.id.destroy();
            };
        },
        .manage_start => onManage(wm),
        .render_start => onRender(wm),
        else => {},
    }
}

// ----------------------------------------------------------------------------
// manage sequence
// ----------------------------------------------------------------------------

fn onManage(wm: *WindowManager) void {
    // manage_finish is sent on EVERY path out of this function.
    defer wm.obj.manageFinish();

    // 1. Drop what river told us is gone.
    window_mod.reap(wm);
    output_mod.reap(wm);
    seat_mod.reap(wm);

    // 1b. SIGHUP asked for a config reload (destroys/creates bindings,
    // legal only here, same as step 2 below).
    if (reload_requested.swap(false, .monotonic)) reloadConfig(wm);

    // 2. Seats that just appeared need their bindings (legal only here).
    var sit = wm.seats.first();
    while (sit) |s| : (sit = types.nextSeat(s, wm)) {
        if (!s.bindings_ready and wm.xkb_bindings != null) seat_mod.setupBindings(wm, s);
    }

    // 2b. Root menu: backgrounds, focus, restacking.
    if (wm.ui) |u| u.sync();

    // 2c. A menu click asked for something.
    if (wm.pending_ui) |req| {
        wm.pending_ui = null;
        runUiAction(wm, req);
    }

    // 3. New windows.
    window_mod.placeNew(wm);

    // 4. Interactive pointer operation: start, apply, end.
    seat_mod.startPendingOps(wm);
    var sit2 = wm.seats.first();
    while (sit2) |s| : (sit2 = types.nextSeat(s, wm)) seat_mod.applyOp(wm, s);

    // 5. Key-binding actions queued since the last sequence.
    runPending(wm);

    // 6. Client-requested fullscreen.
    if (wm.pending_fullscreen) |pf| {
        wm.pending_fullscreen = null;
        if (pf.win.workspace != null and !pf.win.closed) {
            if (pf.on) {
                workspace.setFullscreen(wm, pf.win);
            } else {
                workspace.leaveFullscreen(pf.win);
            }
            workspace.activate(pf.win);
            wm.focus_request = pf.win;
            wm.follow_request = true;
        }
    }

    // 7. Layout. Geometry only; no requests yet.
    layoutAll(wm);

    // 8. Send management state (propose_dimensions, tiled, fullscreen) and
    //    rendering state (position, borders, visibility) in one pass.
    const focus_target = resolveFocus(wm);
    var wit = wm.windows.first();
    while (wit) |w| : (wit = types.nextWindow(w, wm)) {
        window_mod.applyManage(wm, w);
        window_mod.applyRender(wm, w, w == focus_target);
    }

    // 9. Keyboard focus (an open menu keeps it).
    const menu_open = if (wm.ui) |u| u.menuOpen() else false;
    if (!menu_open) {
        sit = wm.seats.first();
        while (sit) |s| : (sit = types.nextSeat(s, wm)) seat_mod.focus(s, focus_target);
    }

    // 10. End a finished pointer operation. After layout so that the last
    //     delta was applied to the final frame.
    seat_mod.finishOps(wm);

    // 11. Consumed.
    wm.focus_request = null;
    wm.follow_request = false;
}

fn runUiAction(wm: *WindowManager, req: types.UiAction) void {
    switch (req) {
        .focus => |w| {
            if (w.closed or w.workspace == null) return;
            if (w.workspace) |ws| ws.output.active = ws.index;
            workspace.activate(w);
            wm.focus_request = w;
            wm.follow_request = true;
        },
        .workspace => |i| action.run(wm, .{ .workspace = i }),
        .workspace_next => action.run(wm, .workspace_next),
        .workspace_prev => action.run(wm, .workspace_prev),
    }
}

fn runPending(wm: *WindowManager) void {
    // Actions may queue further requests (never further actions), so
    // swap the list out before running it.
    var batch = wm.pending;
    wm.pending = .empty;
    defer batch.deinit(wm.gpa);
    for (batch.items) |cmd| action.run(wm, cmd);
}

/// A window can take keyboard focus only if it is alive, has content, and
/// sits on the workspace that is currently shown on its output.
pub fn focusable(w: *const types.Window) bool {
    if (w.closed or w.attrs.is("unfocusable")) return false;
    const ws = w.workspace orelse return false;
    return ws.output.active == ws.index and !ws.output.removed;
}

/// Who gets keyboard focus after this pass.
fn resolveFocus(wm: *WindowManager) ?*types.Window {
    // 1. An explicit request wins.
    if (wm.focus_request) |w| if (focusable(w)) return w;

    // 2. Keep the current focus while it is still valid.
    const current: ?*types.Window = if (wm.seats.first()) |s| s.focused else null;
    if (current) |w| if (focusable(w)) return w;

    // 3. Fall back on the output the user was working on (where the last
    //    focused window is, even if that window just went away), so a second
    //    monitor does not suddenly steal focus onto the first.
    const out = activeOutput(wm, current) orelse return null;
    return workspace.defaultFocus(out.ws());
}

/// The output the user is working on: the focused window's output if it
/// still exists, otherwise the first live output.
fn activeOutput(wm: *WindowManager, focused: ?*types.Window) ?*types.Output {
    if (focused) |w| if (w.workspace) |ws| if (!ws.output.removed) return ws.output;
    var it = wm.outputs.first();
    while (it) |o| : (it = types.nextOutput(o, wm)) {
        if (!o.removed and o.ready()) return o;
    }
    return null;
}

fn layoutAll(wm: *WindowManager) void {
    var oit = wm.outputs.first();
    while (oit) |out| : (oit = types.nextOutput(out, wm)) {
        if (!out.ready() or out.removed) continue;
        // Only the visible workspace needs geometry. Hidden workspaces keep
        // their scroll offset for when they come back.
        layout.compute(out.ws(), &wm.cfg, wm.follow_request);
    }
}

// ----------------------------------------------------------------------------
// render sequence
// ----------------------------------------------------------------------------

/// Runs after the clients answered our proposals. Windows whose size
/// differs from what we asked (they refused or clamp it) only need their
/// position corrected; nothing here changes management state.
fn onRender(wm: *WindowManager) void {
    defer wm.obj.renderFinish();
    if (wm.ui) |u| u.onRender();
    const focus = if (wm.seats.first()) |s| s.focused else null;
    var it = wm.windows.first();
    while (it) |w| : (it = types.nextWindow(w, wm)) {
        window_mod.applyRender(wm, w, w == focus);
    }
}

// ----------------------------------------------------------------------------
// Tests: ordering guarantees that don't fit window_mod/ui.zig's own test
// files because they concern onManage() itself.
// ----------------------------------------------------------------------------

test "wm.commands / root_menu / attrs are only ever assigned inside loadFromConfigImpl" {
    // Regression test: all three are allocated from wm.cfg's arena (see
    // loadFromConfigImpl's doc comment). If a future change assigns any of
    // them somewhere else -- e.g. main() re-inlining the load instead of
    // calling loadStartup(), or reloadConfig() special-casing just
    // wm.commands -- that assignment and loadFromConfigImpl's arena
    // lifetime silently fall out of sync: reloadConfig() frees the old
    // arena believing it moved everything derived from it, while the
    // out-of-band assignment still points into it. This does not crash at
    // the reload site; it corrupts memory the next time something reads
    // the stale field. Scanning for the assignment sites themselves (not
    // just "is loadFromConfigImpl called twice", which a hand-inlined copy
    // would also satisfy) is what actually catches that.
    const src = @embedFile("main.zig");
    const impl_start = std.mem.indexOf(u8, src, "fn loadFromConfigImpl(wm: *WindowManager)").?;
    const impl_end = std.mem.indexOfPos(u8, src, impl_start, "\n}").?;
    // loadFromConfig()'s own error path is the one legitimate assignment
    // outside loadFromConfigImpl: on OOM it resets wm.commands to an empty
    // slice rather than leave a half-parsed one, which does not touch (and
    // so cannot dangle from) the arena being freed by its caller.
    const wrap_start = std.mem.indexOf(u8, src, "fn loadFromConfig(wm: *WindowManager) bool {").?;
    const wrap_end = std.mem.indexOfPos(u8, src, wrap_start, "\n}").?;

    // Each needle is split across two literals so the source line below
    // doesn't contain the contiguous text it searches for (which would
    // make it match itself via @embedFile: this whole file, this line
    // included, is what `src` holds).
    const fields = [_][]const u8{
        "wm." ++ "commands = ",
        "wm." ++ "root_menu = ",
        "wm." ++ "attrs = ",
    };
    for (fields) |field| {
        var i: usize = 0;
        var seen: usize = 0;
        while (std.mem.indexOfPos(u8, src, i, field)) |pos| {
            seen += 1;
            const in_impl = pos >= impl_start and pos < impl_end;
            const in_wrap_fallback = pos >= wrap_start and pos < wrap_end;
            try std.testing.expect(in_impl or in_wrap_fallback);
            i = pos + field.len;
        }
        try std.testing.expect(seen >= 1);
    }
}

test "reloadConfig drains the pending queue before freeing the old config's arena" {
    // Regression test: a key press queued just before SIGHUP arrives holds
    // a `.spawn` Command whose argv slices live in the CURRENT config's
    // arena (see reloadConfig's doc comment). If old_cfg.deinit() ran
    // before that queue is drained, those slices would dangle while
    // action.run(wm, .spawn) is still about to read them.
    const src = @embedFile("main.zig");
    const body_start = std.mem.indexOf(u8, src, "fn reloadConfig(wm: *WindowManager) void {").?;
    const body_end = std.mem.indexOfPos(u8, src, body_start, "\n}").?;
    const body = src[body_start..body_end];
    const at = struct {
        fn call(haystack: []const u8, needle: []const u8) usize {
            return std.mem.indexOf(u8, haystack, needle) orelse @panic("call missing from reloadConfig()");
        }
    }.call;
    const run_pos = at(body, "runPending(wm)");
    const free_pos = at(body, "old_cfg.deinit()");
    try std.testing.expect(run_pos < free_pos);
}

test "onManage reaps closed windows before syncing the menu, in the same sequence" {
    // Regression test for a TODO item ("the menu does not redraw itself
    // after a window closes while it's open, only on the next hover").
    // window_mod.destroy() -> seat.forgetWindow() -> ui.forgetWindow()
    // already marks the affected menu level dirty (see ui.zig); what makes
    // that take effect in the SAME manage sequence, rather than the next
    // one, is that window_mod.reap() (which calls destroy()) runs before
    // `if (wm.ui) |u| u.sync()` inside onManage(). Pin that order here so a
    // future reordering doesn't silently reintroduce the stale-row bug.
    const src = @embedFile("main.zig");
    const body_start = std.mem.indexOf(u8, src, "fn onManage(wm: *WindowManager) void {").?;
    const body_end = std.mem.indexOfPos(u8, src, body_start, "\n}").?;
    const body = src[body_start..body_end];
    const at = struct {
        fn call(haystack: []const u8, needle: []const u8) usize {
            return std.mem.indexOf(u8, haystack, needle) orelse @panic("call missing from onManage()");
        }
    }.call;
    const reap_pos = at(body, "window_mod.reap(wm)");
    const sync_pos = at(body, "u.sync()");
    try std.testing.expect(sync_pos > reap_pos);
}
