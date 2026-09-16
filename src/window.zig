const std = @import("std");

const wayland = @import("wayland");
const river = wayland.client.river;

const types = @import("types.zig");
const layout = @import("layout.zig");

const WindowManager = types.WindowManager;
const Window = types.Window;
const Column = types.Column;
const Strip = types.Strip;

pub fn create(
    wm: *WindowManager,
    river_win: *river.WindowV1,
    river_node: *river.NodeV1,
) !*Window {
    std.log.info("[WINDOW] Creating new window object", .{});

    const win = try wm.gpa.create(Window);

    win.* = .{
        .obj = river_win,
        .node = river_node,
        .link = undefined,
        .width = types.Config.default_column_width,
        .height = 0,
    };

    wm.windows.append(win);
    river_win.setListener(*Window, windowListener, win);

    return win;
}

pub fn manage(win: *Window, wm: *WindowManager) void {
    std.log.info("[WINDOW] manage() called", .{});

    win.new = false;
    win.obj.useSsd();

    if (wm.outputs.first()) |out| {
        const workspace = out.activeWorkspace();

        assignToStrip(&workspace.strip, win, wm.gpa);

        const rect = out.usableRect();
        layout.recomputeGeometry(&workspace.strip, rect);

        std.log.info(
            "[WINDOW] Assigned to strip. X: {}, Y: {}, W: {}, H: {}",
            .{
                win.x,
                win.y,
                win.width,
                win.height,
            },
        );

        win.obj.setPosition(win.x, win.y);
        win.obj.proposeDimensions(win.width, win.height);
    } else {
        std.log.err("[WINDOW] No output available!", .{});
    }
}

pub fn assignToStrip(
    strip: *Strip,
    win: *Window,
    gpa: std.mem.Allocator,
) void {
    std.log.info(
        "[STRIP] Adding window to a new column in the strip",
        .{},
    );

    const col = gpa.create(Column) catch return;

    col.* = .{
        .strip = strip,
        .link = undefined,
        .windows = undefined,
    };

    col.windows.init();

    strip.columns.append(col);
    col.windows.append(win);
    win.column = col;

    strip.active_column = col;
}

fn windowListener(
    river_win: *river.WindowV1,
    event: river.WindowV1.Event,
    win: *Window,
) void {
    _ = river_win;
    _ = win;

    switch (event) {
        .manage => {
            std.log.info(
                "[EVENT] river_window_v1 -> manage",
                .{},
            );
        },

        else => {
            std.log.debug(
                "[EVENT] Received river_window_v1 event",
                .{},
            );
        },
    }
}
