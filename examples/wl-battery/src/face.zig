// SPDX-License-Identifier: 0BSD
//
// The battery face: one square ARGB tile, drawn by hand into a pixel array
// at whatever side the Dock tile has (16..256 px, wmaker-wl's `dock_size`).
// No Wayland and no libc in here, so all of it is unit-testable.
//
// Like wl-clock's face it is NOT drawn at 64x64 and stretched: it is designed
// on a 64x64 grid ("design units") and scale.Metrics maps every position,
// line width, digit, icon cell and pixel-font magnification to whole pixels
// of the real tile (see wl-clock/src/face.zig and scale.zig). At 64 px this
// is exactly the old picture.
//
// Same look as wl-clock / wmaker-wl's Dock tiles: bevelled tile, recessed LCD.
//
//     +------------------+
//     |  .------------.  |
//     |  | ⚡ 🔌   12W |  |   status icon, plug (AC), power
//     |  |   8 7 8 %  |  |   percent, seven segments
//     |  | ◷ 1:23     |  |   clock icon, time to empty / full
//     |  | ######---- |  |   10-segment bar
//     |  '------------'  |
//     +------------------+
//
// Status is a symbol, not a word: bolt = charging, arrow down = discharging,
// check = full, pause = not charging, ? = unknown, cross = no battery.

const std = @import("std");
const battery = @import("battery.zig");
const scale = @import("scale.zig");

/// The design grid: Window Maker's classic dock tile.
pub const native = scale.native;
/// The side to draw at when nobody proposed one.
pub const tile: i32 = native;

/// Room for the biggest tile (256 x 256).
pub const Pixels = [scale.max_pixels]u32;

/// Where a frame is drawn: `side` x `side` ARGB pixels and the design grid
/// laid over them.
pub const Canvas = struct {
    px: []u32,
    m: scale.Metrics,

    /// `px` must hold at least side*side pixels (`side` is kept in range).
    pub fn init(px: []u32, side: i32) Canvas {
        const m = scale.Metrics.init(side);
        std.debug.assert(px.len >= m.pixels());
        return .{ .px = px[0..m.pixels()], .m = m };
    }

    fn at(cv: Canvas, x: i32, y: i32) ?usize {
        if (x < 0 or y < 0 or x >= cv.m.side or y >= cv.m.side) return null;
        return @intCast(y * cv.m.side + x);
    }
};

pub const Info = battery.Info;

// ----------------------------------------------------------------------------
// Palette. The tile colours are dock.zig's (col_tile_from/to, bevel); the LCD
// is the classic green-on-dark of Window Maker clock dockapps.
// ----------------------------------------------------------------------------

const col_tile_from: u32 = 0xffc6c2c6;
const col_tile_to: u32 = 0xff9a969a;
const col_light: u32 = 0xffffffff;
const col_dark: u32 = 0xff555555;
const col_lcd: u32 = 0xff0d1a12;
const col_lit: u32 = 0xff62f08a;
const col_ghost: u32 = 0xff15301f;
const col_text: u32 = 0xff49c46d;
const col_amber: u32 = 0xfff0c05a;
const col_red: u32 = 0xfff0605a;

// Where things are, in DESIGN units (64x64). `layout` maps them to pixels.
const lcd_x = 6;
const lcd_y = 6;
const lcd_w = 52;
const lcd_h = 52;

const text_x = 8;
const text_right = 56;
const row_a_y = 8; // status icon, plug, power (icons up to 10 units, text magnification 2)
const plug_x = 19;
const digits_y = 20;
const digit_w = 9;
const digit_h = 20;
const digits_x = 12; // hundreds, tens, ones: 9 wide, 2 gaps; then the % sign
const row_c_y = 42; // clock icon, time (magnification 2)
const bar_x = 7;
const bar_y = 53;
const seg_n = 10;
const seg_w = 4;
const seg_gap = 1;
const bar_h = 4;

/// The same places in device pixels of one tile size.
pub const Layout = struct {
    /// The LCD's glass and the thickness of the bevel around it.
    glass: scale.Box,
    frame: i32,
    /// Power text: right edge, top, and the room it has (between plug and edge).
    power_right: i32,
    row_a_y: i32,
    power_w: i32,
    power_h: i32,
    /// Left edges of the three digit cells, their top, and the % sign.
    digit_x: [3]i32,
    digits_y: i32,
    pct_x: i32,
    pct_bottom: i32,
    pct_w: i32,
    pct_h: i32,
    /// Time text: left, top, and its room.
    time_x: i32,
    row_c_y: i32,
    time_w: i32,
    time_h: i32,
    /// The whole bar, and the pixels between two segments.
    bar: scale.Box,
    seg_gap: i32,
};

pub fn layout(m: scale.Metrics) Layout {
    const right = m.edge(text_right);
    const bar = atLeast1(m.box(bar_x, bar_y, seg_n * seg_w + (seg_n - 1) * seg_gap, bar_h));
    return .{
        .glass = m.box(lcd_x, lcd_y, lcd_w, lcd_h),
        .frame = m.stroke(1),
        .power_right = right,
        .row_a_y = m.edge(row_a_y),
        .power_w = right - m.edge(plug_x + 7),
        .power_h = m.len(row_a_y, digits_y - row_a_y),
        .digit_x = .{ m.edge(digits_x), m.edge(digits_x + 11), m.edge(digits_x + 22) },
        .digits_y = m.edge(digits_y),
        .pct_x = m.edge(digits_x + 22 + digit_w + 3),
        .pct_bottom = m.edge(digits_y + digit_h),
        .pct_w = right - m.edge(digits_x + 22 + digit_w + 3),
        .pct_h = m.len(digits_y + digit_h - 10, 10),
        .time_x = m.edge(text_x + 11),
        .row_c_y = m.edge(row_c_y),
        .time_w = right - m.edge(text_x + 11),
        .time_h = bar.y - m.edge(row_c_y),
        .bar = bar,
        // One design unit between segments, but at least one pixel once the
        // segments are wide enough to spare it; tiny tiles let them touch.
        .seg_gap = if (bar.w >= 3 * seg_n) m.stroke(seg_gap) else 0,
    };
}

fn atLeast1(b: scale.Box) scale.Box {
    return .{ .x = b.x, .y = b.y, .w = @max(1, b.w), .h = @max(1, b.h) };
}

/// Left and right pixel edge of bar segment `i` (0..seg_n - 1): the bar cut
/// into ten equal pitches, the last segment ends at the bar's end.
fn segSpan(lay: Layout, i: i32) [2]i32 {
    const pitch_total = lay.bar.w + lay.seg_gap;
    const start = lay.bar.x + @divFloor(i * pitch_total + seg_n / 2, seg_n);
    const next = lay.bar.x + @divFloor((i + 1) * pitch_total + seg_n / 2, seg_n);
    const end = if (i == seg_n - 1) lay.bar.x + lay.bar.w else next - lay.seg_gap;
    return .{ start, @max(start + 1, end) };
}

// ----------------------------------------------------------------------------
// Pixel helpers
// ----------------------------------------------------------------------------

fn mix(a: u32, b: u32, t: f32) u32 {
    var out: u32 = 0xff000000;
    inline for (.{ 0, 8, 16 }) |shift| {
        const ca: f32 = @floatFromInt((a >> shift) & 0xff);
        const cb: f32 = @floatFromInt((b >> shift) & 0xff);
        const v = std.math.clamp(@round(ca + (cb - ca) * t), 0, 255);
        const iv: u32 = @intFromFloat(v);
        out |= iv << shift;
    }
    return out;
}

fn put(cv: Canvas, x: i32, y: i32, color: u32) void {
    if (cv.at(x, y)) |i| cv.px[i] = color;
}

fn blend(cv: Canvas, x: i32, y: i32, color: u32, coverage: f32) void {
    if (cv.at(x, y)) |i| cv.px[i] = mix(cv.px[i], color, coverage);
}

fn fillRect(cv: Canvas, x: i32, y: i32, w: i32, h: i32, color: u32) void {
    var yy = y;
    while (yy < y + h) : (yy += 1) {
        var xx = x;
        while (xx < x + w) : (xx += 1) put(cv, xx, yy, color);
    }
}

fn fillBox(cv: Canvas, b: scale.Box, color: u32) void {
    fillRect(cv, b.x, b.y, b.w, b.h, color);
}

/// 1 px frame: `tl` on the top and left edge, `br` on the bottom and right.
fn bevel(cv: Canvas, x: i32, y: i32, w: i32, h: i32, tl: u32, br: u32) void {
    var i: i32 = 0;
    while (i < w) : (i += 1) {
        put(cv, x + i, y, tl);
        put(cv, x + i, y + h - 1, br);
    }
    i = 0;
    while (i < h) : (i += 1) {
        put(cv, x, y + i, tl);
        put(cv, x + w - 1, y + i, br);
    }
}

/// A frame `t` px thick: `t` one-pixel frames, each one inside the last.
fn bevelThick(cv: Canvas, x: i32, y: i32, w: i32, h: i32, t: i32, tl: u32, br: u32) void {
    var k: i32 = 0;
    while (k < t) : (k += 1) bevel(cv, x + k, y + k, w - 2 * k, h - 2 * k, tl, br);
}

// ----------------------------------------------------------------------------
// Antialiased polygons (the seven-segment display)
// ----------------------------------------------------------------------------

const Pt = [2]f32;
const supersample = 4;

fn inside(pts: []const Pt, x: f32, y: f32) bool {
    var in = false;
    var j = pts.len - 1;
    for (pts, 0..) |a, i| {
        const b = pts[j];
        if ((a[1] > y) != (b[1] > y) and x < (b[0] - a[0]) * (y - a[1]) / (b[1] - a[1]) + a[0]) in = !in;
        j = i;
    }
    return in;
}

fn fillPoly(cv: Canvas, pts: []const Pt, color: u32) void {
    if (pts.len < 3) return;
    var min_x = pts[0][0];
    var max_x = pts[0][0];
    var min_y = pts[0][1];
    var max_y = pts[0][1];
    for (pts) |p| {
        min_x = @min(min_x, p[0]);
        max_x = @max(max_x, p[0]);
        min_y = @min(min_y, p[1]);
        max_y = @max(max_y, p[1]);
    }
    const last = cv.m.side - 1;
    const x0: i32 = @max(0, @as(i32, @intFromFloat(@floor(min_x))));
    const x1: i32 = @min(last, @as(i32, @intFromFloat(@ceil(max_x))));
    const y0: i32 = @max(0, @as(i32, @intFromFloat(@floor(min_y))));
    const y1: i32 = @min(last, @as(i32, @intFromFloat(@ceil(max_y))));

    var y = y0;
    while (y <= y1) : (y += 1) {
        var x = x0;
        while (x <= x1) : (x += 1) {
            var hits: u32 = 0;
            var sy: u32 = 0;
            while (sy < supersample) : (sy += 1) {
                var sx: u32 = 0;
                while (sx < supersample) : (sx += 1) {
                    const fx = @as(f32, @floatFromInt(x)) + (@as(f32, @floatFromInt(sx)) + 0.5) / supersample;
                    const fy = @as(f32, @floatFromInt(y)) + (@as(f32, @floatFromInt(sy)) + 0.5) / supersample;
                    if (inside(pts, fx, fy)) hits += 1;
                }
            }
            if (hits > 0) {
                blend(cv, x, y, color, @as(f32, @floatFromInt(hits)) / (supersample * supersample));
            }
        }
    }
}

// ----------------------------------------------------------------------------
// Seven segments
// ----------------------------------------------------------------------------

const seg_a: u8 = 1 << 0; // top
const seg_b: u8 = 1 << 1; // top right
const seg_c: u8 = 1 << 2; // bottom right
const seg_d: u8 = 1 << 3; // bottom
const seg_e: u8 = 1 << 4; // bottom left
const seg_f: u8 = 1 << 5; // top left
const seg_g: u8 = 1 << 6; // middle

const digit_segments = [10]u8{
    seg_a | seg_b | seg_c | seg_d | seg_e | seg_f, // 0
    seg_b | seg_c, // 1
    seg_a | seg_b | seg_d | seg_e | seg_g, // 2
    seg_a | seg_b | seg_c | seg_d | seg_g, // 3
    seg_b | seg_c | seg_f | seg_g, // 4
    seg_a | seg_c | seg_d | seg_f | seg_g, // 5
    seg_a | seg_c | seg_d | seg_e | seg_f | seg_g, // 6
    seg_a | seg_b | seg_c, // 7
    0x7f, // 8
    seg_a | seg_b | seg_c | seg_d | seg_f | seg_g, // 9
};

/// Half the stroke width, and the gap that keeps neighbouring segments apart
/// (design units: they grow with the tile, the polygons are antialiased).
const half_d: f32 = 1.2;
const gap_d: f32 = 0.45;

fn hSeg(cv: Canvas, x0: f32, x1: f32, yc: f32, half: f32, color: u32) void {
    fillPoly(cv, &.{
        .{ x0, yc },
        .{ x0 + half, yc - half },
        .{ x1 - half, yc - half },
        .{ x1, yc },
        .{ x1 - half, yc + half },
        .{ x0 + half, yc + half },
    }, color);
}

fn vSeg(cv: Canvas, xc: f32, y0: f32, y1: f32, half: f32, color: u32) void {
    fillPoly(cv, &.{
        .{ xc, y0 },
        .{ xc + half, y0 + half },
        .{ xc + half, y1 - half },
        .{ xc, y1 },
        .{ xc - half, y1 - half },
        .{ xc - half, y0 + half },
    }, color);
}

/// One digit cell whose top-left pixel is (x, y), digit_w x digit_h design
/// units big, lit in `lit`. Unlit segments are drawn faintly ("ghost" segments), like on
/// a real LCD. `value` null: all ghost.
fn drawDigit(cv: Canvas, x: i32, y: i32, value: ?u8, lit: u32) void {
    const lit_mask: u8 = if (value) |v| digit_segments[v] else 0;
    const half = cv.m.f(half_d);
    const gap = cv.m.f(gap_d);
    const dw = cv.m.f(digit_w);
    const dh = cv.m.f(digit_h);
    const fx: f32 = @floatFromInt(x);
    const fy: f32 = @floatFromInt(y);
    const xl = fx + half;
    const xr = fx + dw - half;
    const yt = fy + half;
    const ym = fy + dh / 2.0;
    const yb = fy + dh - half;

    const all = [_]u8{ seg_a, seg_b, seg_c, seg_d, seg_e, seg_f, seg_g };
    for (all) |seg| {
        const color = if (lit_mask & seg != 0) lit else col_ghost;
        switch (seg) {
            seg_a => hSeg(cv, xl + gap, xr - gap, yt, half, color),
            seg_g => hSeg(cv, xl + gap, xr - gap, ym, half, color),
            seg_d => hSeg(cv, xl + gap, xr - gap, yb, half, color),
            seg_f => vSeg(cv, xl, yt + gap, ym - gap, half, color),
            seg_b => vSeg(cv, xr, yt + gap, ym - gap, half, color),
            seg_e => vSeg(cv, xl, ym + gap, yb - gap, half, color),
            seg_c => vSeg(cv, xr, ym + gap, yb - gap, half, color),
            else => unreachable,
        }
    }
}

// ----------------------------------------------------------------------------
// A 3x5 pixel font (upper case, digits and a little punctuation)
// ----------------------------------------------------------------------------

fn g(a: u3, b: u3, c: u3, d: u3, e: u3) [5]u3 {
    return .{ a, b, c, d, e };
}

fn glyph(ch: u8) [5]u3 {
    return switch (std.ascii.toUpper(ch)) {
        'A' => g(0b010, 0b101, 0b111, 0b101, 0b101),
        'B' => g(0b110, 0b101, 0b110, 0b101, 0b110),
        'C' => g(0b011, 0b100, 0b100, 0b100, 0b011),
        'D' => g(0b110, 0b101, 0b101, 0b101, 0b110),
        'E' => g(0b111, 0b100, 0b110, 0b100, 0b111),
        'F' => g(0b111, 0b100, 0b110, 0b100, 0b100),
        'G' => g(0b011, 0b100, 0b101, 0b101, 0b011),
        'H' => g(0b101, 0b101, 0b111, 0b101, 0b101),
        'I' => g(0b111, 0b010, 0b010, 0b010, 0b111),
        'J' => g(0b001, 0b001, 0b001, 0b101, 0b010),
        'K' => g(0b101, 0b101, 0b110, 0b101, 0b101),
        'L' => g(0b100, 0b100, 0b100, 0b100, 0b111),
        'M' => g(0b101, 0b111, 0b111, 0b101, 0b101),
        'N' => g(0b110, 0b101, 0b101, 0b101, 0b101),
        'O' => g(0b010, 0b101, 0b101, 0b101, 0b010),
        'P' => g(0b110, 0b101, 0b110, 0b100, 0b100),
        'Q' => g(0b010, 0b101, 0b101, 0b110, 0b011),
        'R' => g(0b110, 0b101, 0b110, 0b101, 0b101),
        'S' => g(0b011, 0b100, 0b010, 0b001, 0b110),
        'T' => g(0b111, 0b010, 0b010, 0b010, 0b010),
        'U' => g(0b101, 0b101, 0b101, 0b101, 0b111),
        'V' => g(0b101, 0b101, 0b101, 0b101, 0b010),
        'W' => g(0b101, 0b101, 0b111, 0b111, 0b101),
        'X' => g(0b101, 0b101, 0b010, 0b101, 0b101),
        'Y' => g(0b101, 0b101, 0b010, 0b010, 0b010),
        'Z' => g(0b111, 0b001, 0b010, 0b100, 0b111),
        '0' => g(0b111, 0b101, 0b101, 0b101, 0b111),
        '1' => g(0b010, 0b110, 0b010, 0b010, 0b111),
        '2' => g(0b110, 0b001, 0b010, 0b100, 0b111),
        '3' => g(0b110, 0b001, 0b010, 0b001, 0b110),
        '4' => g(0b101, 0b101, 0b111, 0b001, 0b001),
        '5' => g(0b111, 0b100, 0b110, 0b001, 0b110),
        '6' => g(0b011, 0b100, 0b110, 0b101, 0b010),
        '7' => g(0b111, 0b001, 0b010, 0b010, 0b010),
        '8' => g(0b010, 0b101, 0b010, 0b101, 0b010),
        '9' => g(0b010, 0b101, 0b011, 0b001, 0b110),
        '-' => g(0b000, 0b000, 0b111, 0b000, 0b000),
        '.' => g(0b000, 0b000, 0b000, 0b000, 0b010),
        ':' => g(0b000, 0b010, 0b000, 0b010, 0b000),
        '/' => g(0b001, 0b001, 0b010, 0b100, 0b100),
        '_' => g(0b000, 0b000, 0b000, 0b000, 0b111),
        '%' => g(0b101, 0b001, 0b010, 0b100, 0b101),
        else => g(0, 0, 0, 0, 0), // space and anything else: blank
    };
}

/// Width in pixels of `s` at the magnification `mag` (no trailing gap).
pub fn textWidth(s: []const u8, mag: i32) i32 {
    return cellsWidth(s.len, mag);
}

/// The same for `cells` glyph cells (4 columns each, the last without gap).
fn cellsWidth(cells: usize, mag: i32) i32 {
    if (cells == 0) return 0;
    return @as(i32, @intCast(cells)) * 4 * mag - mag;
}

fn drawText(cv: Canvas, x: i32, y: i32, mag: i32, s: []const u8, color: u32) void {
    var cx = x;
    for (s) |ch| {
        const rows = glyph(ch);
        for (rows, 0..) |bits, row| {
            var col: u2 = 0;
            while (col < 3) : (col += 1) {
                // Bit 2 is the left column.
                if (bits & (@as(u3, 1) << (2 - col)) != 0) {
                    fillRect(cv, cx + @as(i32, col) * mag, y + @as(i32, @intCast(row)) * mag, mag, mag, color);
                }
            }
        }
        cx += 4 * mag;
    }
}

/// The whole-number magnification of the pixel font for `base` design
/// pixels per dot: the proportional size rounded to the nearest whole
/// number, then reduced until `cells` glyphs fit `avail_w` px wide and the
/// 5 rows fit `avail_h` px (never below 1).
pub fn fitMag(m: scale.Metrics, base: i32, cells: usize, avail_w: i32, avail_h: i32) i32 {
    var mag = m.stroke(base);
    while (mag > 1 and (cellsWidth(cells, mag) > avail_w or 5 * mag > avail_h)) mag -= 1;
    return mag;
}

/// Draw `s` at the size that fits `avail_w` x `avail_h`, left-aligned at
/// `x_or_right`, or ending there when `right_aligned`. A text that does not
/// fit even at 1x (a tiny tile, or an absurd value) is left out rather than
/// run over its neighbours.
fn fitted(cv: Canvas, s: []const u8, x_or_right: i32, right_aligned: bool, y: i32, avail_w: i32, avail_h: i32, color: u32) void {
    const mag = fitMag(cv.m, 2, s.len, avail_w, avail_h);
    const w = textWidth(s, mag);
    if (s.len == 0 or w > avail_w or 5 * mag > avail_h) return;
    drawText(cv, if (right_aligned) x_or_right - w else x_or_right, y, mag, s, color);
}

// ----------------------------------------------------------------------------
// Icons: '#' is a lit cell of the 64x64 grid. All rows of an icon have the
// same width. A cell becomes a snapped box (at least 1 px), so an icon stays
// crisp pixel art at every tile size.
// ----------------------------------------------------------------------------

const Icon = []const []const u8;

const icon_bolt: Icon = &.{ "....###", "...###.", "..###..", ".######", "######.", "..###..", ".###...", "##....." };
const icon_arrow: Icon = &.{ "..###..", "..###..", "..###..", "..###..", "#######", ".#####.", "..###..", "...#..." };
const icon_check: Icon = &.{ "........#", ".......##", "#.....##.", "##...##..", ".##.##...", "..###....", "...#....." };
const icon_pause: Icon = &.{ "###.###", "###.###", "###.###", "###.###", "###.###", "###.###", "###.###", "###.###" };
const icon_unknown: Icon = &.{ ".###.", "#...#", "....#", "...#.", "..#..", "..#..", ".....", "..#.." };
const icon_cross: Icon = &.{ "#.....#", ".#...#.", "..#.#..", "...#...", "..#.#..", ".#...#.", "#.....#" };
const icon_plug: Icon = &.{ ".#...#.", ".#...#.", "#######", "#######", "#######", ".#####.", "..###..", "...#...", "...#...", "...#..." };
const icon_clock: Icon = &.{ "..#####..", ".#.....#.", "#...#...#", "#...#...#", "#...###.#", "#.......#", ".#.....#.", "..#####.." };

fn drawIcon(cv: Canvas, x: i32, y: i32, icon: Icon, color: u32) void {
    for (icon, 0..) |row, ry| {
        for (row, 0..) |ch, rx| {
            if (ch == '#') fillBox(cv, atLeast1(cv.m.box(x + @as(i32, @intCast(rx)), y + @as(i32, @intCast(ry)), 1, 1)), color);
        }
    }
}


/// Digits and bar: green normally, amber <= 20 %, red <= 10 % (not while
/// charging or full).
fn levelColor(info: Info) u32 {
    if (!info.present) return col_lit;
    if (info.status == .charging or info.status == .full) return col_lit;
    if (info.percent <= 10) return col_red;
    if (info.percent <= 20) return col_amber;
    return col_lit;
}

/// "9.5W" below 10 W, "12W" from there on (never more than "999W": the
/// face has no room for more).
fn fmtPower(buf: []u8, mw: u32) []const u8 {
    const tenths = (mw + 50) / 100;
    if (tenths < 100) return std.fmt.bufPrint(buf, "{d}.{d}W", .{ tenths / 10, tenths % 10 }) catch "";
    return std.fmt.bufPrint(buf, "{d}W", .{@min((mw + 500) / 1000, 999)}) catch "";
}

/// Tile and empty LCD: the same for every frame of one size, so it is
/// painted once per size (one float blend per pixel) and then only copied.
var bg: Pixels = undefined;
var bg_side: i32 = 0;

fn background(cv: Canvas) []const u32 {
    const m = cv.m;
    const n = m.pixels();
    if (bg_side != m.side) {
        const side: usize = @intCast(m.side);
        const own: Canvas = .{ .px = bg[0..n], .m = m };
        // Diagonal gradient and the two-step bevel of dock.zig's tiles.
        for (0..side) |yy| {
            for (0..side) |xx| {
                const t = @as(f32, @floatFromInt(xx + yy)) / (2.0 * @as(f32, @floatFromInt(side - 1)));
                bg[yy * side + xx] = mix(col_tile_from, col_tile_to, t);
            }
        }
        bevelThick(own, 0, 0, m.side, m.side, 2 * m.stroke(1), col_light, col_dark);
        // The recessed LCD.
        const lay = layout(m);
        const gl = lay.glass;
        bevelThick(own, gl.x - lay.frame, gl.y - lay.frame, gl.w + 2 * lay.frame, gl.h + 2 * lay.frame, lay.frame, col_dark, col_light);
        fillBox(own, gl, col_lcd);
        bg_side = m.side;
    }
    return bg[0..n];
}

pub fn render(cv: Canvas, info: Info) void {
    const m = cv.m;
    const lay = layout(m);
    const pct: u8 = if (info.present) @min(info.percent, 100) else 0;
    const lit = levelColor(info);

    @memcpy(cv.px, background(cv)); // tile + LCD, built once per size

    // Row A: status symbol, plug when on AC, power.
    if (!info.present) {
        drawIcon(cv, text_x, row_a_y, icon_cross, col_red);
    } else switch (info.status) {
        .charging => drawIcon(cv, text_x, row_a_y, icon_bolt, col_lit),
        .discharging => drawIcon(cv, text_x, row_a_y, icon_arrow, lit),
        .full => drawIcon(cv, text_x, row_a_y, icon_check, col_lit),
        .idle => drawIcon(cv, text_x, row_a_y, icon_pause, col_text),
        .unknown => drawIcon(cv, text_x, row_a_y, icon_unknown, col_text),
    }
    if (info.present and info.ac) drawIcon(cv, plug_x, row_a_y, icon_plug, col_lit);
    if (info.power_mw) |mw| {
        var pb: [12]u8 = undefined;
        const s = fmtPower(&pb, mw);
        fitted(cv, s, lay.power_right, true, lay.row_a_y, lay.power_w, lay.power_h, col_text);
    }

    // Percent: three seven-segment digits (leading ones ghosted) and a %.
    const hundreds: ?u8 = if (info.present and pct == 100) 1 else null;
    const tens: ?u8 = if (info.present and pct >= 10) (pct / 10) % 10 else null;
    const ones: ?u8 = if (info.present) pct % 10 else null;
    drawDigit(cv, lay.digit_x[0], lay.digits_y, hundreds, lit);
    drawDigit(cv, lay.digit_x[1], lay.digits_y, tens, lit);
    drawDigit(cv, lay.digit_x[2], lay.digits_y, ones, lit);
    // The % sits on the digits' baseline, to the right of the last digit.
    const pm = fitMag(m, 2, 1, lay.pct_w, lay.pct_h);
    if (textWidth("%", pm) <= lay.pct_w and 5 * pm <= lay.pct_h) {
        drawText(cv, lay.pct_x, lay.pct_bottom - 5 * pm, pm, "%", col_text);
    }

    // Row C: clock symbol and the time to empty / full.
    if (info.minutes) |mins| {
        var tb: [12]u8 = undefined;
        const s = std.fmt.bufPrint(&tb, "{d}:{d:0>2}", .{ mins / 60, mins % 60 }) catch "";
        drawIcon(cv, text_x, row_c_y + 1, icon_clock, col_text);
        fitted(cv, s, lay.time_x, false, lay.row_c_y, lay.time_w, lay.time_h, col_text);
    }

    // Bar: 10 segments, a started segment counts (1 % shows one).
    const segs: i32 = if (info.present) @divTrunc(@as(i32, pct) + 9, 10) else 0;
    var i: i32 = 0;
    while (i < seg_n) : (i += 1) {
        const span = segSpan(lay, i);
        fillRect(cv, span[0], lay.bar.y, span[1] - span[0], lay.bar.h, if (i < segs) lit else col_ghost);
    }
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

const Px64 = [64 * 64]u32;

fn at(cv: Canvas, x: i32, y: i32) u32 {
    return cv.px[@intCast(y * cv.m.side + x)];
}

test "textWidth" {
    try std.testing.expectEqual(@as(i32, 0), textWidth("", 2));
    try std.testing.expectEqual(@as(i32, 3), textWidth("A", 1));
    try std.testing.expectEqual(@as(i32, 30), textWidth("1:23", 2));
}

test "mix interpolates and never leaves 0..255" {
    try std.testing.expectEqual(@as(u32, 0xff000000), mix(0xff000000, 0xffffffff, 0));
    try std.testing.expectEqual(@as(u32, 0xffffffff), mix(0xff000000, 0xffffffff, 1));
    try std.testing.expectEqual(@as(u32, 0xff808080), mix(0xff000000, 0xffffffff, 0.5));
    try std.testing.expectEqual(@as(u32, 0xffffffff), mix(0xff000000, 0xffffffff, 3));
    try std.testing.expectEqual(@as(u32, 0xff000000), mix(0xff000000, 0xffffffff, -3));
}

test "formatting" {
    var b: [12]u8 = undefined;
    try std.testing.expectEqualStrings("12W", fmtPower(&b, 12_480));
    try std.testing.expectEqualStrings("0.0W", fmtPower(&b, 0));
    try std.testing.expectEqualStrings("9.5W", fmtPower(&b, 9_540));
    try std.testing.expectEqualStrings("130W", fmtPower(&b, 130_000));
    try std.testing.expectEqualStrings("999W", fmtPower(&b, 4_000_000_000));
}

test "render: Dock frame, opaque, recessed LCD" {
    var px: Px64 = undefined;
    const cv = Canvas.init(&px, 64);
    render(cv, .{});
    for (px) |p| try std.testing.expectEqual(@as(u32, 0xff), p >> 24);
    try std.testing.expectEqual(col_light, at(cv, 10, 0));
    try std.testing.expectEqual(col_light, at(cv, 0, 10));
    try std.testing.expectEqual(col_dark, at(cv, 10, 63));
    try std.testing.expectEqual(col_dark, at(cv, 63, 10));
    try std.testing.expectEqual(col_dark, at(cv, 5, 20));
    try std.testing.expectEqual(col_light, at(cv, 58, 20));
    try std.testing.expectEqual(col_lcd, at(cv, 7, 7));
}

test "render: 88 % lights tens and ones, ghosts the hundreds" {
    var px: Px64 = undefined;
    const cv = Canvas.init(&px, 64);
    render(cv, .{ .present = true, .status = .charging, .percent = 88 });
    try std.testing.expectEqual(col_ghost, at(cv, digits_x + 4, digits_y + 1));
    try std.testing.expectEqual(col_lit, at(cv, digits_x + 11 + 4, digits_y + 1));
    try std.testing.expectEqual(col_lit, at(cv, digits_x + 22 + 4, digits_y + 1));
}

test "render: low battery turns red, charging stays green" {
    var low_px: Px64 = undefined;
    var chg_px: Px64 = undefined;
    const low = Canvas.init(&low_px, 64);
    const chg = Canvas.init(&chg_px, 64);
    render(low, .{ .present = true, .status = .discharging, .percent = 5 });
    render(chg, .{ .present = true, .status = .charging, .percent = 5 });
    try std.testing.expectEqual(col_red, at(low, digits_x + 22 + 4, digits_y + 1));
    try std.testing.expectEqual(col_lit, at(chg, digits_x + 22 + 4, digits_y + 1));
}

test "render: the bar has one segment per started 10 %" {
    var px: Px64 = undefined;
    const cv = Canvas.init(&px, 64);
    render(cv, .{ .present = true, .status = .charging, .percent = 50 });
    try std.testing.expectEqual(col_lit, at(cv, bar_x + 4 * (seg_w + seg_gap) + 1, bar_y + 1));
    try std.testing.expectEqual(col_ghost, at(cv, bar_x + 5 * (seg_w + seg_gap) + 1, bar_y + 1));
    // The segments are exactly the old 4 px with 1 px between them.
    try std.testing.expectEqual(col_lcd, at(cv, bar_x + 4, bar_y + 1));
    try std.testing.expectEqual(col_lit, at(cv, bar_x + 3, bar_y + 1));
}

fn areaDiffers(a: Canvas, b: Canvas, x0: i32, y0: i32, w: i32, h: i32) bool {
    var y = y0;
    while (y < y0 + h) : (y += 1) {
        var x = x0;
        while (x < x0 + w) : (x += 1) {
            if (at(a, x, y) != at(b, x, y)) return true;
        }
    }
    return false;
}

test "render: each status has its own symbol, AC adds the plug" {
    var chg_px: Px64 = undefined;
    var dis_px: Px64 = undefined;
    var full_px: Px64 = undefined;
    var ac_px: Px64 = undefined;
    var bat_px: Px64 = undefined;
    const chg = Canvas.init(&chg_px, 64);
    const dis = Canvas.init(&dis_px, 64);
    const full = Canvas.init(&full_px, 64);
    const ac = Canvas.init(&ac_px, 64);
    const bat = Canvas.init(&bat_px, 64);
    render(chg, .{ .present = true, .status = .charging, .percent = 50 });
    render(dis, .{ .present = true, .status = .discharging, .percent = 50 });
    render(full, .{ .present = true, .status = .full, .percent = 50 });
    render(ac, .{ .present = true, .status = .discharging, .percent = 50, .ac = true });
    render(bat, .{ .present = true, .status = .discharging, .percent = 50 });
    try std.testing.expect(areaDiffers(chg, dis, text_x, row_a_y, 9, 10));
    try std.testing.expect(areaDiffers(dis, full, text_x, row_a_y, 9, 10));
    try std.testing.expect(areaDiffers(ac, bat, plug_x, row_a_y, 7, 10));
    // Without AC the plug's place is plain LCD glass.
    try std.testing.expectEqual(col_lcd, at(bat, plug_x + 3, row_a_y + 3));
}

test "render: power and time only when known" {
    var none_px: Px64 = undefined;
    var some_px: Px64 = undefined;
    const none = Canvas.init(&none_px, 64);
    const some = Canvas.init(&some_px, 64);
    render(none, .{ .present = true, .status = .discharging, .percent = 50 });
    render(some, .{ .present = true, .status = .discharging, .percent = 50, .power_mw = 12_000, .minutes = 83 });
    try std.testing.expect(areaDiffers(none, some, 26, row_a_y, 30, 10)); // power
    try std.testing.expect(areaDiffers(none, some, text_x, row_c_y, 48, 10)); // clock + time
}

test "render: no battery, and nonsense values, do not crash" {
    var px: Px64 = undefined;
    const cv = Canvas.init(&px, 64);
    render(cv, .{});
    try std.testing.expectEqual(col_ghost, at(cv, bar_x + 1, bar_y + 1));
    render(cv, .{ .present = true, .percent = 255, .power_mw = 4_000_000_000, .minutes = 4_000_000_000, .voltage_mv = 4_000_000_000, .health = 255 });
    try std.testing.expectEqual(@as(u32, 0xff), px[0] >> 24);
}

test "glyphs: letters, digits and % all have some pixels, unknown is blank" {
    for ("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-.:/_%") |ch| {
        var any = false;
        for (glyph(ch)) |row| {
            if (row != 0) any = true;
        }
        try std.testing.expect(any);
    }
    for (glyph(' ')) |row| try std.testing.expectEqual(@as(u3, 0), row);
    try std.testing.expectEqual(glyph('A'), glyph('a'));
}

test "every tile size draws an opaque face without leaving the buffer" {
    var buf: Pixels = undefined;
    const full: Info = .{ .present = true, .ac = true, .status = .charging, .percent = 100, .power_mw = 130_000, .minutes = 599 };
    var side: i32 = scale.min_side;
    while (side <= scale.max_side) : (side += 9) {
        const cv = Canvas.init(&buf, side);
        render(cv, full);
        for (cv.px) |p| try std.testing.expectEqual(@as(u32, 0xff), p >> 24);
        render(cv, .{});
        for (cv.px) |p| try std.testing.expectEqual(@as(u32, 0xff), p >> 24);
    }
    const last = Canvas.init(&buf, scale.max_side);
    render(last, full);
    for (last.px) |p| try std.testing.expectEqual(@as(u32, 0xff), p >> 24);
}

test "layout: parts stay in the LCD, bar segments are ordered and never empty" {
    var side: i32 = scale.min_side;
    while (side <= scale.max_side) : (side += 1) {
        const m = scale.Metrics.init(side);
        const lay = layout(m);
        const gl = lay.glass;
        try std.testing.expect(gl.x - lay.frame >= 0 and gl.x + gl.w + lay.frame <= side);
        try std.testing.expect(lay.bar.x >= gl.x and lay.bar.x + lay.bar.w <= gl.x + gl.w);
        try std.testing.expect(lay.bar.y + lay.bar.h <= gl.y + gl.h);
        try std.testing.expect(lay.digit_x[0] < lay.digit_x[1] and lay.digit_x[1] < lay.digit_x[2]);
        var prev_end: i32 = lay.bar.x;
        var i: i32 = 0;
        while (i < seg_n) : (i += 1) {
            const s = segSpan(lay, i);
            try std.testing.expect(s[0] < s[1]);
            try std.testing.expect(s[0] >= prev_end);
            prev_end = s[1];
        }
        try std.testing.expectEqual(lay.bar.x + lay.bar.w, prev_end);
    }
}

test "render at 128 px: the picture is drawn at its own size, not stretched" {
    var buf: Pixels = undefined;
    const cv = Canvas.init(&buf, 128);
    render(cv, .{ .present = true, .status = .charging, .percent = 50 });
    const lay = layout(cv.m);

    // Two bevel steps of two pixels: four light rows on top.
    for (0..4) |i| try std.testing.expectEqual(col_light, at(cv, 40, @intCast(i)));
    try std.testing.expect(at(cv, 40, 4) != col_light);
    // The LCD frame is two pixels thick.
    try std.testing.expectEqual(col_dark, at(cv, 10, 40));
    try std.testing.expectEqual(col_dark, at(cv, 11, 40));
    // Segments are 8 px wide with 2 px between them: 2 x the 64 px picture.
    try std.testing.expectEqual(@as(i32, 2), lay.seg_gap);
    const y = lay.bar.y + 1;
    try std.testing.expectEqual(col_lit, at(cv, 14 + 10 * 4 + 1, y));
    try std.testing.expectEqual(col_lit, at(cv, 14 + 10 * 4 + 7, y));
    try std.testing.expectEqual(col_lcd, at(cv, 14 + 10 * 4 + 8, y));
    try std.testing.expectEqual(col_lcd, at(cv, 14 + 10 * 4 + 9, y));
    try std.testing.expectEqual(col_ghost, at(cv, 14 + 10 * 5 + 1, y));
}

test "render at 96 px: odd factors keep gaps and segments on whole pixels" {
    var buf: Pixels = undefined;
    const cv = Canvas.init(&buf, 96);
    render(cv, .{ .present = true, .status = .charging, .percent = 100 });
    const lay = layout(cv.m);
    var i: i32 = 0;
    while (i < seg_n) : (i += 1) {
        const s = segSpan(lay, i);
        // Every segment is lit through, and the pixel after it (the gap) is not.
        var x = s[0];
        while (x < s[1]) : (x += 1) try std.testing.expectEqual(col_lit, at(cv, x, lay.bar.y));
        if (i + 1 < seg_n) try std.testing.expectEqual(col_lcd, at(cv, s[1], lay.bar.y));
    }
}
