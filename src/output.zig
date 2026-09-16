const std = @import("std");

const wayland = @import("wayland");
const river = wayland.client.river;

const types = @import("types.zig");
const Output = types.Output;
const WindowManager = types.WindowManager;

pub fn create(
    wm: *WindowManager,
    river_out: *river.OutputV1,
) !*Output {
    const output = try wm.gpa.create(Output);

    output.* = .{
        .obj = river_out,
        .link = undefined,
    };

    for (&output.workspaces, 0..) |*ws, i| {
        ws.init(output, @intCast(i));
    }

    wm.outputs.append(output);

    return output;
}

pub fn switchWorkspace(output: *Output, index: u32) void {
    if (index >= types.Config.workspace_count) {
        return;
    }

    output.active_workspace = index;
}
