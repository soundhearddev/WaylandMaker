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

const types = @import("types.zig");
const config = @import("config.zig");
const layout = @import("layout.zig");
const workspace = @import("workspace.zig");
const window_mod = @import("window.zig");
const output_mod = @import("output.zig");
const seat_mod = @import("seat.zig");
const action = @import("action.zig");
const wm_files = @import("wm_files.zig");
const proc = @import("process.zig");

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

    // Parse key-binding commands once. They live as long as the config.
    const arena = wm.cfg.arena.allocator();
    wm.commands = try action.parseAll(arena, &wm.cfg);

    // Window Maker files: root menu, per-application rules and autostart.
    const files = try wm_files.load(io, arena, &wm.cfg);
    wm.root_menu = files.root_menu;
    wm.attrs = files.attributes;
    const autostart_path = files.autostart;

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

    std.log.info("wmaker-wl running (config: {s})", .{wm.cfg.config_file});

    // Window Maker's autostart: one script, run once, detached. Run through
    // /bin/sh so it works whether or not the file is marked executable; a
    // shebang line is just a `#` comment to sh and is harmless either way.
    if (autostart_path) |p| {
        std.log.info("autostart: running {s}", .{p});
        proc.spawn(wm, &.{ "/bin/sh", p });
    }

    while (!wm.quit) {
        if (display.dispatch() != .SUCCESS) break;
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
// Registry
// ----------------------------------------------------------------------------

const RegistryCtx = struct {
    wm: *WindowManager,
    bound_wm: *bool,
};

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

    // 2. Seats that just appeared need their bindings (legal only here).
    var sit = wm.seats.first();
    while (sit) |s| : (sit = types.nextSeat(s, wm)) {
        if (!s.bindings_ready and wm.xkb_bindings != null) seat_mod.setupBindings(wm, s);
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

    // 9. Keyboard focus.
    sit = wm.seats.first();
    while (sit) |s| : (sit = types.nextSeat(s, wm)) seat_mod.focus(s, focus_target);

    // 10. End a finished pointer operation. After layout so that the last
    //     delta was applied to the final frame.
    seat_mod.finishOps(wm);

    // 11. Consumed.
    wm.focus_request = null;
    wm.follow_request = false;
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

    const focus = if (wm.seats.first()) |s| s.focused else null;
    var it = wm.windows.first();
    while (it) |w| : (it = types.nextWindow(w, wm)) {
        window_mod.applyRender(wm, w, w == focus);
    }
}
