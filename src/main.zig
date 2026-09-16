const std = @import("std");
const wayland = @import("wayland");
const wl = wayland.client.wl;
const river = wayland.client.river;

const types = @import("types.zig");
const layout = @import("layout.zig");
const window = @import("window.zig");
const output = @import("output.zig");
const seat = @import("seat.zig");

const WindowManager = types.WindowManager;

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) std.log.err("Memory leak detected!", .{});
    }

    const display = try wl.Display.connect(null);
    defer display.disconnect();

    const wm: ?*WindowManager = null;

    // Wayland Registry Init & Event Loop setup
    // (Hier werden die Bindings für river_window_manager_v1 registriert)

    std.log.info("wmaker-wl gestartet", .{});

    while (display.dispatch() == .SUCCESS) {
        if (wm) |m| {
            var out_it = m.outputs.first();
            while (out_it) |out_node| : (out_it = out_node.next) {
                const out: *types.Output = @fieldParentPtr("link", out_node);
                const ws = out.getActiveWorkspace();

                layout.calculateLayout(&ws.strip, .{
                    .x = 0,
                    .y = 0,
                    .w = 1920,
                    .h = 1080,
                });
            }
        }
    }
}
