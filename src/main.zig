// SPDX-License-Identifier: 0BSD
//
// wmaker-wl: scrollable-tiling window manager client for river.
// Enhanced with WindowMaker compatibility layer and improved code structure.
//
// Protocol flow (river-window-management-v1):
//   input/window events ... -> manage_start -> [we edit window-management
//   state, then manage_finish] -> render_start -> [we edit rendering state,
//   then render_finish].

const std = @import("std");
const wayland = @import("wayland");
const wl = wayland.client.wl;
const river = wayland.client.river;

const types = @import("types.zig");
const layout = @import("layout.zig");
const window_mod = @import("window.zig");
const output = @import("output.zig");
const seat = @import("seat.zig");
const action = @import("action.zig");
const config = @import("config.zig");
const input = @import("input.zig");
const wmaker = @import("compatibility.zig");

const WindowManager = types.WindowManager;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    ignoreSigchld();

    // Load config first (may include WMaker-specific settings)
    var cfg = try config.load(io, gpa);
    defer cfg.deinit(gpa);

    // Initialize WMaker compatibility layer (if available)
    var wmaker_ctx = try wmaker.init(gpa, &cfg);
    defer wmaker_ctx.deinit(gpa);

    const display = wl.Display.connect(null) catch |err| {
        std.log.err("cannot connect to wayland display: {}", .{err});
        return err;
    };
    defer display.disconnect();

    const wm = try gpa.create(WindowManager);
    defer gpa.destroy(wm);

    wm.* = .{
        .gpa = gpa,
        .io = io,
        .config = cfg,
        .wmaker_ctx = wmaker_ctx,
        .outputs = undefined,
        .windows = undefined,
        .seats = undefined,
    };
    wm.outputs.init();
    wm.windows.init();
    wm.seats.init();
    defer wm.pending_actions.deinit(gpa);

    window_mod.global_wm = wm;
    input.global_wm = wm;

    const registry = try display.getRegistry();
    registry.setListener(*WindowManager, registryListener, wm);

    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

    if (wm.obj == null) {
        std.log.err("river_window_manager_v1 not advertised. Run me from river: `river -c wmaker-wl`", .{});
        return error.MissingRiverWindowManagement;
    }

    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

    std.log.info("wmaker-wl running (config: {s})", .{cfg.config_file});

    while (!wm.quit) {
        if (display.dispatch() != .SUCCESS) break;
    }

    if (wm.quit) {
        if (wm.obj) |o| {
            if (wm.obj_version >= 4) o.exitSession() else o.stop();
        }
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

fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, wm: *WindowManager) void {
    switch (event) {
        .global => |g| {
            const name = std.mem.span(g.interface);

            if (std.mem.eql(u8, name, std.mem.span(river.WindowManagerV1.interface.name))) {
                const version = @min(g.version, 6);
                const obj = registry.bind(g.name, river.WindowManagerV1, version) catch |err| {
                    std.log.err("bind river_window_manager_v1 failed: {}", .{err});
                    return;
                };
                wm.obj = obj;
                wm.obj_version = version;
                obj.setListener(*WindowManager, riverWmListener, wm);
            } else if (std.mem.eql(u8, name, std.mem.span(river.XkbBindingsV1.interface.name))) {
                wm.xkb_bindings = registry.bind(g.name, river.XkbBindingsV1, 1) catch |err| {
                    std.log.err("bind river_xkb_bindings_v1 failed: {}", .{err});
                    return;
                };
                var it = wm.seats.first();
                while (it) |s| : (it = types.nextSeat(s, wm)) s.needs_binding_setup = true;
            }
        },
        else => {},
    }
}

fn riverWmListener(river_wm: *river.WindowManagerV1, event: river.WindowManagerV1.Event, wm: *WindowManager) void {
    switch (event) {
        .unavailable => {
            std.log.err("window management unavailable: another WM is already running", .{});
            std.process.exit(1);
        },
        .finished => {
            std.log.info("river finished, exiting", .{});
            std.process.exit(0);
        },
        .window => |ev| {
            _ = window_mod.create(wm, ev.id) catch |err| {
                std.log.err("create window failed: {}", .{err});
            };
        },
        .output => |ev| {
            _ = output.create(wm, ev.id) catch |err| {
                std.log.err("create output failed: {}", .{err});
            };
        },
        .seat => |ev| {
            _ = seat.create(wm, ev.id) catch |err| {
                std.log.err("create seat failed: {}", .{err});
            };
        },
        .manage_start => handleManageStart(river_wm, wm),
        .render_start => handleRenderStart(river_wm, wm),
        else => {},
    }
}

fn handleManageStart(river_wm: *river.WindowManagerV1, wm: *WindowManager) void {
    var sit = wm.seats.first();
    while (sit) |s| : (sit = types.nextSeat(s, wm)) {
        if (s.needs_binding_setup) seat.setupBindings(wm, s);
    }
    seat.reap(wm);
    output.reap(wm);

    var wit = wm.windows.first();
    while (wit) |w| {
        const next = types.nextWindow(w, wm);
        if (w.new) window_mod.manage(w, wm);
        wit = next;
    }

    while (wm.pending_actions.items.len > 0) {
        const act = wm.pending_actions.orderedRemove(0);
        action.run(wm, act);
        if (wm.quit) break;
    }

    if (wm.quit) {
        river_wm.manageFinish();
        return;
    }

    applyLayout(wm);

    if (wm.pending_close) |w| {
        w.obj.close();
        wm.pending_close = null;
    }

    if (wm.pending_focus) |w| {
        if (wm.seats.first()) |s| seat.focus(s, w);
        wm.pending_focus = null;
    } else if (wm.seats.first()) |s| {
        if (s.focused == null) {
            if (wm.outputs.first()) |o| {
                if (o.activeWorkspace().strip.focusedWindow()) |w| seat.focus(s, w);
            }
        }
    }

    if (wm.pending_spawn) |argv| {
        input.spawn(wm, argv);
        wm.pending_spawn = null;
    }

    wm.needs_layout = false;
    river_wm.manageFinish();
}

fn applyLayout(wm: *WindowManager) void {
    var oit = wm.outputs.first();
    while (oit) |out| : (oit = types.nextOutput(out, wm)) {
        if (!out.isReady()) continue;

        const ws = out.activeWorkspace();
        const strip = &ws.strip;
        const usable = out.rect();

        if (strip.active_column) |active| {
            layout.recomputeGeometry(strip, usable);
            layout.scrollToColumn(strip, active, usable.width);
        }
        layout.recomputeGeometry(strip, usable);

        var cit = strip.columns.first();
        while (cit) |col| : (cit = types.nextColumn(col)) {
            var wit = col.windows.first();
            while (wit) |win| : (wit = types.nextWindowInColumn(win)) {
                if (win.proposed_w != win.width or win.proposed_h != win.height) {
                    win.obj.proposeDimensions(win.width, win.height);
                    win.proposed_w = win.width;
                    win.proposed_h = win.height;
                }
                win.obj.setTiled(.{ .top = true, .bottom = true, .left = true, .right = true });
            }
        }
    }
}

fn handleRenderStart(river_wm: *river.WindowManagerV1, wm: *WindowManager) void {
    const focused = if (wm.seats.first()) |s| s.focused else null;

    var oit = wm.outputs.first();
    while (oit) |out| : (oit = types.nextOutput(out, wm)) {
        if (!out.isReady()) continue;

        for (&out.workspaces, 0..) |*ws, i| {
            const active = (i == out.active_workspace);
            var cit = ws.strip.columns.first();
            while (cit) |col| : (cit = types.nextColumn(col)) {
                var wit = col.windows.first();
                while (wit) |win| : (wit = types.nextWindowInColumn(win)) {
                    renderWindow(win, active, win == focused, out.rect(), wm.config);
                }
            }
        }
    }

    river_wm.renderFinish();
}

fn renderWindow(win: *types.Window, workspace_active: bool, is_focused: bool, usable: types.Rectangle, cfg: config.Config) void {
    if (workspace_active and win.hidden) {
        win.obj.show();
        win.hidden = false;
    } else if (!workspace_active and !win.hidden) {
        win.obj.hide();
        win.hidden = true;
    }
    if (!workspace_active) return;

    if (win.node) |node| {
        node.setPosition(win.x, win.y);
        if (is_focused) node.placeTop();
    }

    if (layout.isOffscreen(win, usable)) return;

    if (win.border_focused != is_focused) {
        const c = if (is_focused) cfg.border_focused else cfg.border_unfocused;
        win.obj.setBorders(
            .{ .top = true, .bottom = true, .left = true, .right = true },
            cfg.border_width,
            channel((c >> 16) & 0xff),
            channel((c >> 8) & 0xff),
            channel(c & 0xff),
            0xffffffff,
        );
        win.border_focused = is_focused;
    }
}

fn channel(v: u32) u32 {
    return v * 0x01010101;
}
