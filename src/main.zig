// SPDX-License-Identifier: 0BSD
//
// wmaker-wl: scrollable-tiling window manager client for river.
//
// Protocol flow (river-window-management-v1):
//   input/window events ... -> manage_start -> [we edit window-management
//   state, then manage_finish] -> render_start -> [we edit rendering state,
//   then render_finish].
//
// Rules this file follows:
//   * propose_dimensions, focus_window, close, use_ssd, set_tiled,
//     xkb_binding.enable ... are window-management state: ONLY between
//     manage_start and manage_finish.
//   * node.set_position, hide/show, set_borders are rendering state: legal
//     in manage OR render sequences. We do them in render_start.

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

const WindowManager = types.WindowManager;
const Config = types.Config;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    // Spawned programs are fire-and-forget. Ignoring SIGCHLD makes the
    // kernel reap them automatically, so we never accumulate zombies and
    // never have to call wait() on a blocking event loop.
    ignoreSigchld();

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
        .outputs = undefined,
        .windows = undefined,
        .seats = undefined,
    };
    wm.outputs.init();
    wm.windows.init();
    wm.seats.init();
    defer wm.pending_actions.deinit(gpa);

    window_mod.global_wm = wm;

    const registry = try display.getRegistry();
    registry.setListener(*WindowManager, registryListener, wm);

    // Roundtrip 1: learn the globals (binds window manager + xkb bindings).
    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

    if (wm.obj == null) {
        std.log.err("river_window_manager_v1 not advertised. Run me from river: `river -c wmaker-wl`", .{});
        return error.MissingRiverWindowManagement;
    }
    if (wm.xkb_bindings == null) {
        std.log.err("river_xkb_bindings_v1 not advertised - keybindings will not work", .{});
    }

    // Roundtrip 2: receive the initial output/seat/window events.
    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

    std.log.info("wmaker-wl running", .{});

    while (!wm.quit) {
        if (display.dispatch() != .SUCCESS) break;
    }

    if (wm.quit) {
        // The user explicitly asked to leave: end the whole session.
        // exit_session exists since protocol version 4.
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

// ============================================================================
// Registry
// ============================================================================

fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, wm: *WindowManager) void {
    switch (event) {
        .global => |g| {
            const name = std.mem.span(g.interface);

            if (std.mem.eql(u8, name, std.mem.span(river.WindowManagerV1.interface.name))) {
                // Use the highest version we know (scanner was generated
                // for 6), capped by what river offers.
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
                // Seats created before this global showed up still need
                // their bindings.
                var it = wm.seats.first();
                while (it) |s| : (it = types.nextSeat(s, wm)) s.needs_binding_setup = true;
            }
        },
        else => {},
    }
}

// ============================================================================
// river_window_manager_v1
// ============================================================================

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

// ============================================================================
// manage sequence
// ============================================================================

fn handleManageStart(river_wm: *river.WindowManagerV1, wm: *WindowManager) void {
    // 1. Bindings: enable() is only legal here.
    var sit = wm.seats.first();
    while (sit) |s| : (sit = types.nextSeat(s, wm)) {
        if (s.needs_binding_setup) seat.setupBindings(wm, s);
    }
    seat.reap(wm);
    output.reap(wm);

    // 2. Place brand-new windows into the strip.
    var wit = wm.windows.first();
    while (wit) |w| {
        const next = types.nextWindow(w, wm);
        if (w.new) window_mod.manage(w, wm);
        wit = next;
    }

    // 3. Execute queued keybinding actions. We drain a copy so an action
    //    that queues another one cannot invalidate our iteration.
    while (wm.pending_actions.items.len > 0) {
        const act = wm.pending_actions.orderedRemove(0);
        action.run(wm, act);
        if (wm.quit) break;
    }

    if (wm.quit) {
        river_wm.manageFinish();
        return;
    }

    // 4. Geometry + dimensions for every output's active workspace.
    applyLayout(wm);

    // 5. Focus / close / spawn requested by actions or events.
    if (wm.pending_close) |w| {
        w.obj.close();
        wm.pending_close = null;
    }

    if (wm.pending_focus) |w| {
        if (wm.seats.first()) |s| seat.focus(s, w);
        wm.pending_focus = null;
    } else if (wm.seats.first()) |s| {
        // Nothing requested, but if focus is empty (e.g. the focused
        // window closed) hand it to the active column.
        if (s.focused == null) {
            if (wm.outputs.first()) |o| {
                if (o.activeWorkspace().strip.focusedWindow()) |w| seat.focus(s, w);
            }
        }
    }

    if (wm.pending_spawn) |argv| {
        spawn(wm, argv);
        wm.pending_spawn = null;
    }

    wm.needs_layout = false;
    river_wm.manageFinish();
}

/// Compute geometry and send propose_dimensions / set_tiled.
/// Manage sequence only.
fn applyLayout(wm: *WindowManager) void {
    var oit = wm.outputs.first();
    while (oit) |out| : (oit = types.nextOutput(out, wm)) {
        if (!out.isReady()) continue;

        const ws = out.activeWorkspace();
        const strip = &ws.strip;
        const usable = out.rect();

        // Scroll just enough to reveal the active column.
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

fn spawn(wm: *WindowManager, argv: []const []const u8) void {
    // Zig 0.16: process spawning goes through std.Io. Stdio is ignored so
    // no pipe is left open for us to leak. The child is never wait()ed on;
    // SIGCHLD is ignored (see ignoreSigchld) so the kernel reaps it.
    _ = std.process.spawn(wm.io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch |err| {
        std.log.err("failed to spawn {s}: {}", .{ argv[0], err });
        return;
    };
}

// ============================================================================
// render sequence
// ============================================================================

fn handleRenderStart(river_wm: *river.WindowManagerV1, wm: *WindowManager) void {
    const focused = if (wm.seats.first()) |s| s.focused else null;

    // Hide everything that lives on a non-active workspace.
    var oit = wm.outputs.first();
    while (oit) |out| : (oit = types.nextOutput(out, wm)) {
        if (!out.isReady()) continue;

        for (&out.workspaces, 0..) |*ws, i| {
            const active = (i == out.active_workspace);
            var cit = ws.strip.columns.first();
            while (cit) |col| : (cit = types.nextColumn(col)) {
                var wit = col.windows.first();
                while (wit) |win| : (wit = types.nextWindowInColumn(win)) {
                    renderWindow(win, active, win == focused, out.rect());
                }
            }
        }
    }

    river_wm.renderFinish();
}

fn renderWindow(win: *types.Window, workspace_active: bool, is_focused: bool, usable: types.Rectangle) void {
    // Hide/show on workspace change.
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

    // Skip the border request entirely for windows scrolled out of view;
    // they get it when they scroll back in.
    if (layout.isOffscreen(win, usable)) return;

    if (win.border_focused != is_focused) {
        const c = if (is_focused) Config.border_focused else Config.border_unfocused;
        win.obj.setBorders(
            .{ .top = true, .bottom = true, .left = true, .right = true },
            Config.border_width,
            channel((c >> 16) & 0xff),
            channel((c >> 8) & 0xff),
            channel(c & 0xff),
            0xffffffff,
        );
        win.border_focused = is_focused;
    }
}

/// river takes colour channels as 32-bit fractions (0xffffffff = 100 %).
fn channel(v: u32) u32 {
    return v * 0x01010101;
}
