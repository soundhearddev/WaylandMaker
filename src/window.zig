const std = @import("std");
const wayland = @import("wayland");
const wl = wayland.client.wl;
const river = wayland.client.river;

const types = @import("types.zig");
const WindowManager = types.WindowManager;
const Window = types.Window;
const Column = types.Column;
const Strip = types.Strip;
const layout = @import("layout.zig");

pub fn create(wm: *WindowManager, river_win: *river.WindowV1) !*Window {
    const window = try wm.allocator.create(Window);
    window.* = .{
        .river_window = river_win,
    };

    river_win.setListener(*Window, windowListener, window);
    return window;
}

pub fn manage(window: *Window, wm: *WindowManager) void {
    window.is_managed = true;
    window.river_window.useSsd();

    // Zuweisung zum Strip (vorerst erster Output)
    if (wm.outputs.first()) |output_node| {
        const output: *types.Output = @fieldParentPtr("link", output_node);
        const workspace = output.getActiveWorkspace();
        addWindowToStrip(&workspace.strip, window, wm.allocator);
    }
}

pub fn addWindowToStrip(strip: *Strip, window: *Window, allocator: std.mem.Allocator) void {
    const col = allocator.create(Column) catch return;
    col.* = Column.init(strip);

    strip.columns.append(&col.link);
    col.windows.append(&window.column_link);
    window.column = col;

    strip.active_column = col;
    col.active_window = window;
}

pub fn removeWindow(strip: *Strip, window: *Window, allocator: std.mem.Allocator) void {
    const column = window.column orelse return;
    window.column_link.remove();
    window.column = null;

    if (column.isEmpty()) {
        if (strip.active_column == column) {
            strip.active_column = if (column.link.next != &strip.columns.link)
                @fieldParentPtr("link", column.link.next.?)
            else if (column.link.prev != &strip.columns.link)
                @fieldParentPtr("link", column.link.prev.?)
            else
                null;
        }
        column.link.remove();
        allocator.destroy(column);
    }
}

fn windowListener(river_win: *river.WindowV1, event: river.WindowV1.Event, window: *Window) void {
    _ = river_win;
    _ = window;

    switch (event) {
        .manage => {
            // Wird vom WindowManager Event-Handler aufgerufen
        },
        .destroy => {
            // Cleanup
        },
        else => {},
    }
}
