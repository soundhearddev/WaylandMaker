// SPDX-License-Identifier: 0BSD
//
// river_output_v1 lifecycle. An Output object only becomes useful for
// layout once we've received at least one `position` and one `dimensions`
// event -- see types.Output.isReady().

const std = @import("std");

const wayland = @import("wayland");
const river = wayland.client.river;

const types = @import("types.zig");
const WindowManager = types.WindowManager;
const Output = types.Output;

pub fn create(wm: *WindowManager, river_out: *river.OutputV1) !*Output {
    const output = try wm.gpa.create(Output);
    output.* = .{
        .obj = river_out,
        .link = undefined,
    };

    for (&output.workspaces, 0..) |*ws, i| {
        ws.init(output, @intCast(i));
    }

    wm.outputs.append(output);
    river_out.setListener(*WindowManager, listener, wm);

    return output;
}

fn findOutput(wm: *WindowManager, river_out: *river.OutputV1) ?*Output {
    var it = wm.outputs.first();
    while (it) |out| : (it = nextOutput(out)) {
        if (out.obj == river_out) return out;
    }
    return null;
}

fn nextOutput(out: *Output) ?*Output {
    const n = out.link.next orelse return null;
    return @fieldParentPtr("link", n);
}

fn listener(river_out: *river.OutputV1, event: river.OutputV1.Event, wm: *WindowManager) void {
    const output = findOutput(wm, river_out) orelse return;

    switch (event) {
        .position => |pos| {
            output.x = pos.x;
            output.y = pos.y;
            wm.needs_layout = true;
        },
        .dimensions => |dim| {
            output.width = dim.width;
            output.height = dim.height;
            wm.needs_layout = true;
        },
        .removed => {
            output.removed = true;
        },
        else => {},
    }
}

/// Destroy outputs marked as removed.
pub fn reap(wm: *WindowManager) void {
    var it = wm.outputs.first();
    while (it) |out| {
        const next = nextOutput(out);
        if (out.removed) {
            out.obj.destroy();
            out.link.remove();
            wm.gpa.destroy(out);
        }
        it = next;
    }
}
