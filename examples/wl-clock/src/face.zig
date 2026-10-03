// SPDX-License-Identifier: 0BSD
//
// The clock's face: one 64x64 ARGB tile, drawn by hand into a pixel array.
// No Wayland and no libc in here, so all of it is unit-testable.
//
// The look is the one of wmaker-wl's own Dock tiles (src/dock.zig): a light
// bevelled tile with a diagonal gradient. Window Maker dockapps draw their
// whole 64x64 tile themselves, frame included, so that is what this does --
// then, docked, the clock simply replaces the tile that was drawn under it
// and nobody can tell the two apart. In the middle sits a recessed LCD with
// the weekday and day, HH:MM in seven segments, the month (or --label), AM/PM
// in 12-hour mode, and a bar that fills up second by second.
//
//     +------------------+
//     |  .------------.  |
//     |  |  FRI 02    |  |
//     |  |  18:42     |  |
//     |  |  OCT       |  |
//     |  |  ######    |  |
//     |  '------------'  |
//     +------------------+

const std = @import("std");

/// Window Maker's classic dock tile.
pub const side = 64;
pub const tile: i32 = side;
pub const pixel_count = side * side;

pub const Pixels = [pixel_count]u32;

/// Broken-down local time, the part the face needs.
pub const Clock = struct {
    hour: u8 = 0, // 0..23
    min: u8 = 0, // 0..59
    sec: u8 = 0, // 0..59
    mday: u8 = 1, // 1..31
    mon: u8 = 0, // 0..11
    wday: u8 = 0, // 0 = Sunday .. 6
};

pub const View = struct {
    hour12: bool = false,
    /// Seconds bar and blinking colon. Off: the face only changes once a
    /// minute, so the clock costs nothing between minutes.
    seconds: bool = true,
    /// Shown instead of the month name.
    label: ?[]const u8 = null,
};

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

// Where things are (all in tile pixels).
const lcd_x = 6;
const lcd_y = 6;
const lcd_w = 52;
const lcd_h = 52;

const date_y = 9;
const digits_y = 22;
const digit_w = 9;
const digit_h = 20;
const info_y = 46;
const bar_x = 9;
const bar_y = 53;
const bar_w = 46;
const bar_h = 3;

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

fn put(px: *Pixels, x: i32, y: i32, color: u32) void {
    if (x < 0 or y < 0 or x >= tile or y >= tile) return;
    px[@intCast(y * tile + x)] = color;
}

fn blend(px: *Pixels, x: i32, y: i32, color: u32, coverage: f32) void {
    if (x < 0 or y < 0 or x >= tile or y >= tile) return;
    const i: usize = @intCast(y * tile + x);
    px[i] = mix(px[i], color, coverage);
}

fn fillRect(px: *Pixels, x: i32, y: i32, w: i32, h: i32, color: u32) void {
    var yy = y;
    while (yy < y + h) : (yy += 1) {
        var xx = x;
        while (xx < x + w) : (xx += 1) put(px, xx, yy, color);
    }
}

/// 1 px frame: `tl` on the top and left edge, `br` on the bottom and right.
fn bevel(px: *Pixels, x: i32, y: i32, w: i32, h: i32, tl: u32, br: u32) void {
    var i: i32 = 0;
    while (i < w) : (i += 1) {
        put(px, x + i, y, tl);
        put(px, x + i, y + h - 1, br);
    }
    i = 0;
    while (i < h) : (i += 1) {
        put(px, x, y + i, tl);
        put(px, x + w - 1, y + i, br);
    }
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

fn fillPoly(px: *Pixels, pts: []const Pt, color: u32) void {
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
    const x0: i32 = @max(0, @as(i32, @intFromFloat(@floor(min_x))));
    const x1: i32 = @min(tile - 1, @as(i32, @intFromFloat(@ceil(max_x))));
    const y0: i32 = @max(0, @as(i32, @intFromFloat(@floor(min_y))));
    const y1: i32 = @min(tile - 1, @as(i32, @intFromFloat(@ceil(max_y))));

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
                blend(px, x, y, color, @as(f32, @floatFromInt(hits)) / (supersample * supersample));
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

/// Half the stroke width, and the gap that keeps neighbouring segments apart.
const half: f32 = 1.2;
const gap: f32 = 0.45;

fn hSeg(px: *Pixels, x0: f32, x1: f32, yc: f32, color: u32) void {
    fillPoly(px, &.{
        .{ x0, yc },
        .{ x0 + half, yc - half },
        .{ x1 - half, yc - half },
        .{ x1, yc },
        .{ x1 - half, yc + half },
        .{ x0 + half, yc + half },
    }, color);
}

fn vSeg(px: *Pixels, xc: f32, y0: f32, y1: f32, color: u32) void {
    fillPoly(px, &.{
        .{ xc, y0 },
        .{ xc + half, y0 + half },
        .{ xc + half, y1 - half },
        .{ xc, y1 },
        .{ xc - half, y1 - half },
        .{ xc - half, y0 + half },
    }, color);
}

/// One digit cell at (x, y), digit_w x digit_h. Unlit segments are drawn
/// faintly ("ghost" segments), like on a real LCD. `value` null: all ghost.
fn drawDigit(px: *Pixels, x: i32, y: i32, value: ?u8) void {
    const lit_mask: u8 = if (value) |v| digit_segments[v] else 0;
    const fx: f32 = @floatFromInt(x);
    const fy: f32 = @floatFromInt(y);
    const xl = fx + half;
    const xr = fx + digit_w - half;
    const yt = fy + half;
    const ym = fy + digit_h / 2.0;
    const yb = fy + digit_h - half;

    const all = [_]u8{ seg_a, seg_b, seg_c, seg_d, seg_e, seg_f, seg_g };
    for (all) |seg| {
        const color = if (lit_mask & seg != 0) col_lit else col_ghost;
        switch (seg) {
            seg_a => hSeg(px, xl + gap, xr - gap, yt, color),
            seg_g => hSeg(px, xl + gap, xr - gap, ym, color),
            seg_d => hSeg(px, xl + gap, xr - gap, yb, color),
            seg_f => vSeg(px, xl, yt + gap, ym - gap, color),
            seg_b => vSeg(px, xr, yt + gap, ym - gap, color),
            seg_e => vSeg(px, xl, ym + gap, yb - gap, color),
            seg_c => vSeg(px, xr, ym + gap, yb - gap, color),
            else => unreachable,
        }
    }
}

fn drawColon(px: *Pixels, x: i32, y: i32, lit: bool) void {
    const color = if (lit) col_lit else col_ghost;
    fillRect(px, x + 1, y + 5, 2, 2, color);
    fillRect(px, x + 1, y + 13, 2, 2, color);
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
        else => g(0, 0, 0, 0, 0), // space and anything else: blank
    };
}

/// Width in pixels of `s` at `scale` (no trailing gap).
pub fn textWidth(s: []const u8, scale: i32) i32 {
    if (s.len == 0) return 0;
    return @as(i32, @intCast(s.len)) * 4 * scale - scale;
}

fn drawText(px: *Pixels, x: i32, y: i32, scale: i32, s: []const u8, color: u32) void {
    var cx = x;
    for (s) |ch| {
        const rows = glyph(ch);
        for (rows, 0..) |bits, row| {
            var col: u2 = 0;
            while (col < 3) : (col += 1) {
                // Bit 2 is the left column.
                if (bits & (@as(u3, 1) << (2 - col)) != 0) {
                    fillRect(px, cx + @as(i32, col) * scale, y + @as(i32, @intCast(row)) * scale, scale, scale, color);
                }
            }
        }
        cx += 4 * scale;
    }
}

// ----------------------------------------------------------------------------
// The face
// ----------------------------------------------------------------------------

const weekdays = [7][]const u8{ "SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT" };
const months = [12][]const u8{ "JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC" };

/// Hour as shown: 0..23, or 1..12 in 12-hour mode.
pub fn displayHour(hour: u8, hour12: bool) u8 {
    if (!hour12) return hour;
    const h = hour % 12;
    return if (h == 0) 12 else h;
}

pub fn isPm(hour: u8) bool {
    return hour >= 12;
}

/// Longest label that is shown (it must not run into the AM/PM text).
pub const max_label = 8;

pub fn render(px: *Pixels, raw: Clock, view: View) void {
    // Whatever the caller computed, never index a table out of range.
    const clk: Clock = .{
        .hour = @min(raw.hour, 23),
        .min = @min(raw.min, 59),
        .sec = @min(raw.sec, 59),
        .mday = std.math.clamp(raw.mday, 1, 31),
        .mon = raw.mon % 12,
        .wday = raw.wday % 7,
    };

    // Tile: diagonal gradient and the two-step bevel of dock.zig's tiles.
    for (0..side) |yy| {
        for (0..side) |xx| {
            const t = @as(f32, @floatFromInt(xx + yy)) / (2.0 * (side - 1));
            px[yy * side + xx] = mix(col_tile_from, col_tile_to, t);
        }
    }
    bevel(px, 0, 0, tile, tile, col_light, col_dark);
    bevel(px, 1, 1, tile - 2, tile - 2, col_light, col_dark);

    // The recessed LCD: inverted bevel around it, dark glass inside.
    bevel(px, lcd_x - 1, lcd_y - 1, lcd_w + 2, lcd_h + 2, col_dark, col_light);
    fillRect(px, lcd_x, lcd_y, lcd_w, lcd_h, col_lcd);

    // Weekday and day of the month, large.
    var date_buf: [8]u8 = undefined;
    const date = std.fmt.bufPrint(&date_buf, "{s} {d:0>2}", .{ weekdays[clk.wday], clk.mday }) catch "";
    drawText(px, lcd_x + @divTrunc(lcd_w - textWidth(date, 2), 2), date_y, 2, date, col_text);

    // HH:MM. Layout: d d : d d, 9 px digits, 2 px gaps, a 4 px colon.
    const shown = displayHour(clk.hour, view.hour12);
    const x0: i32 = lcd_x + 2;
    const tens: ?u8 = if (view.hour12 and shown < 10) null else shown / 10;
    drawDigit(px, x0, digits_y, tens);
    drawDigit(px, x0 + 11, digits_y, shown % 10);
    drawColon(px, x0 + 22, digits_y, !view.seconds or clk.sec % 2 == 0);
    drawDigit(px, x0 + 28, digits_y, clk.min / 10);
    drawDigit(px, x0 + 39, digits_y, clk.min % 10);

    // Month (or label) on the left, AM/PM on the right.
    var label_buf: [max_label]u8 = undefined;
    var info: []const u8 = months[clk.mon];
    if (view.label) |l| {
        const n = @min(l.len, max_label);
        for (l[0..n], 0..) |ch, i| label_buf[i] = std.ascii.toUpper(ch);
        info = label_buf[0..n];
    }
    drawText(px, bar_x, info_y, 1, info, col_text);
    if (view.hour12) {
        const ampm: []const u8 = if (isPm(clk.hour)) "PM" else "AM";
        drawText(px, bar_x + bar_w - textWidth(ampm, 1), info_y, 1, ampm, col_text);
    }

    // Seconds: a bar that fills over the minute.
    if (view.seconds) {
        fillRect(px, bar_x, bar_y, bar_w, bar_h, col_ghost);
        const filled: i32 = @divTrunc(bar_w * (@as(i32, clk.sec) + 1) + 59, 60); // rounded up: never empty
        fillRect(px, bar_x, bar_y, filled, bar_h, col_lit);
    }
}

/// The part of the clock that changes what is drawn: with the seconds off,
/// a new second does not need a new frame.
pub fn frameKey(clk: Clock, view: View) Clock {
    var k = clk;
    if (!view.seconds) k.sec = 0;
    return k;
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

test "displayHour: 24h is untouched, 12h maps 0 and 12 to 12" {
    try std.testing.expectEqual(@as(u8, 0), displayHour(0, false));
    try std.testing.expectEqual(@as(u8, 23), displayHour(23, false));
    try std.testing.expectEqual(@as(u8, 12), displayHour(0, true));
    try std.testing.expectEqual(@as(u8, 12), displayHour(12, true));
    try std.testing.expectEqual(@as(u8, 1), displayHour(13, true));
    try std.testing.expectEqual(@as(u8, 11), displayHour(23, true));
    try std.testing.expect(!isPm(11));
    try std.testing.expect(isPm(12));
}

test "textWidth" {
    try std.testing.expectEqual(@as(i32, 0), textWidth("", 2));
    try std.testing.expectEqual(@as(i32, 3), textWidth("A", 1));
    try std.testing.expectEqual(@as(i32, 46), textWidth("FRI 02", 2));
}

test "mix interpolates and never leaves 0..255" {
    try std.testing.expectEqual(@as(u32, 0xff000000), mix(0xff000000, 0xffffffff, 0));
    try std.testing.expectEqual(@as(u32, 0xffffffff), mix(0xff000000, 0xffffffff, 1));
    try std.testing.expectEqual(@as(u32, 0xff808080), mix(0xff000000, 0xffffffff, 0.5));
    // Out-of-range factors are clamped, not wrapped.
    try std.testing.expectEqual(@as(u32, 0xffffffff), mix(0xff000000, 0xffffffff, 3));
    try std.testing.expectEqual(@as(u32, 0xff000000), mix(0xff000000, 0xffffffff, -3));
}

fn at(px: *const Pixels, x: i32, y: i32) u32 {
    return px[@intCast(y * tile + x)];
}

test "render: the tile has the Dock's frame, an opaque face, and the LCD" {
    var px: Pixels = undefined;
    render(&px, .{ .hour = 8, .min = 8, .sec = 30, .mday = 2, .mon = 9, .wday = 5 }, .{});

    // Every pixel is opaque.
    for (px) |p| try std.testing.expectEqual(@as(u32, 0xff), p >> 24);
    // Bevel like dock.zig: light top/left, dark bottom/right, twice.
    try std.testing.expectEqual(col_light, at(&px, 10, 0));
    try std.testing.expectEqual(col_light, at(&px, 0, 10));
    try std.testing.expectEqual(col_dark, at(&px, 10, 63));
    try std.testing.expectEqual(col_dark, at(&px, 63, 10));
    try std.testing.expectEqual(col_light, at(&px, 10, 1));
    try std.testing.expectEqual(col_dark, at(&px, 10, 62));
    // The gradient runs from light (top-left) to dark (bottom-right).
    try std.testing.expect((at(&px, 3, 3) & 0xff) > (at(&px, 60, 60) & 0xff));
    // The LCD is recessed: dark edge top/left, light bottom/right.
    try std.testing.expectEqual(col_dark, at(&px, 5, 20));
    try std.testing.expectEqual(col_light, at(&px, 58, 20));
    try std.testing.expectEqual(col_lcd, at(&px, 7, 7));
}

test "render: 08:08 lights the right segments" {
    var px: Pixels = undefined;
    render(&px, .{ .hour = 8, .min = 8, .sec = 30 }, .{});
    // Digit 1 is a 0 (no middle bar), digit 2 an 8 (all segments).
    // Middle bar: y = digits_y + 10 = 32, x = digit cell + 4.
    try std.testing.expectEqual(col_ghost, at(&px, 8 + 4, 31));
    try std.testing.expectEqual(col_lit, at(&px, 8 + 11 + 4, 31));
    // The top bar of the 0 is lit.
    try std.testing.expectEqual(col_lit, at(&px, 8 + 4, digits_y + 1));
}

test "render: 12-hour mode blanks the leading zero and shows AM/PM" {
    var am: Pixels = undefined;
    var h24: Pixels = undefined;
    render(&am, .{ .hour = 9, .min = 5, .sec = 0 }, .{ .hour12 = true });
    render(&h24, .{ .hour = 9, .min = 5, .sec = 0 }, .{});
    // 09 in 24h shows a 0 (top bar lit); in 12h that cell is all ghost.
    try std.testing.expectEqual(col_lit, at(&h24, 8 + 4, digits_y + 1));
    try std.testing.expectEqual(col_ghost, at(&am, 8 + 4, digits_y + 1));
    // 24h has no AM/PM text; 12h does, so the two renders differ there.
    var differs = false;
    var y: i32 = info_y;
    while (y < info_y + 5) : (y += 1) {
        var x: i32 = bar_x + bar_w - 8;
        while (x < bar_x + bar_w) : (x += 1) {
            if (at(&am, x, y) != at(&h24, x, y)) differs = true;
        }
    }
    try std.testing.expect(differs);
}

test "render: the colon blinks with the seconds, and stays on without them" {
    var even: Pixels = undefined;
    var odd: Pixels = undefined;
    var steady: Pixels = undefined;
    render(&even, .{ .hour = 1, .min = 2, .sec = 10 }, .{});
    render(&odd, .{ .hour = 1, .min = 2, .sec = 11 }, .{});
    render(&steady, .{ .hour = 1, .min = 2, .sec = 11 }, .{ .seconds = false });
    const cx = 8 + 22 + 1;
    const cy = digits_y + 5;
    try std.testing.expectEqual(col_lit, at(&even, cx, cy));
    try std.testing.expectEqual(col_ghost, at(&odd, cx, cy));
    try std.testing.expectEqual(col_lit, at(&steady, cx, cy));
}

test "render: the seconds bar fills over the minute and is absent when off" {
    var a: Pixels = undefined;
    var b: Pixels = undefined;
    var off: Pixels = undefined;
    render(&a, .{ .sec = 0 }, .{});
    render(&b, .{ .sec = 59 }, .{});
    render(&off, .{ .sec = 59 }, .{ .seconds = false });
    const y = bar_y + 1;
    // 0 s: about a sixtieth filled; 59 s: all of it.
    try std.testing.expectEqual(col_lit, at(&a, bar_x, y));
    try std.testing.expectEqual(col_ghost, at(&a, bar_x + bar_w - 1, y));
    try std.testing.expectEqual(col_lit, at(&b, bar_x + bar_w - 1, y));
    // Off: the bar's place is just LCD glass.
    try std.testing.expectEqual(col_lcd, at(&off, bar_x + 5, y));
}

test "render: a label replaces the month, and a long one is cut" {
    var month: Pixels = undefined;
    var label: Pixels = undefined;
    var long: Pixels = undefined;
    var cut: Pixels = undefined;
    const clk: Clock = .{ .mon = 9 };
    render(&month, clk, .{});
    render(&label, clk, .{ .label = "tokyo" });
    render(&long, clk, .{ .label = "abcdefghijklmnop" });
    render(&cut, clk, .{ .label = "abcdefgh" });
    try std.testing.expect(!std.mem.eql(u32, &month, &label));
    // Everything past max_label is ignored.
    try std.testing.expect(std.mem.eql(u32, &long, &cut));
}

test "render survives nonsense clock values" {
    var px: Pixels = undefined;
    render(&px, .{ .hour = 255, .min = 255, .sec = 255, .mday = 255, .mon = 255, .wday = 255 }, .{ .hour12 = true, .label = "\x00\xff" });
    // Nothing to assert beyond "did not crash or overflow"; still opaque.
    try std.testing.expectEqual(@as(u32, 0xff), px[0] >> 24);
    render(&px, .{ .hour = 255, .min = 255, .sec = 255, .mday = 0, .mon = 255, .wday = 255 }, .{});
    try std.testing.expectEqual(@as(u32, 0xff), px[0] >> 24);
}

test "frameKey ignores the second only when it is not shown" {
    const a: Clock = .{ .sec = 5 };
    const b: Clock = .{ .sec = 6 };
    try std.testing.expect(!std.meta.eql(frameKey(a, .{}), frameKey(b, .{})));
    try std.testing.expect(std.meta.eql(frameKey(a, .{ .seconds = false }), frameKey(b, .{ .seconds = false })));
}

test "glyphs: letters and digits all have some pixels, unknown is blank" {
    for ("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-.:/_") |ch| {
        var any = false;
        for (glyph(ch)) |row| {
            if (row != 0) any = true;
        }
        try std.testing.expect(any);
    }
    for (glyph(' ')) |row| try std.testing.expectEqual(@as(u3, 0), row);
    for (glyph(0xff)) |row| try std.testing.expectEqual(@as(u3, 0), row);
    // Lower case maps onto upper case.
    try std.testing.expectEqual(glyph('A'), glyph('a'));
}
