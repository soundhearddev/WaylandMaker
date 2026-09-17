// SPDX-License-Identifier: 0BSD
//
// Pure geometry: given a Strip and the usable rectangle of its output,
// compute where every column and every window inside it should be. No
// Wayland calls happen here -- callers (main.zig's manage_start handler)
// take the x/y/width/height this leaves on each Window and turn them into
// `propose_dimensions` / `river_node.set_position` requests.

const std = @import("std");

const types = @import("types.zig");
const Strip = types.Strip;
const Column = types.Column;
const Window = types.Window;
const Rectangle = types.Rectangle;
const Config = types.Config;

/// Height of a single window inside a column that has `count` windows
/// stacked in it, given `total_height` usable pixels for the whole column.
pub fn windowHeight(count: i32, total_height: i32) i32 {
    if (count <= 0) return total_height;
    const total_gaps = (count - 1) * Config.gap;
    return @max(1, @divTrunc(total_height - total_gaps, count));
}

fn columnWindowCount(column: *Column) i32 {
    var count: i32 = 0;
    var it = column.windows.first();
    while (it) |win| : (it = types.nextWindowInColumn(win)) count += 1;
    return count;
}

pub fn calculateWindowHeight(column: *Column, usable_height: i32) i32 {
    const count = columnWindowCount(column);
    if (count == 0) return usable_height;
    return windowHeight(count, usable_height);
}

/// Scroll the strip just enough to bring `target` fully into view, without
/// moving it any further than necessary.
pub fn scrollToColumn(strip: *Strip, target: *Column, output_width: i32) void {
    const col_left = target.strip_x;
    const col_right = col_left + target.width;

    const margin = Config.gap * 2;

    if (col_left < strip.scroll_x + margin) {
        strip.scroll_x = @max(0, col_left - margin);
    } else if (col_right > strip.scroll_x + output_width - margin) {
        strip.scroll_x = col_right - output_width + margin;
    }
}

/// Snap back to 0 if total content width fits in output, eliminating dead space.
pub fn snapToEdge(strip: *Strip, output_width: i32) void {
    var content_width: i32 = Config.gap;
    var it = strip.columns.first();
    while (it) |col| : (it = types.nextColumn(col)) {
        content_width += col.width + Config.gap;
    }

    if (content_width <= output_width) {
        strip.scroll_x = 0;
        return;
    }

    const max_scroll = content_width - output_width;
    if (strip.scroll_x > max_scroll) strip.scroll_x = max_scroll;
    if (strip.scroll_x < 0) strip.scroll_x = 0;
}

/// Recompute strip_x for every column and x/y/width/height for every window in the strip.
pub fn recomputeGeometry(strip: *Strip, usable_rect: Rectangle) void {
    var current_strip_x: i32 = Config.gap;

    var col_it = strip.columns.first();
    while (col_it) |col| : (col_it = types.nextColumn(col)) {
        col.strip_x = current_strip_x;

        const count = columnWindowCount(col);
        const win_h = windowHeight(count, usable_rect.height - Config.gap * 2);

        var win_y: i32 = usable_rect.y + Config.gap;

        var win_it = col.windows.first();
        while (win_it) |win| : (win_it = types.nextWindowInColumn(win)) {
            win.x = usable_rect.x + col.strip_x - strip.scroll_x;
            win.y = win_y;
            win.width = col.width;
            win.height = win_h;

            win_y += win_h + Config.gap;
        }

        current_strip_x += col.width + Config.gap;
    }
}

/// Check if a window is completely offscreen horizontally.
pub fn isOffscreen(win: *const Window, usable_rect: Rectangle) bool {
    return win.x + win.width <= usable_rect.x or win.x >= usable_rect.x + usable_rect.width;
}
