const std = @import("std");

const types = @import("types.zig");
const seat = @import("seat.zig");

const Action = types.Action;
const WindowManager = types.WindowManager;

pub fn handleAction(wm: *WindowManager, action: Action) void {
    switch (action) {
        .none => {},

        .exit => {
            std.log.info("[ACTION] Exiting wmaker-wl...", .{});
            std.process.exit(0);
        },

        .focus_left, .focus_right => |dir| {
            _ = dir;
            // Preparation for focus switching logic on the active workspace
            if (wm.outputs.first()) |out| {
                const ws = out.activeWorkspace();
                if (ws.strip.active_column) |col| {
                    if (col.windows.first()) |win| {
                        if (wm.seats.first()) |s| {
                            seat.focus(s, win);
                        }
                    }
                }
            }
        },

        else => {},
    }
}
