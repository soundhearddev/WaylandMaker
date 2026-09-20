// SPDX-License-Identifier: 0BSD
//
// Spawning child processes.

const std = @import("std");
const types = @import("types.zig");

/// Start `argv` detached. SIGCHLD is ignored process-wide (see main.zig),
/// so children are reaped automatically and never become zombies.
pub fn spawn(wm: *types.WindowManager, argv: []const []const u8) void {
    if (argv.len == 0) return;
    _ = std.process.spawn(wm.io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch |err| {
        std.log.err("failed to spawn `{s}`: {t}", .{ argv[0], err });
    };
}
