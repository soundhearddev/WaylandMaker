// SPDX-License-Identifier: GPL-3.0
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

/// Column widths are absolute pixels, fitted to the work area they were made
/// for. When the work area changes width (the Dock was reserved after the
/// window opened, a layer-shell bar came or went, the Dock moved to the
/// other edge) every column keeps its share of it, or a column made for the
/// full width would still stretch under the Dock.
pub fn rescaleColumns(strip: *Strip, work_w: i32, cfg: *const config.Config) void {
    const old_w = strip.work_w;
    strip.work_w = work_w;
    if (old_w <= 0 or old_w == work_w) return;

    const gap: f64 = @floatFromInt(cfg.gap);
    const old_avail: f64 = @floatFromInt(@max(1, old_w - 2 * cfg.outer_gap));
    const new_avail: f64 = @floatFromInt(@max(1, work_w - 2 * cfg.outer_gap));
    var it = strip.columns.first();
    while (it) |col| : (it = types.nextCol(col)) {
        const frac = (@as(f64, @floatFromInt(col.width)) + gap) / (old_avail + gap);
        const w: i32 = @intFromFloat(@round(frac * (new_avail + gap) - gap));
        col.width = @max(minOuterWidth(cfg), w);
        // The remembered pre-maximize width is scaled the same way.
        if (col.unmaximized_width > 0) {
            const uf = (@as(f64, @floatFromInt(col.unmaximized_width)) + gap) / (old_avail + gap);
            const uw: i32 = @intFromFloat(@round(uf * (new_avail + gap) - gap));
            col.unmaximized_width = @max(minOuterWidth(cfg), uw);
        }
    }
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

/// Keep the view on a maximized active column: it fills the work area, so
/// its left edge is the viewport's left edge, whatever `center_focused_column`
/// says. Returns whether it did anything.
pub fn lockMaximized(strip: *Strip, view_w: i32, cfg: *const config.Config) bool {
    if (!cfg.maximize_follow) return false;
    const col = strip.active orelse return false;
    if (!col.isMaximized()) return false;
    const content_w = assignColumnX(strip, cfg);
    revealColumn(strip, col, view_w, content_w, .on_overflow, cfg);
    return true;
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

    rescaleColumns(strip, work.w, cfg);
    const content_w = assignColumnX(strip, cfg);
    if (follow) {
        followActive(strip, work.w, cfg);
    } else {
        clampScroll(strip, content_w, work.w);
    }
    // A maximized active column keeps the camera, whatever happened (a
    // scroll command, a Dock that appeared, a window that opened elsewhere).
    _ = lockMaximized(strip, work.w, cfg);
    strip.offset_x = centeringOffset(strip.columnCount(), content_w, work.w, cfg);

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

            const outer_x = work.x + col.x - strip.scroll_x + strip.offset_x;
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

/// `center_single_column`: how far a lone column that is narrower than the
/// work area moves right to sit in the middle. 0 in every other case.
pub fn centeringOffset(columns: usize, content_w: i32, view_w: i32, cfg: *const config.Config) i32 {
    if (!cfg.center_single_column or columns != 1 or content_w >= view_w) return 0;
    return @divTrunc(view_w - content_w, 2);
}

/// Floating windows keep their own rect (output-local), which layout only
/// translates to global coordinates and keeps reachable on screen.
fn computeFloating(ws: *Workspace, cfg: *const config.Config) void {
    const out = ws.output;
    var it = ws.floating.first();
    while (it) |win| : (it = types.nextFloating(win)) {
        if (!win.has_float_rect) initFloatRect(win, out, cfg);
        // Output-local work area: the part of the window you grab must not
        // end up under the Dock either.
        const work = out.workArea();
        const local: Rect = .{
            .x = work.x - out.rect.x,
            .y = work.y - out.rect.y,
            .w = work.w,
            .h = work.h,
        };
        keepReachable(&win.float_rect, local);
        keepOutOfReserved(&win.float_rect, local, out.reserved);
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
/// On a side where the Dock reserved space, a floating window stays entirely
/// inside the work area (it is moved, not resized; one too big for the area
/// sticks to the near edge). Sides nothing was reserved on keep their
/// freedom.
pub fn keepOutOfReserved(r: *Rect, local: Rect, res: Output.Insets) void {
    if (res.left > 0 or res.right > 0) {
        const max_x = local.x + local.w - r.w;
        r.x = if (max_x < local.x) local.x else std.math.clamp(r.x, local.x, max_x);
    }
    if (res.top > 0 or res.bottom > 0) {
        const max_y = local.y + local.h - r.h;
        r.y = if (max_y < local.y) local.y else std.math.clamp(r.y, local.y, max_y);
    }
}

pub fn keepReachable(r: *Rect, bounds: Rect) void {
    const grab: i32 = 48;
    const min_x = bounds.x + grab - r.w;
    const max_x = bounds.x + bounds.w - grab;
    const min_y = bounds.y; // the top edge (where you grab it) must stay on screen
    const max_y = bounds.y + bounds.h - grab;
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

test "keepOutOfReserved: a floating window never covers the Dock's strip" {
    const local: Rect = .{ .x = 0, .y = 0, .w = 1856, .h = 1080 };
    var a: Rect = .{ .x = 1700, .y = 50, .w = 400, .h = 300 };
    keepOutOfReserved(&a, local, .{ .right = 64 });
    try std.testing.expectEqual(@as(i32, 1856 - 400), a.x);
    try std.testing.expectEqual(@as(i32, 50), a.y);
    var b: Rect = .{ .x = 10, .y = 50, .w = 400, .h = 300 };
    keepOutOfReserved(&b, .{ .x = 64, .y = 0, .w = 1856, .h = 1080 }, .{ .left = 64 });
    try std.testing.expectEqual(@as(i32, 64), b.x);
    var c: Rect = .{ .x = -300, .y = 50, .w = 400, .h = 300 };
    keepOutOfReserved(&c, local, .{});
    try std.testing.expectEqual(@as(i32, -300), c.x);
    var d: Rect = .{ .x = 500, .y = 0, .w = 3000, .h = 300 };
    keepOutOfReserved(&d, local, .{ .right = 64 });
    try std.testing.expectEqual(@as(i32, 0), d.x);
}

test "keepReachable keeps the grab zone out of a reserved strip" {
    // 64px reserved on the left (a Dock): the window may not be pushed
    // further left than its last 48px of grab zone beyond the strip.
    var r: Rect = .{ .x = -5000, .y = 100, .w = 400, .h = 300 };
    keepReachable(&r, .{ .x = 64, .y = 0, .w = 1856, .h = 1080 });
    try std.testing.expectEqual(@as(i32, 64 + 48 - 400), r.x);
    // On the right: at least 48px stay left of the reserved strip.
    var q: Rect = .{ .x = 9000, .y = 100, .w = 400, .h = 300 };
    keepReachable(&q, .{ .x = 0, .y = 0, .w = 1856, .h = 1080 });
    try std.testing.expectEqual(@as(i32, 1856 - 48), q.x);
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

test "lockMaximized pins the camera to a maximized active column" {
    var cfg: config.Config = .{ .arena = undefined };
    cfg.outer_gap = 8;
    var ws: Workspace = undefined;
    var strip: Strip = .{ .workspace = &ws, .columns = undefined };
    strip.columns.init();
    var a: Column = .{ .strip = &strip, .windows = undefined, .width = 500 };
    var b: Column = .{ .strip = &strip, .windows = undefined, .width = 1904, .unmaximized_width = 500 };
    var c: Column = .{ .strip = &strip, .windows = undefined, .width = 500 };
    strip.columns.append(&a);
    strip.columns.append(&b);
    strip.columns.append(&c);
    strip.active = &b;
    strip.scroll_x = 300; // the camera drifted away
    try std.testing.expect(lockMaximized(&strip, 1920, &cfg));
    try std.testing.expectEqual(b.x - 8, strip.scroll_x);

    cfg.maximize_follow = false;
    strip.scroll_x = 300;
    try std.testing.expect(!lockMaximized(&strip, 1920, &cfg));
    try std.testing.expectEqual(@as(i32, 300), strip.scroll_x);

    // not maximized: nothing to lock
    cfg.maximize_follow = true;
    b.unmaximized_width = 0;
    try std.testing.expect(!lockMaximized(&strip, 1920, &cfg));
}

test "centeringOffset centres only a lone column that does not fill the view" {
    var cfg: config.Config = .{ .arena = undefined };
    try std.testing.expectEqual(@as(i32, 0), centeringOffset(1, 600, 1920, &cfg));
    cfg.center_single_column = true;
    try std.testing.expectEqual(@as(i32, 660), centeringOffset(1, 600, 1920, &cfg));
    try std.testing.expectEqual(@as(i32, 0), centeringOffset(2, 600, 1920, &cfg));
    try std.testing.expectEqual(@as(i32, 0), centeringOffset(1, 1920, 1920, &cfg));
}
