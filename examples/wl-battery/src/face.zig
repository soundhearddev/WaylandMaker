// SPDX-License-Identifier: 0BSD
//
// The battery face: one 64x64 ARGB tile, drawn by hand into a pixel array.
// No Wayland and no libc in here, so all of it is unit-testable.
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

/// Window Maker's classic dock tile.
pub const side = 64;
pub const tile: i32 = side;
pub const pixel_count = side * side;

pub const Pixels = [pixel_count]u32;

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

// Where things are (all in tile pixels).
const lcd_x = 6;
const lcd_y = 6;
const lcd_w = 52;
const lcd_h = 52;

const text_x = 8;
const text_right = 56;
const row_a_y = 8; // status icon, plug, power (icons up to 10 px, text scale 2)
const plug_x = 19;
const digits_y = 20;
const digit_w = 9;
const digit_h = 20;
const digits_x = 12; // hundreds, tens, ones: 9 px wide, 2 px gaps; then the % sign
const row_c_y = 42; // clock icon, time (scale 2)
const bar_x = 7;
const bar_y = 53;
const seg_n = 10;
const seg_w = 4;
const seg_gap = 1;
const bar_h = 4;

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
fn drawDigit(px: *Pixels, x: i32, y: i32, value: ?u8, lit: u32) void {
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
        const color = if (lit_mask & seg != 0) lit else col_ghost;
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

// ----------------------------------------------------------------------------
// Icons: '#' is a lit pixel. All rows of an icon have the same width.
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

fn drawIcon(px: *Pixels, x: i32, y: i32, icon: Icon, color: u32) void {
    for (icon, 0..) |row, ry| {
        for (row, 0..) |ch, rx| {
            if (ch == '#') put(px, x + @as(i32, @intCast(rx)), y + @as(i32, @intCast(ry)), color);
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

/// "9.5W" below 10 W, "12W" from there on.
fn fmtPower(buf: []u8, mw: u32) []const u8 {
    const tenths = (mw + 50) / 100;
    if (tenths < 100) return std.fmt.bufPrint(buf, "{d}.{d}W", .{ tenths / 10, tenths % 10 }) catch "";
    return std.fmt.bufPrint(buf, "{d}W", .{(mw + 500) / 1000}) catch "";
}

pub fn render(px: *Pixels, info: Info) void {
    const pct: u8 = if (info.present) @min(info.percent, 100) else 0;
    const lit = levelColor(info);

    // Tile: diagonal gradient and the two-step bevel of dock.zig's tiles.
    for (0..side) |yy| {
        for (0..side) |xx| {
            const t = @as(f32, @floatFromInt(xx + yy)) / (2.0 * (side - 1));
            px[yy * side + xx] = mix(col_tile_from, col_tile_to, t);
        }
    }
    bevel(px, 0, 0, tile, tile, col_light, col_dark);
    bevel(px, 1, 1, tile - 2, tile - 2, col_light, col_dark);

    // The recessed LCD.
    bevel(px, lcd_x - 1, lcd_y - 1, lcd_w + 2, lcd_h + 2, col_dark, col_light);
    fillRect(px, lcd_x, lcd_y, lcd_w, lcd_h, col_lcd);

    // Row A: status symbol, plug when on AC, power.
    if (!info.present) {
        drawIcon(px, text_x, row_a_y, icon_cross, col_red);
    } else switch (info.status) {
        .charging => drawIcon(px, text_x, row_a_y, icon_bolt, col_lit),
        .discharging => drawIcon(px, text_x, row_a_y, icon_arrow, lit),
        .full => drawIcon(px, text_x, row_a_y, icon_check, col_lit),
        .idle => drawIcon(px, text_x, row_a_y, icon_pause, col_text),
        .unknown => drawIcon(px, text_x, row_a_y, icon_unknown, col_text),
    }
    if (info.present and info.ac) drawIcon(px, plug_x, row_a_y, icon_plug, col_lit);
    if (info.power_mw) |mw| {
        var pb: [12]u8 = undefined;
        const s = fmtPower(&pb, mw);
        drawText(px, text_right - textWidth(s, 2), row_a_y, 2, s, col_text);
    }

    // Percent: three seven-segment digits (leading ones ghosted) and a %.
    const hundreds: ?u8 = if (info.present and pct == 100) 1 else null;
    const tens: ?u8 = if (info.present and pct >= 10) (pct / 10) % 10 else null;
    const ones: ?u8 = if (info.present) pct % 10 else null;
    drawDigit(px, digits_x, digits_y, hundreds, lit);
    drawDigit(px, digits_x + 11, digits_y, tens, lit);
    drawDigit(px, digits_x + 22, digits_y, ones, lit);
    drawText(px, digits_x + 22 + digit_w + 3, digits_y + digit_h - 10, 2, "%", col_text);

    // Row C: clock symbol and the time to empty / full.
    if (info.minutes) |m| {
        var tb: [12]u8 = undefined;
        const s = std.fmt.bufPrint(&tb, "{d}:{d:0>2}", .{ m / 60, m % 60 }) catch "";
        drawIcon(px, text_x, row_c_y + 1, icon_clock, col_text);
        drawText(px, text_x + 11, row_c_y, 2, s, col_text);
    }

    // Bar: 10 segments, a started segment counts (1 % shows one).
    const segs: i32 = if (info.present) @divTrunc(@as(i32, pct) + 9, 10) else 0;
    var i: i32 = 0;
    while (i < seg_n) : (i += 1) {
        fillRect(px, bar_x + i * (seg_w + seg_gap), bar_y, seg_w, bar_h, if (i < segs) lit else col_ghost);
    }
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

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

fn at(px: *const Pixels, x: i32, y: i32) u32 {
    return px[@intCast(y * tile + x)];
}

test "formatting" {
    var b: [12]u8 = undefined;
    try std.testing.expectEqualStrings("12W", fmtPower(&b, 12_480));
    try std.testing.expectEqualStrings("0.0W", fmtPower(&b, 0));
    try std.testing.expectEqualStrings("9.5W", fmtPower(&b, 9_540));
    try std.testing.expectEqualStrings("130W", fmtPower(&b, 130_000));
}

test "render: Dock frame, opaque, recessed LCD" {
    var px: Pixels = undefined;
    render(&px, .{});
    for (px) |p| try std.testing.expectEqual(@as(u32, 0xff), p >> 24);
    try std.testing.expectEqual(col_light, at(&px, 10, 0));
    try std.testing.expectEqual(col_light, at(&px, 0, 10));
    try std.testing.expectEqual(col_dark, at(&px, 10, 63));
    try std.testing.expectEqual(col_dark, at(&px, 63, 10));
    try std.testing.expectEqual(col_dark, at(&px, 5, 20));
    try std.testing.expectEqual(col_light, at(&px, 58, 20));
    try std.testing.expectEqual(col_lcd, at(&px, 7, 7));
}

test "render: 88 % lights tens and ones, ghosts the hundreds" {
    var px: Pixels = undefined;
    render(&px, .{ .present = true, .status = .charging, .percent = 88 });
    try std.testing.expectEqual(col_ghost, at(&px, digits_x + 4, digits_y + 1));
    try std.testing.expectEqual(col_lit, at(&px, digits_x + 11 + 4, digits_y + 1));
    try std.testing.expectEqual(col_lit, at(&px, digits_x + 22 + 4, digits_y + 1));
}

test "render: low battery turns red, charging stays green" {
    var low: Pixels = undefined;
    var chg: Pixels = undefined;
    render(&low, .{ .present = true, .status = .discharging, .percent = 5 });
    render(&chg, .{ .present = true, .status = .charging, .percent = 5 });
    try std.testing.expectEqual(col_red, at(&low, digits_x + 22 + 4, digits_y + 1));
    try std.testing.expectEqual(col_lit, at(&chg, digits_x + 22 + 4, digits_y + 1));
}

test "render: the bar has one segment per started 10 %" {
    var px: Pixels = undefined;
    render(&px, .{ .present = true, .status = .charging, .percent = 50 });
    try std.testing.expectEqual(col_lit, at(&px, bar_x + 4 * (seg_w + seg_gap) + 1, bar_y + 1));
    try std.testing.expectEqual(col_ghost, at(&px, bar_x + 5 * (seg_w + seg_gap) + 1, bar_y + 1));
}

fn areaDiffers(a: *const Pixels, b: *const Pixels, x0: i32, y0: i32, w: i32, h: i32) bool {
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
    var chg: Pixels = undefined;
    var dis: Pixels = undefined;
    var full: Pixels = undefined;
    var ac: Pixels = undefined;
    var bat: Pixels = undefined;
    render(&chg, .{ .present = true, .status = .charging, .percent = 50 });
    render(&dis, .{ .present = true, .status = .discharging, .percent = 50 });
    render(&full, .{ .present = true, .status = .full, .percent = 50 });
    render(&ac, .{ .present = true, .status = .discharging, .percent = 50, .ac = true });
    render(&bat, .{ .present = true, .status = .discharging, .percent = 50 });
    try std.testing.expect(areaDiffers(&chg, &dis, text_x, row_a_y, 9, 10));
    try std.testing.expect(areaDiffers(&dis, &full, text_x, row_a_y, 9, 10));
    try std.testing.expect(areaDiffers(&ac, &bat, plug_x, row_a_y, 7, 10));
    // Without AC the plug's place is plain LCD glass.
    try std.testing.expectEqual(col_lcd, at(&bat, plug_x + 3, row_a_y + 3));
}

test "render: power and time only when known" {
    var none: Pixels = undefined;
    var some: Pixels = undefined;
    render(&none, .{ .present = true, .status = .discharging, .percent = 50 });
    render(&some, .{ .present = true, .status = .discharging, .percent = 50, .power_mw = 12_000, .minutes = 83 });
    try std.testing.expect(areaDiffers(&none, &some, 26, row_a_y, 30, 10)); // power
    try std.testing.expect(areaDiffers(&none, &some, text_x, row_c_y, 48, 10)); // clock + time
}

test "render: no battery, and nonsense values, do not crash" {
    var px: Pixels = undefined;
    render(&px, .{});
    try std.testing.expectEqual(col_ghost, at(&px, bar_x + 1, bar_y + 1));
    render(&px, .{ .present = true, .percent = 255, .power_mw = 4_000_000_000, .minutes = 4_000_000_000, .voltage_mv = 4_000_000_000, .health = 255 });
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
