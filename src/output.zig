// SPDX-License-Identifier: 0BSD
//
// river_output_v1 lifecycle. river does NOT advertise outputs through
// wl_registry: it sends an `output` event on river_window_manager_v1 once
// that is bound, carrying the new river_output_v1 object.

const std = @import("std");
const wayland = @import("wayland");
const river = wayland.client.river;

const types = @import("types.zig");
const WindowManager = types.WindowManager;
const Output = types.Output;

pub fn create(wm: *WindowManager, river_out: *river.OutputV1) !*Output {
    const out = try wm.gpa.create(Output);
    out.* = .{
        .obj = river_out,
        .link = undefined,
    };

    for (&out.workspaces, 0..) |*ws, i| {
        ws.init(out, @intCast(i));
    }

    wm.outputs.append(out);
    river_out.setListener(*WindowManager, listener, wm);
    return out;
}

fn find(wm: *WindowManager, river_out: *river.OutputV1) ?*Output {
    var it = wm.outputs.first();
    while (it) |out| : (it = types.nextOutput(out, wm)) {
        if (out.obj == river_out) return out;
    }
    return null;
}

fn listener(river_out: *river.OutputV1, event: river.OutputV1.Event, wm: *WindowManager) void {
    const out = find(wm, river_out) orelse return;

    switch (event) {
        .position => |pos| {
            out.x = pos.x;
            out.y = pos.y;
            wm.needs_layout = true;
        },
        .dimensions => |dim| {
            out.width = dim.width;
            out.height = dim.height;
            wm.needs_layout = true;
        },
        .removed => {
            out.removed = true;
            wm.needs_layout = true;
        },
        else => {},
    }
}

/// Destroy outputs marked as removed. Windows on a removed output are
/// moved to the first remaining output (see window.rehome).
pub fn reap(wm: *WindowManager) void {
    var it = wm.outputs.first();
    while (it) |out| {
        const next = types.nextOutput(out, wm);
        if (out.removed) {
            out.link.remove();
            out.obj.destroy();
            wm.gpa.destroy(out);
        }
        it = next;
    }
}
