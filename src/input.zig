// SPDX-License-Identifier: 0BSD
//
// Input handling: keyboard bindings, mouse interactions.
// Separated from main event loop for better maintainability.

const std = @import("std");
const types = @import("types.zig");

pub var global_wm: ?*types.WindowManager = null;

pub const MouseState = struct {
    x: i32 = 0,
    y: i32 = 0,
    button_mask: u32 = 0,
    dragging_window: ?*types.Window = null,
    drag_start_x: i32 = 0,
    drag_start_y: i32 = 0,
    initial_window_x: i32 = 0,
    initial_window_y: i32 = 0,
};

pub fn spawn(wm: *types.WindowManager, argv: []const []const u8) void {
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

pub fn handleMouseButtonPress(
    wm: *types.WindowManager,
    mouse: *MouseState,
    button: u32,
    x: i32,
    y: i32,
) void {
    if (!wm.config.enable_mouse_support) return;

    mouse.x = x;
    mouse.y = y;
    mouse.button_mask |= (1 << button);

    // Find window at cursor
    const window_at_cursor = findWindowAtPoint(wm, x, y);

    switch (button) {
        1 => { // Left click - move window (with Mod4)
            if (window_at_cursor) |w| {
                mouse.dragging_window = w;
                mouse.drag_start_x = x;
                mouse.drag_start_y = y;
                mouse.initial_window_x = w.x;
                mouse.initial_window_y = w.y;
                wm.needs_layout = true;
            }
        },
        3 => { // Right click - resize window
            if (window_at_cursor) |w| {
                mouse.dragging_window = w;
                mouse.drag_start_x = x;
                mouse.drag_start_y = y;
                wm.needs_layout = true;
            }
        },
        else => {},
    }
}

pub fn handleMouseButtonRelease(
    mouse: *MouseState,
    button: u32,
) void {
    mouse.button_mask &= ~(1 << button);

    if (button == 1 or button == 3) {
        mouse.dragging_window = null;
    }
}

pub fn handleMouseMotion(
    wm: *types.WindowManager,
    mouse: *MouseState,
    x: i32,
    y: i32,
) void {
    if (!wm.config.enable_mouse_support) return;

    const dx = x - mouse.drag_start_x;
    const dy = y - mouse.drag_start_y;

    if (mouse.dragging_window) |w| {
        if ((mouse.button_mask & (1 << 1)) != 0) {
            // Left button: move
            w.x = mouse.initial_window_x + dx;
            w.y = mouse.initial_window_y + dy;
            wm.needs_layout = true;
        } else if ((mouse.button_mask & (1 << 3)) != 0) {
            // Right button: resize
            const new_width = @max(100, w.width + dx);
            const new_height = @max(100, w.height + dy);
            w.width = @intCast(new_width);
            w.height = @intCast(new_height);
            wm.needs_layout = true;
        }
    }

    mouse.x = x;
    mouse.y = y;
}

fn findWindowAtPoint(wm: *types.WindowManager, x: i32, y: i32) ?*types.Window {
    var oit = wm.outputs.first();
    while (oit) |out| : (oit = types.nextOutput(out, wm)) {
        if (!out.isReady()) continue;

        const ws = out.activeWorkspace();
        var cit = ws.strip.columns.first();
        while (cit) |col| : (cit = types.nextColumn(col)) {
            var wit = col.windows.first();
            while (wit) |w| : (wit = types.nextWindowInColumn(w)) {
                if (x >= w.x and x < w.x + w.width and
                    y >= w.y and y < w.y + w.height)
                {
                    return w;
                }
            }
        }
    }
    return null;
}

pub fn handleKeybinding(wm: *types.WindowManager, action: []const u8) void {
    if (std.mem.eql(u8, action, "spawn_terminal")) {
        wm.pending_spawn = wm.config.terminal_cmd;
    } else if (std.mem.eql(u8, action, "spawn_launcher")) {
        wm.pending_spawn = wm.config.launcher_cmd;
    } else if (std.mem.eql(u8, action, "spawn_browser")) {
        wm.pending_spawn = wm.config.browser_cmd;
    } else if (std.mem.eql(u8, action, "focus_left")) {
        if (wm.outputs.first()) |out| {
            const ws = out.activeWorkspace();
            if (ws.strip.active_column) |active| {
                if (types.prevColumn(active)) |prev| {
                    ws.strip.active_column = prev;
                    wm.needs_layout = true;
                }
            }
        }
    } else if (std.mem.eql(u8, action, "focus_right")) {
        if (wm.outputs.first()) |out| {
            const ws = out.activeWorkspace();
            if (ws.strip.active_column) |active| {
                if (types.nextColumn(active)) |next| {
                    ws.strip.active_column = next;
                    wm.needs_layout = true;
                }
            }
        }
    } else if (std.mem.eql(u8, action, "focus_up")) {
        if (wm.seats.first()) |s| {
            if (s.focused) |f| {
                if (types.prevWindowInColumn(f)) |prev| {
                    s.focused = prev;
                    wm.needs_layout = true;
                }
            }
        }
    } else if (std.mem.eql(u8, action, "focus_down")) {
        if (wm.seats.first()) |s| {
            if (s.focused) |f| {
                if (types.nextWindowInColumn(f)) |next| {
                    s.focused = next;
                    wm.needs_layout = true;
                }
            }
        }
    } else {
        std.log.debug("unknown action: {s}", .{action});
    }
}
