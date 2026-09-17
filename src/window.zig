const std = @import("std");
const wayland = @import("wayland");
const river = wayland.client.river;

const types = @import("types.zig");
const layout = @import("layout.zig");
const seat = @import("seat.zig");

const WindowManager = types.WindowManager;
const Window = types.Window;
const Column = types.Column;
const Strip = types.Strip;

pub fn create(
    wm: *WindowManager,
    river_win: *river.WindowV1,
    river_node: ?*river.NodeV1,
) !*Window {
    std.log.info("[WINDOW] Creating new window object", .{});

    const win = try wm.gpa.create(Window);

    win.* = .{
        .obj = river_win,
        .node = river_node,
        .link = undefined,
        .width = types.Config.default_column_width,
        .height = 0,
        .x = 0,
        .y = 0,
        .new = true,
        .ready = false,
        .column = null,
    };

    wm.windows.append(win);
    river_win.setListener(*Window, windowListener, win);

    return win;
}

pub fn manage(win: *Window, wm: *WindowManager) void {
    std.log.info("[WINDOW] Managing window...", .{});

    win.new = false;
    win.obj.useSsd();

    if (win.node == null) {
        win.node = win.obj.getNode() catch |err| {
            std.log.err("[WINDOW] Failed to get river node: {}", .{err});
            return;
        };
        std.log.info("[WINDOW] Successfully obtained river node for window", .{});
    }

    var target_width: i32 = types.Config.default_column_width;
    var target_height: i32 = 800;

    if (wm.outputs.first()) |out| {
        const workspace = out.activeWorkspace();
        assignToStrip(&workspace.strip, win, wm.gpa);

        const rect = out.usableRect();
        layout.recomputeGeometry(&workspace.strip, rect);

        if (rect.height > 0) target_height = rect.height;
        if (win.width > 0) target_width = win.width;

        if (win.node) |node| {
            node.setPosition(win.x, win.y);
            std.log.info("[WINDOW] Set node position to ({d}, {d})", .{ win.x, win.y });
        }
    } else {
        std.log.warn("[WINDOW] No bound output available. Using fallback layout dimensions ({d}x{d}).", .{ target_width, target_height });
    }

    win.height = target_height;
    win.width = target_width;

    win.obj.proposeDimensions(win.width, win.height);

    if (wm.seats.first()) |s| {
        seat.focus(s, win);
    }
}

pub fn assignToStrip(
    strip: *Strip,
    win: *Window,
    gpa: std.mem.Allocator,
) void {
    std.log.info("[STRIP] Inserting new column for window", .{});

    const col = gpa.create(Column) catch return;
    col.* = .{
        .strip = strip,
        .link = undefined,
        .windows = undefined,
    };
    col.windows.init();
    col.windows.append(win);
    win.column = col;

    if (strip.active_column) |active| {
        if (active.link.next) |next_link| {
            col.link.next = next_link;
            col.link.prev = &active.link;
            active.link.next = &col.link;
            next_link.prev = &col.link;
        } else {
            strip.columns.append(col);
        }
    } else {
        strip.columns.append(col);
    }

    strip.active_column = col;
}

fn windowListener(
    river_win: *river.WindowV1,
    event: river.WindowV1.Event,
    win: *Window,
) void {
    _ = river_win;

    switch (event) {
        .dimensions => |dim| {
            win.width = dim.width;
            win.height = dim.height;
            win.ready = true;
            std.log.info("[WINDOW] Received dimensions: {d}x{d}", .{ dim.width, dim.height });
        },
        else => {
            std.log.debug("[EVENT] Received river_window_v1 event", .{});
        },
    }
}
