// SPDX-License-Identifier: 0BSD
//
// Input handling: keyboard bindings, mouse interactions.
// Separated from main event loop for better maintainability.

const std = @import("std");
const types = @import("types.zig");

pub var global_wm: ?*types.WindowManager = null;

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

// NOTE: keybinding dispatch is NOT done here. It lives in seat.zig
// (river_xkb_binding "pressed" -> wm.pending_actions) and action.zig
// (action.run, executed from manage_start), which is the only dispatcher
// that is actually wired up and covers the full types.Action set. An
// earlier, unreachable, string-keyed duplicate of that logic (covering
// only a handful of actions) used to live here; it was removed to avoid
// two dispatchers drifting apart.
