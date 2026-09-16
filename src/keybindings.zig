const std = @import("std");
const types = @import("types.zig");
const WindowManager = types.WindowManager;

pub fn handleAction(wm: *WindowManager, action_id: u32) void {
    _ = wm;
    switch (action_id) {
        1 => {
            // z.B. Next Column
        },
        2 => {
            // z.B. Prev Column
        },
        else => {},
    }
}
