const std = @import("std");
const wayland = @import("wayland");
const wl = wayland.client.wl;
const river = wayland.client.river;

const types = @import("types.zig");
const Output = types.Output;
const Workspace = types.Workspace;
const Strip = types.Strip;
const WindowManager = types.WindowManager;

pub fn create(wm: *WindowManager, river_output: *river.OutputV1) !*Output {
    const output = try wm.allocator.create(Output);
    output.* = .{
        .wm = wm,
        .river_output = river_output,
        .workspaces = undefined,
    };

    for (&output.workspaces) |*ws| {
        ws.* = .{
            .output = output,
            .strip = Strip.init(),
        };
    }

    wm.outputs.append(&output.link);
    return output;
}

pub fn switchWorkspace(output: *Output, index: usize) void {
    if (index >= types.Config.workspace_count) return;
    output.active_workspace = index;
    // Hide/Show Logik wird bei der Sichtbarkeits-Verdrahtung ergänzt
}
