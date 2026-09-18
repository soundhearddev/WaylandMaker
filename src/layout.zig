// SPDX-License-Identifier: 0BSD
//
// Pure geometry for the scrollable strip. No Wayland calls happen here:
// callers (main.zig) turn the x/y/width/height this leaves on every Window
// into propose_dimensions / node.set_position requests.
//
// Coordinates:
//   strip_x  - position inside the endless strip (0 = left edge of first col)
//   win.x/y  - final position on the *output* (already minus scroll_x, plus
//              the output's own origin)

const std = @import("std");

const types = @import("types.zig");
const Strip = types.Strip;
const Column = types.Column;
const Window = types.Window;
const Rectangle = types.Rectangle;
const Config = types.Config;

/// Width of a newly created column for an output `usable_width` wide.
pub fn defaultColumnWidth(usable_width: i32) i32 {
    const avail: f64 = @floatFromInt(@max(0, usable_width - Config.gap * 2));
    const w: i32 = @intFromFloat(avail * Config.default_column_width_fraction);
    return @max(Config.min_column_width, w);
}

/// Width of a column for a given fraction of the usable width.
pub fn widthForFraction(usable_width: i32, fraction: f64) i32 {
    const avail: f64 = @floatFromInt(@max(0, usable_width - Config.gap * 2));
    const w: i32 = @intFromFloat(avail * fraction);
    return @max(Config.min_column_width, w);
}

/// Total width of all columns including the outer gaps.
pub fn contentWidth(strip: *Strip) i32 {
    var total: i32 = Config.gap;
    var it = strip.columns.first();
    while (it) |col| : (it = types.nextColumn(col)) {
        total += col.width + Config.gap;
    }
    return total;
}

/// Compute strip_x for every column. Must run before scrolling math.
fn assignStripX(strip: *Strip) void {
    var x: i32 = Config.gap;
    var it = strip.columns.first();
    while (it) |col| : (it = types.nextColumn(col)) {
        col.strip_x = x;
        x += col.width + Config.gap;
    }
}

/// Keep the viewport inside [0, content - viewport]. If everything fits on
/// screen the strip is pinned to the left edge (no dead space).
pub fn clampScroll(strip: *Strip, viewport_width: i32) void {
    const content = contentWidth(strip);
    if (content <= viewport_width) {
        strip.scroll_x = 0;
        return;
    }
    const max_scroll = content - viewport_width;
    strip.scroll_x = std.math.clamp(strip.scroll_x, 0, max_scroll);
}

/// niri-style "follow focus": scroll the *minimum* amount that brings the
/// whole column into view. If it is already fully visible, nothing moves.
/// If the column is wider than the viewport, its left edge is aligned.
pub fn scrollToColumn(strip: *Strip, target: *Column, viewport_width: i32) void {
    assignStripX(strip);

    const left = target.strip_x - Config.gap;
    const right = target.strip_x + target.width + Config.gap;

    if (target.width + Config.gap * 2 >= viewport_width) {
        strip.scroll_x = left;
    } else if (left < strip.scroll_x) {
        strip.scroll_x = left;
    } else if (right > strip.scroll_x + viewport_width) {
        strip.scroll_x = right - viewport_width;
    }
    clampScroll(strip, viewport_width);
}

/// Height of one window in a column stacked with `count` windows.
pub fn windowHeight(count: i32, total_height: i32) i32 {
    if (count <= 0) return total_height;
    const total_gaps = (count - 1) * Config.gap;
    return @max(1, @divTrunc(total_height - total_gaps, count));
}

/// Recompute strip_x per column and x/y/width/height per window.
///
/// Sizes account for the border: river's dimensions refer to the *content*
/// only and borders are drawn on top, so the content is shrunk by the
/// border width on each side to keep the visual box inside its slot.
pub fn recomputeGeometry(strip: *Strip, usable: Rectangle) void {
    assignStripX(strip);
    clampScroll(strip, usable.width);

    const bw = Config.border_width;

    var col_it = strip.columns.first();
    while (col_it) |col| : (col_it = types.nextColumn(col)) {
        const count = col.windowCount();
        const slot_h = windowHeight(count, usable.height - Config.gap * 2);

        var y: i32 = usable.y + Config.gap;

        var win_it = col.windows.first();
        while (win_it) |win| : (win_it = types.nextWindowInColumn(win)) {
            win.x = usable.x + col.strip_x - strip.scroll_x + bw;
            win.y = y + bw;
            win.width = @max(1, col.width - bw * 2);
            win.height = @max(1, slot_h - bw * 2);
            y += slot_h + Config.gap;
        }
    }
}

/// True if the window's slot is completely outside the viewport.
pub fn isOffscreen(win: *const Window, usable: Rectangle) bool {
    return win.x + win.width <= usable.x or win.x >= usable.x + usable.width;
}
