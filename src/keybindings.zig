const std = @import("std");

const types = @import("types.zig");
const Action = types.Action;
const WindowManager = types.WindowManager;

pub fn handleAction(wm: *WindowManager, action: Action) void {
    _ = wm;

    switch (action) {
        .none => {},

        .exit => {},

        else => {},
    }
}
