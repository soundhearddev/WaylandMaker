// SPDX-License-Identifier: 0BSD
//
// Pure geometry: no Wayland calls, no allocation. Given the data model and
// a work area, this fills in `Window.target` for every window. main.zig
// then turns those targets into propose_dimensions / set_position.
//
// Terminology
//   outer box  - what the user sees: content + border on every side.
//   content    - what river's `dimensions`/`set_position` refer to.
//   strip x    - x inside the endless horizontal strip; 0 is the left edge of
//                the strip's padding, columns start at `outer_gap`.
//   viewport   - the part of the strip currently visible = the work area.

const std = @import("std");
const types = @import("types.zig");
const config = @import("config.zig");

const Rect = types.Rect;
const Window = types.Window;
const Column = types.Column;
const Strip = types.Strip;
const Workspace = types.Workspace;
const Output = types.Output;

// ----------------------------------------------------------------------------
// Widths
// ----------------------------------------------------------------------------

/// Outer width of a column that takes `fraction` of the work area.
///
/// With n = 1/fraction columns side by side there are n-1 inner gaps, so
///     n * w + (n-1) * gap = avail   =>   w = fraction * (avail + gap) - gap
/// which makes 1/2 + 1/2 and 1/3 + 1/3 + 1/3 tile flush, and fraction 1
/// give exactly `avail`.
pub fn columnWidthFor(work_w: i32, fraction: f64, cfg: *const config.Config) i32 {
    const avail: f64 = @floatFromInt(@max(1, work_w - 2 * cfg.outer_gap));
    const gap: f64 = @floatFromInt(cfg.gap);
    const w: i32 = @intFromFloat(@round(fraction * (avail + gap) - gap));
    return @max(minOuterWidth(cfg), w);
}

pub fn minOuterWidth(cfg: *const config.Config) i32 {
    return cfg.min_window_size + 2 * cfg.border_width;
}

// ----------------------------------------------------------------------------
// Strip geometry
// ----------------------------------------------------------------------------

/// Assign `Column.x` and return the total content width of the strip.
pub fn assignColumnX(strip: *Strip, cfg: *const config.Config) i32 {
    var x: i32 = cfg.outer_gap;
    var it = strip.columns.first();
    while (it) |col| : (it = types.nextCol(col)) {
        col.x = x;
        x += col.width + cfg.gap;
    }
    // The loop added one inner gap too many after the last column; the
    // strip ends with an outer gap instead.
    const cols = strip.columnCount();
    if (cols == 0) return 2 * cfg.outer_gap;
    return x - cfg.gap + cfg.outer_gap;
}

/// Clamp the viewport so it never shows dead space beyond the strip. If
/// everything fits, it is pinned to the left.
pub fn clampScroll(strip: *Strip, content_w: i32, view_w: i32) void {
    if (content_w <= view_w) {
        strip.scroll_x = 0;
        return;
    }
    strip.scroll_x = std.math.clamp(strip.scroll_x, 0, content_w - view_w);
}

/// Scroll so `col` is visible according to `mode`. Assumes `assignColumnX`
/// already ran for the current widths.
pub fn revealColumn(strip: *Strip, col: *Column, view_w: i32, content_w: i32, mode: config.CenterMode, cfg: *const config.Config) void {
    const left = col.x - cfg.outer_gap;
    const right = col.x + col.width + cfg.outer_gap;

    switch (mode) {
        .never => {},
        .always => strip.scroll_x = col.x + @divTrunc(col.width - view_w, 2),
        .on_overflow => {
            if (col.width + 2 * cfg.outer_gap >= view_w) {
                // Wider than the screen: align its left edge.
                strip.scroll_x = left;
            } else if (left < strip.scroll_x) {
                strip.scroll_x = left;
            } else if (right > strip.scroll_x + view_w) {
                strip.scroll_x = right - view_w;
            }
        },
    }
    clampScroll(strip, content_w, view_w);
}

/// Bring the active column of `strip` into view. Called whenever focus,
/// column widths or the column list changed.
pub fn followActive(strip: *Strip, view_w: i32, cfg: *const config.Config) void {
    const content_w = assignColumnX(strip, cfg);
    if (strip.active) |col| {
        revealColumn(strip, col, view_w, content_w, cfg.center_focused_column, cfg);
    } else {
        clampScroll(strip, content_w, view_w);
    }
}

/// Explicit scroll by `dx` pixels (scroll_left / scroll_right).
pub fn scrollBy(strip: *Strip, dx: i32, view_w: i32, cfg: *const config.Config) void {
    const content_w = assignColumnX(strip, cfg);
    strip.scroll_x += dx;
    clampScroll(strip, content_w, view_w);
}

/// Centre `col` in the viewport regardless of the configured mode.
pub fn centerColumn(strip: *Strip, col: *Column, view_w: i32, cfg: *const config.Config) void {
    const content_w = assignColumnX(strip, cfg);
    revealColumn(strip, col, view_w, content_w, .always, cfg);
}

// ----------------------------------------------------------------------------
// Height distribution inside a column
// ----------------------------------------------------------------------------

/// Outer height of each of `n` stacked windows in `total_h`. Returns the
/// base height and how many leading windows get one extra pixel so the
/// column is filled exactly (no 1px slivers at the bottom).
pub fn stackHeights(n: usize, total_h: i32, gap: i32) struct { base: i32, extra: usize } {
    if (n == 0) return .{ .base = total_h, .extra = 0 };
    const nn: i32 = @intCast(n);
    const usable = @max(nn, total_h - (nn - 1) * gap);
    return .{
        .base = @divTrunc(usable, nn),
        .extra = @intCast(@mod(usable, nn)),
    };
}

// ----------------------------------------------------------------------------
// The one entry point
// ----------------------------------------------------------------------------

/// Compute every window's `target` on `ws`. Also fixes up scrolling: the
/// strip is re-clamped/re-followed here so a width change, a closed window
/// or a changed work area can never leave the viewport out of range.
///
/// `follow` = the focus target changed this pass; scroll to reveal it.
pub fn compute(ws: *Workspace, cfg: *const config.Config, follow: bool) void {
    const out = ws.output;
    const work = out.workArea();
    const strip = &ws.strip;

    const content_w = assignColumnX(strip, cfg);
    if (follow) {
        followActive(strip, work.w, cfg);
    } else {
        clampScroll(strip, content_w, work.w);
    }

    const col_top = work.y + cfg.outer_gap;
    const col_h = @max(1, work.h - 2 * cfg.outer_gap);

    var cit = strip.columns.first();
    while (cit) |col| : (cit = types.nextCol(col)) {
        const n = col.count();
        const heights = stackHeights(n, col_h, cfg.gap);

        var y = col_top;
        var idx: usize = 0;
        var wit = col.windows.first();
        while (wit) |win| : ({
            wit = types.nextWin(win);
            idx += 1;
        }) {
            var h_outer = heights.base;
            if (idx < heights.extra) h_outer += 1;
            const bw = win.borderWidth(cfg); // NoBorder: the slot is all content

            const outer_x = work.x + col.x - strip.scroll_x;
            win.target = .{
                .x = outer_x + bw,
                .y = y + bw,
                .w = @max(1, col.width - 2 * bw),
                .h = @max(1, h_outer - 2 * bw),
            };
            y += h_outer + cfg.gap;
        }
    }

    computeFloating(ws, cfg);
    computeFullscreen(ws);
}

/// Floating windows keep their own rect (output-local), which layout only
/// translates to global coordinates and keeps reachable on screen.
fn computeFloating(ws: *Workspace, cfg: *const config.Config) void {
    const out = ws.output;
    var it = ws.floating.first();
    while (it) |win| : (it = types.nextFloating(win)) {
        if (!win.has_float_rect) initFloatRect(win, out, cfg);
        keepReachable(&win.float_rect, out.rect);
        win.target = .{
            .x = out.rect.x + win.float_rect.x,
            .y = out.rect.y + win.float_rect.y,
            .w = win.float_rect.w,
            .h = win.float_rect.h,
        };
    }
}

fn computeFullscreen(ws: *Workspace) void {
    const win = ws.fullscreen orelse return;
    // river owns fullscreen geometry; we only record it for hit-testing.
    win.target = ws.output.rect;
}

/// Give a window that has never floated a sensible centred rect.
pub fn initFloatRect(win: *Window, out: *const Output, cfg: *const config.Config) void {
    const work = out.workArea();
    const fw: i32 = @intFromFloat(@as(f64, @floatFromInt(work.w)) * cfg.floating_size);
    const fh: i32 = @intFromFloat(@as(f64, @floatFromInt(work.h)) * cfg.floating_size);
    const size = win.clampSize(fw, fh, cfg.min_window_size);

    // Dialogs and other small windows keep the size they asked for.
    const w = if (win.actual_w > 0 and win.actual_w < fw) win.actual_w else size.w;
    const h = if (win.actual_h > 0 and win.actual_h < fh) win.actual_h else size.h;

    win.float_rect = .{
        .x = (work.x - out.rect.x) + @divTrunc(work.w - w, 2),
        .y = (work.y - out.rect.y) + @divTrunc(work.h - h, 2),
        .w = w,
        .h = h,
    };
    win.has_float_rect = true;
}

/// Keep at least a grabbable strip of the window on screen so a floating
/// window can never be lost off the edge. Output-local coordinates.
pub fn keepReachable(r: *Rect, bounds: Rect) void {
    const grab: i32 = 48;
    const min_x = grab - r.w;
    const max_x = bounds.w - grab;
    const min_y = 0; // the top edge (where you grab it) must stay on screen
    const max_y = bounds.h - grab;
    r.x = std.math.clamp(r.x, min_x, @max(min_x, max_x));
    r.y = std.math.clamp(r.y, min_y, @max(min_y, max_y));
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

test "stackHeights fills the column exactly" {
    // 3 windows, gap 8 in 1000px: 1000 - 16 = 984 = 3 * 328
    const a = stackHeights(3, 1000, 8);
    try std.testing.expectEqual(@as(i32, 328), a.base);
    try std.testing.expectEqual(@as(usize, 0), a.extra);

    // 3 windows in 1001px -> one window gets the spare pixel
    const b = stackHeights(3, 1001, 8);
    const total: i32 = b.base * 3 + @as(i32, @intCast(b.extra)) + 16;
    try std.testing.expectEqual(@as(i32, 1001), total);
}

test "stackHeights single window uses everything" {
    const a = stackHeights(1, 500, 8);
    try std.testing.expectEqual(@as(i32, 500), a.base);
    try std.testing.expectEqual(@as(usize, 0), a.extra);
}

test "keepReachable never loses the window" {
    var r: Rect = .{ .x = 5000, .y = 5000, .w = 400, .h = 300 };
    keepReachable(&r, .{ .x = 0, .y = 0, .w = 1920, .h = 1080 });
    try std.testing.expect(r.x < 1920);
    try std.testing.expect(r.y < 1080);

    var l: Rect = .{ .x = -5000, .y = -5000, .w = 400, .h = 300 };
    keepReachable(&l, .{ .x = 0, .y = 0, .w = 1920, .h = 1080 });
    try std.testing.expect(l.x + l.w > 0);
    try std.testing.expect(l.y >= 0);
}

test "clampScroll pins to the left when everything fits" {
    var strip: Strip = undefined;
    strip.scroll_x = 300;
    clampScroll(&strip, 800, 1000);
    try std.testing.expectEqual(@as(i32, 0), strip.scroll_x);
}

test "clampScroll limits to content - view" {
    var strip: Strip = undefined;
    strip.scroll_x = 9999;
    clampScroll(&strip, 3000, 1000);
    try std.testing.expectEqual(@as(i32, 2000), strip.scroll_x);
    strip.scroll_x = -50;
    clampScroll(&strip, 3000, 1000);
    try std.testing.expectEqual(@as(i32, 0), strip.scroll_x);
}

test "columnWidthFor tiles flush" {
    var cfg: config.Config = .{ .arena = undefined };
    cfg.gap = 8;
    cfg.outer_gap = 8;
    cfg.border_width = 2;
    cfg.min_window_size = 120;
    // 1920 wide: avail = 1904
    try std.testing.expectEqual(@as(i32, 948), columnWidthFor(1920, 0.5, &cfg));
    try std.testing.expectEqual(@as(i32, 1904), columnWidthFor(1920, 1.0, &cfg));
    // three thirds: 3*629 + 2*8 = 1903, within rounding of 1904
    const third = columnWidthFor(1920, 1.0 / 3.0, &cfg);
    try std.testing.expect(@abs(3 * third + 2 * 8 - 1904) <= 3);
}
