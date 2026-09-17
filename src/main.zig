const std = @import("std");
const wayland = @import("wayland");
const wl = wayland.client.wl;
const river = wayland.client.river;

const types = @import("types.zig");
const layout = @import("layout.zig");
const window_mod = @import("window.zig");
const output = @import("output.zig");
const seat = @import("seat.zig");
const action = @import("action.zig");

const WindowManager = types.WindowManager;

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer if (gpa.deinit() == .leak) {
        std.log.err("[MEM] Memory leak detected!", .{});
    };

    const allocator = gpa.allocator();

    std.log.info("[INIT] Connecting to Wayland display...", .{});
    const display = try wl.Display.connect(null);
    defer display.disconnect();

    const wm = try allocator.create(WindowManager);
    defer allocator.destroy(wm);

    wm.* = .{
        .gpa = allocator,
        .obj = null,
        .xkb_bindings = null,
        .outputs = undefined,
        .windows = undefined,
        .seats = undefined,
        .pending_windows = .empty,
        .needs_layout = true,
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

    if (display.roundtrip() != .SUCCESS) {
        std.log.err("[INIT] Initial display roundtrip failed.", .{});
        return;
    }

    std.log.info("[INIT] wmaker-wl started successfully. Entering event loop...", .{});

    while (display.dispatch() == .SUCCESS) {}

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

            if (std.mem.eql(u8, interface_name, std.mem.span(river.WindowManagerV1.interface.name))) {
                std.log.info("[REGISTRY] Binding river_window_manager_v1 (Name: {d})", .{global.name});
                const river_wm = registry.bind(global.name, river.WindowManagerV1, 1) catch return;
                ctx.wm.obj = river_wm;
                river_wm.setListener(*WindowManager, riverWmListener, ctx.wm);
            } else if (std.mem.eql(u8, interface_name, std.mem.span(river.OutputV1.interface.name))) {
                std.log.info("[REGISTRY] Binding river_output_v1 (Name: {d})", .{global.name});
                const river_out = registry.bind(global.name, river.OutputV1, 1) catch return;
                _ = output.create(ctx.wm, river_out) catch return;
            } else if (std.mem.eql(u8, interface_name, std.mem.span(river.SeatV1.interface.name))) {
                std.log.info("[REGISTRY] Binding river_seat_v1 (Name: {d})", .{global.name});
                const river_seat = registry.bind(global.name, river.SeatV1, 1) catch return;
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
    switch (event) {
        .window => |ev| {
            std.log.info("[RIVER] -> New window event received", .{});
            _ = window_mod.create(wm, ev.id, null) catch |err| {
                std.log.err("[WINDOW] Failed to create window: {}", .{err});
            };
        },
        .manage_start => handleManageStart(river_wm, wm),
        .render_start => handleRenderStart(river_wm, wm),
        else => {},
    }
}

fn handleManageStart(river_wm: *river.WindowManagerV1, wm: *WindowManager) void {
    std.log.info("[RIVER] -> MANAGE_START received", .{});

    var count: u32 = 0;
    var win_it = wm.windows.first();

    while (win_it) |win| {
        count += 1;
        const next_win = types.nextWindow(win, wm);

        if (win.new) {
            std.log.info("[MANAGE] Managing window {x}", .{@intFromPtr(win)});
            window_mod.manage(win, wm);
        }
        win_it = next_win;
    }

    river_wm.manageFinish();
    std.log.info("[RIVER] <- MANAGE_FINISH sent ({d} windows checked)", .{count});
}

fn handleRenderStart(river_wm: *river.WindowManagerV1, wm: *WindowManager) void {
    std.log.info("[RIVER] -> RENDER_START received", .{});

    var out_it = wm.outputs.first();
    while (out_it) |out| {
        const next_out = types.nextOutput(out);

        // Skip unready outputs
        if (!out.isReady()) {
            out_it = next_out;
            continue;
        }

        const ws = out.activeWorkspace();
        const rect = out.usableRect();

        // Recalculate layout geometry
        layout.recomputeGeometry(&ws.strip, rect);

        var col_it = ws.strip.columns.first();
        while (col_it) |col| {
            const next_col = types.nextColumn(col);

            var w_it = col.windows.first();
            while (w_it) |win| {
                const next_w = types.nextWindowInColumn(win);

                if (win.node) |node| {
                    node.setPosition(win.x, win.y);
                }
                win.obj.proposeDimensions(win.width, win.height);

                w_it = next_w;
            }
            col_it = next_col;
        }
        out_it = next_out;
    }

    wm.needs_layout = false;
    river_wm.renderFinish();
    std.log.info("[RIVER] <- RENDER_FINISH sent", .{});
}
