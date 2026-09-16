const std = @import("std");
const types = @import("types.zig");
const Strip = types.Strip;
const Column = types.Column;
const Window = types.Window;
const Rect = types.Rect;
const Config = types.Config;

pub fn calculateWindowHeight(column: *Column, total_height: i32) i32 {
    var count: i32 = 0;
    var it = column.windows.first();
    while (it) |node| : (it = node.next) {
        count += 1;
    }
    if (count == 0) return total_height;
    const gaps = (count - 1) * Config.gap;
    return @divTrunc(total_height - gaps, count);
}

pub fn scrollToColumn(strip: *Strip, target: *Column, output_width: i32) void {
    var current_x: i32 = Config.outer_margin;
    var it = strip.columns.first();

    while (it) |node| : (it = node.next) {
        const col: *Column = @fieldParentPtr("link", node);
        if (col == target) {
            if (current_x < strip.scroll_x) {
                strip.scroll_x = current_x;
            } else if (current_x + Config.strip_width > strip.scroll_x + output_width) {
                strip.scroll_x = current_x + Config.strip_width - output_width + Config.outer_margin;
            }
            break;
        }
        current_x += Config.strip_width + Config.gap;
    }
    if (strip.scroll_x < 0) strip.scroll_x = 0;
}

pub fn calculateLayout(strip: *Strip, output_rect: Rect) void {
    var col_x: i32 = Config.outer_margin - strip.scroll_x;
    var col_it = strip.columns.first();

    while (col_it) |col_node| : (col_it = col_node.next) {
        const col: *Column = @fieldParentPtr("link", col_node);
        const win_h = calculateWindowHeight(col, output_rect.h - (Config.outer_margin * 2));
        var win_y: i32 = output_rect.y + Config.outer_margin;

        var win_it = col.windows.first();
        while (win_it) |win_node| : (win_it = win_node.next) {
            const win: *Window = @fieldParentPtr("column_link", win_node);

            // Setzt die berechneten Dimensionen auf das Window
            win.dimensions = .{
                .width = @intCast(Config.strip_width),
                .height = @intCast(win_h),
            };

            // Platzierung per Wayland-Call erfolgt zentral in der Render-Schleife
            win.river_window.setPosition(col_x, win_y);
            win.river_window.proposeDimensions(win.dimensions.width, win.dimensions.height);

            win_y += win_h + Config.gap;
        }

        col_x += Config.strip_width + Config.gap;
    }
}
