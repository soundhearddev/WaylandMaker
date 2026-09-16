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

        if (deinit_status == .leak) {
            std.log.err("[MEM] Memory leak detected!", .{});
        }
    }

    const allocator = gpa.allocator();

    const display = try wl.Display.connect(null);
    defer display.disconnect();

    std.log.info("[INIT] Connecting to Wayland display...", .{});

    const wm = try allocator.create(WindowManager);

    wm.* = .{
        .gpa = allocator,
        .io = undefined,
        .obj = undefined,
        .xkb_bindings = undefined,
        .outputs = undefined,
        .windows = undefined,
        .seats = undefined,
    };

    wm.outputs.init();
    wm.windows.init();
    wm.seats.init();

    const registry = try display.getRegistry();

    var context = Context{
        .wm = wm,
        .allocator = allocator,
    };

    registry.setListener(*Context, registryListener, &context);

    const roundtrip_status = display.roundtrip();

    if (roundtrip_status != .SUCCESS) {
        std.log.err(
            "[INIT] Wayland display roundtrip failed: {}",
            .{roundtrip_status},
        );
        return;
    }

    std.log.info(
        "[INIT] wmaker-wl started. Waiting for River events...",
        .{},
    );

    var frame_count: u64 = 0;

    while (display.dispatch() == .SUCCESS) {
        frame_count += 1;

        var out_it = wm.outputs.first();

        while (out_it) |out| : (out_it = if (out.link.next) |n|
            @fieldParentPtr("link", n)
        else
            null)
        {
            const ws = out.activeWorkspace();
            const rect = out.usableRect();

            layout.recomputeGeometry(&ws.strip, rect);

            var win_count: u32 = 0;
            var col_it = ws.strip.columns.first();

            while (col_it) |col| : (col_it = if (col.link.next) |n|
                @fieldParentPtr("link", n)
            else
                null)
            {
                var win_it = col.windows.first();

                while (win_it) |win| : (win_it = if (win.column_link.next) |n|
                    @fieldParentPtr("column_link", n)
                else
                    null)
                {
                    win_count += 1;

                    win.node.setPosition(win.x, win.y);
                }
            }

            if (win_count > 0 and frame_count % 100 == 0) {
                std.log.debug(
                    "[LOOP] Frame {}: Recomputing layout for {} windows",
                    .{ frame_count, win_count },
                );
            }
        }
    }

    std.log.warn("[EXIT] Event loop terminated.", .{});
}

const Context = struct {
    wm: *WindowManager,
    allocator: std.mem.Allocator,
};

fn registryListener(
    registry: *wl.Registry,
    event: wl.Registry.Event,
    ctx: *Context,
) void {
    switch (event) {
        .global => |global| {
            const interface_name = std.mem.span(global.interface);

            if (std.mem.eql(
                u8,
                interface_name,
                std.mem.span(river.WindowManagerV1.interface.name),
            )) {
                std.log.info(
                    "[REGISTRY] Binding river_window_manager_v1 (Name: {})...",
                    .{global.name},
                );

                const river_wm =
                    registry.bind(global.name, river.WindowManagerV1, 1) catch return;

                ctx.wm.obj = river_wm;

                river_wm.setListener(
                    *WindowManager,
                    riverWmListener,
                    ctx.wm,
                );
            } else if (std.mem.eql(
                u8,
                interface_name,
                std.mem.span(river.OutputV1.interface.name),
            )) {
                std.log.info(
                    "[REGISTRY] Binding river_output_v1 (Name: {})...",
                    .{global.name},
                );

                const river_out =
                    registry.bind(global.name, river.OutputV1, 1) catch return;

                _ = output.create(ctx.wm, river_out) catch return;
            } else if (std.mem.eql(
                u8,
                interface_name,
                std.mem.span(river.SeatV1.interface.name),
            )) {
                std.log.info(
                    "[REGISTRY] Binding river_seat_v1 (Name: {})...",
                    .{global.name},
                );

                const river_seat =
                    registry.bind(global.name, river.SeatV1, 1) catch return;

                _ = seat.create(ctx.wm, river_seat) catch return;
            }
        },

        else => {},
    }
}

fn riverWmListener(
    river_wm: *river.WindowManagerV1,
    event: river.WindowManagerV1.Event,
    wm: *WindowManager,
) void {
    _ = wm;

    switch (event) {
        .manage_start => {
            std.log.info(
                "[RIVER] Received manage_start event. Starting layout calculation...",
                .{},
            );

            river_wm.manageFinish();
        },

        .render_start => {
            std.log.info(
                "[RIVER] Received render_start event.",
                .{},
            );

            river_wm.renderFinish();
        },

        else => {},
    }
}
