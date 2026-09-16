const std = @import("std");

const types = @import("types.zig");
const Strip = types.Strip;
const Column = types.Column;
const Window = types.Window;
const Rectangle = types.Rectangle;
const Config = types.Config;

pub fn calculateWindowHeight(column: *Column, total_height: i32) i32 {
    var count: i32 = 0;
    var it = column.windows.first();

    while (it) |win| : (it = if (win.column_link.next) |n|
        @fieldParentPtr("column_link", n)
    else
        null)
    {
        count += 1;
    }

    if (count == 0) {
        return total_height;
    }

    const total_gaps = (count - 1) * Config.gap;

    return @divTrunc(total_height - total_gaps, count);
}

pub fn scrollToColumn(
    strip: *Strip,
    target: *Column,
    output_width: i32,
) void {
    const col_left = target.strip_x;
    const col_right = col_left + target.width;

    if (col_left < strip.scroll_x) {
        strip.scroll_x = col_left - Config.gap;
    } else if (col_right > strip.scroll_x + output_width) {
        strip.scroll_x = col_right - output_width + Config.gap;
    }

    if (strip.scroll_x < 0) {
        strip.scroll_x = 0;
    }
}

pub fn recomputeGeometry(
    strip: *Strip,
    usable_rect: Rectangle,
) void {
    var current_strip_x: i32 = Config.gap;

    var col_it = strip.columns.first();

    while (col_it) |col| : (col_it = if (col.link.next) |n|
        @fieldParentPtr("link", n)
    else
        null)
    {
        col.strip_x = current_strip_x;

        const win_h = calculateWindowHeight(
            col,
            usable_rect.height - (Config.gap * 2),
        );

        var win_y: i32 = usable_rect.y + Config.gap;

        var win_it = col.windows.first();

        while (win_it) |win| : (win_it = if (win.column_link.next) |n|
            @fieldParentPtr("column_link", n)
        else
            null)
        {
            win.x = usable_rect.x + col.strip_x - strip.scroll_x;
            win.y = win_y;
            win.width = col.width;
            win.height = win_h;

            win_y += win_h + Config.gap;
        }

        current_strip_x += col.width + Config.gap;
    }
}
