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

        .focus_left => {
            if (wm.outputs.first()) |out| {
                const ws = out.activeWorkspace();
                if (ws.strip.active_column) |col| {
                    if (types.prevColumn(col)) |prev_col| {
                        ws.strip.active_column = prev_col;
                        if (prev_col.focusedWindow()) |win| {
                            if (wm.seats.first()) |s| seat.focus(s, win);
                        }
                    }
                }
            }
        },

        .focus_right => {
            if (wm.outputs.first()) |out| {
                const ws = out.activeWorkspace();
                if (ws.strip.active_column) |col| {
                    if (types.nextColumn(col)) |next_col| {
                        ws.strip.active_column = next_col;
                        if (next_col.focusedWindow()) |win| {
                            if (wm.seats.first()) |s| seat.focus(s, win);
                        }
                    }
                }
            }
        },

        else => {},
    }
}
