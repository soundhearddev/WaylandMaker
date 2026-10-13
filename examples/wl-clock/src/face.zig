// SPDX-License-Identifier: 0BSD
//
// The clock's face: one square ARGB tile, drawn by hand into a pixel array
// at whatever side the Dock tile has (16..256 px, wmaker-wl's `dock_size`).
// No Wayland and no libc in here, so all of it is unit-testable.
//
// The face is NOT drawn at 64x64 and stretched. It is designed on a 64x64
// grid ("design units", Window Maker's tile) and every position, every line
// width, every digit and every font scale is mapped to whole device pixels
// of the real tile by scale.Metrics: edges snap to pixels (so neighbouring
// shapes never leave a gap and nothing sits on a half pixel), strokes are at
// least one pixel, the pixel font is magnified by a whole number that is
// reduced until the text fits, and the antialiased segments are computed at
// the real resolution. At 64 px this is exactly the old picture.
//
// The look is the one of wmaker-wl's own Dock tiles (src/dock.zig): a light
// bevelled tile with a diagonal gradient. Window Maker dockapps draw their
// whole tile themselves, frame included, so that is what this does -- then,
// docked, the clock simply replaces the tile that was drawn under it and
// nobody can tell the two apart. In the middle sits a recessed LCD with the
// weekday and day, HH:MM in seven segments, the month (or --label), AM/PM in
// 12-hour mode, and a bar that fills up second by second.
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

// Where things are, in DESIGN units (64x64). `layout` maps them to pixels.
const lcd_x = 6;
const lcd_y = 6;
const lcd_w = 52;
const lcd_h = 52;

const date_y = 9;
const digits_y = 22;
const digit_w = 9;
const digit_h = 20;
const digits_x: i32 = lcd_x + 2;
const info_y = 46;
const bar_x = 9;
const bar_y = 53;
const bar_w = 46;
const bar_h = 3;

/// The same places in device pixels of one tile size.
pub const Layout = struct {
    /// The LCD's glass and the thickness of the bevel around it.
    glass: scale.Box,
    frame: i32,
    date_y: i32,
    digits_y: i32,
    /// Left edges of the four digit cells (H H M M).
    digit_x: [4]i32,
    /// The two dots of the colon.
    colon: [2]scale.Box,
    info_y: i32,
    bar: scale.Box,
};

pub fn layout(m: scale.Metrics) Layout {
    const cx = digits_x + 22 + 1;
    return .{
        .glass = m.box(lcd_x, lcd_y, lcd_w, lcd_h),
        .frame = m.stroke(1),
        .date_y = m.edge(date_y),
        .digits_y = m.edge(digits_y),
        .digit_x = .{ m.edge(digits_x), m.edge(digits_x + 11), m.edge(digits_x + 28), m.edge(digits_x + 39) },
        .colon = .{ atLeast1(m.box(cx, digits_y + 5, 2, 2)), atLeast1(m.box(cx, digits_y + 13, 2, 2)) },
        .info_y = m.edge(info_y),
        .bar = atLeast1(m.box(bar_x, bar_y, bar_w, bar_h)),
    };
}

fn atLeast1(b: scale.Box) scale.Box {
    return .{ .x = b.x, .y = b.y, .w = @max(1, b.w), .h = @max(1, b.h) };
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
/// units big. Unlit segments are drawn faintly ("ghost" segments), like on
/// a real LCD. `value` null: all ghost.
fn drawDigit(cv: Canvas, x: i32, y: i32, value: ?u8) void {
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
        const color = if (lit_mask & seg != 0) col_lit else col_ghost;
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

fn drawColon(cv: Canvas, lay: Layout, lit: bool) void {
    const color = if (lit) col_lit else col_ghost;
    fillBox(cv, lay.colon[0], color);
    fillBox(cv, lay.colon[1], color);
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

/// Magnification of the weekday + day line ("FRI 02", 6 glyphs).
pub fn dateMag(m: scale.Metrics, lay: Layout) i32 {
    return fitMag(m, 2, 6, lay.bar.w, lay.digits_y - lay.date_y);
}

/// Magnification of the month/label line; in 12-hour mode the line also
/// holds a gap and AM/PM (3 more glyph cells).
pub fn infoMag(m: scale.Metrics, lay: Layout, label_len: usize, hour12: bool) i32 {
    const cells = label_len + if (hour12) @as(usize, 3) else 0;
    return fitMag(m, 1, cells, lay.bar.w, lay.bar.y - lay.info_y);
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
        // The recessed LCD: inverted bevel around it, dark glass inside.
        const lay = layout(m);
        const gl = lay.glass;
        bevelThick(own, gl.x - lay.frame, gl.y - lay.frame, gl.w + 2 * lay.frame, gl.h + 2 * lay.frame, lay.frame, col_dark, col_light);
        fillBox(own, gl, col_lcd);
        bg_side = m.side;
    }
    return bg[0..n];
}

/// Whatever the caller computed, never index a table out of range.
fn sanitize(raw: Clock) Clock {
    return .{
        .hour = @min(raw.hour, 23),
        .min = @min(raw.min, 59),
        .sec = @min(raw.sec, 59),
        .mday = std.math.clamp(raw.mday, 1, 31),
        .mon = raw.mon % 12,
        .wday = raw.wday % 7,
    };
}

/// Everything that changes at most once a minute: tile, date, HH MM digits,
/// month / label, AM/PM. The expensive part (antialiased segments), so the
/// caller keeps the result and only redoes it when `baseKey` changes (or the
/// side does).
pub fn renderBase(cv: Canvas, raw: Clock, view: View) void {
    const clk = sanitize(raw);
    const m = cv.m;
    const lay = layout(m);
    @memcpy(cv.px, background(cv));

    // Weekday and day of the month, large.
    var date_buf: [8]u8 = undefined;
    const date = std.fmt.bufPrint(&date_buf, "{s} {d:0>2}", .{ weekdays[clk.wday], clk.mday }) catch "";
    const dmag = dateMag(m, lay);
    drawText(cv, lay.glass.x + @divTrunc(lay.glass.w - textWidth(date, dmag), 2), lay.date_y, dmag, date, col_text);

    // HH MM. Layout: d d : d d (the colon is renderSeconds' business).
    const shown = displayHour(clk.hour, view.hour12);
    const tens: ?u8 = if (view.hour12 and shown < 10) null else shown / 10;
    drawDigit(cv, lay.digit_x[0], lay.digits_y, tens);
    drawDigit(cv, lay.digit_x[1], lay.digits_y, shown % 10);
    drawDigit(cv, lay.digit_x[2], lay.digits_y, clk.min / 10);
    drawDigit(cv, lay.digit_x[3], lay.digits_y, clk.min % 10);

    // Month (or label) on the left, AM/PM on the right.
    var label_buf: [max_label]u8 = undefined;
    var info: []const u8 = months[clk.mon];
    if (view.label) |l| {
        const n = @min(l.len, max_label);
        for (l[0..n], 0..) |ch, i| label_buf[i] = std.ascii.toUpper(ch);
        info = label_buf[0..n];
    }
    const imag = infoMag(m, lay, info.len, view.hour12);
    drawText(cv, lay.bar.x, lay.info_y, imag, info, col_text);
    if (view.hour12) {
        const ampm: []const u8 = if (isPm(clk.hour)) "PM" else "AM";
        drawText(cv, lay.bar.x + lay.bar.w - textWidth(ampm, imag), lay.info_y, imag, ampm, col_text);
    }
}

/// What changes every second: the colon and the seconds bar. Draws on top of
/// a copy of renderBase's result, a few rectangles, no antialiasing.
pub fn renderSeconds(cv: Canvas, raw: Clock, view: View) void {
    const clk = sanitize(raw);
    const lay = layout(cv.m);
    drawColon(cv, lay, !view.seconds or clk.sec % 2 == 0);

    // Seconds: a bar that fills over the minute.
    if (view.seconds) {
        const b = lay.bar;
        fillBox(cv, b, col_ghost);
        const filled: i32 = @divTrunc(b.w * (@as(i32, clk.sec) + 1) + 59, 60); // rounded up: never empty
        fillRect(cv, b.x, b.y, filled, b.h, col_lit);
    }
}

/// A whole frame in one go (--snapshot, tests).
pub fn render(cv: Canvas, raw: Clock, view: View) void {
    renderBase(cv, raw, view);
    renderSeconds(cv, raw, view);
}

/// What renderBase depends on besides the view: the time without seconds.
/// While it stays the same, the base picture can be reused.
pub fn baseKey(raw: Clock) Clock {
    var k = sanitize(raw);
    k.sec = 0;
    return k;
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

const Px64 = [64 * 64]u32;

fn at(cv: Canvas, x: i32, y: i32) u32 {
    return cv.px[@intCast(y * cv.m.side + x)];
}

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

test "render: the tile has the Dock's frame, an opaque face, and the LCD" {
    var px: Px64 = undefined;
    const cv = Canvas.init(&px, 64);
    render(cv, .{ .hour = 8, .min = 8, .sec = 30, .mday = 2, .mon = 9, .wday = 5 }, .{});

    // Every pixel is opaque.
    for (px) |p| try std.testing.expectEqual(@as(u32, 0xff), p >> 24);
    // Bevel like dock.zig: light top/left, dark bottom/right, twice.
    try std.testing.expectEqual(col_light, at(cv, 10, 0));
    try std.testing.expectEqual(col_light, at(cv, 0, 10));
    try std.testing.expectEqual(col_dark, at(cv, 10, 63));
    try std.testing.expectEqual(col_dark, at(cv, 63, 10));
    try std.testing.expectEqual(col_light, at(cv, 10, 1));
    try std.testing.expectEqual(col_dark, at(cv, 10, 62));
    // The gradient runs from light (top-left) to dark (bottom-right).
    try std.testing.expect((at(cv, 3, 3) & 0xff) > (at(cv, 60, 60) & 0xff));
    // The LCD is recessed: dark edge top/left, light bottom/right.
    try std.testing.expectEqual(col_dark, at(cv, 5, 20));
    try std.testing.expectEqual(col_light, at(cv, 58, 20));
    try std.testing.expectEqual(col_lcd, at(cv, 7, 7));
}

test "render: 08:08 lights the right segments" {
    var px: Px64 = undefined;
    const cv = Canvas.init(&px, 64);
    render(cv, .{ .hour = 8, .min = 8, .sec = 30 }, .{});
    // Digit 1 is a 0 (no middle bar), digit 2 an 8 (all segments).
    // Middle bar: y = digits_y + 10 = 32, x = digit cell + 4.
    try std.testing.expectEqual(col_ghost, at(cv, 8 + 4, 31));
    try std.testing.expectEqual(col_lit, at(cv, 8 + 11 + 4, 31));
    // The top bar of the 0 is lit.
    try std.testing.expectEqual(col_lit, at(cv, 8 + 4, digits_y + 1));
}

test "render: 12-hour mode blanks the leading zero and shows AM/PM" {
    var am_px: Px64 = undefined;
    var h24_px: Px64 = undefined;
    const am = Canvas.init(&am_px, 64);
    const h24 = Canvas.init(&h24_px, 64);
    render(am, .{ .hour = 9, .min = 5, .sec = 0 }, .{ .hour12 = true });
    render(h24, .{ .hour = 9, .min = 5, .sec = 0 }, .{});
    // 09 in 24h shows a 0 (top bar lit); in 12h that cell is all ghost.
    try std.testing.expectEqual(col_lit, at(h24, 8 + 4, digits_y + 1));
    try std.testing.expectEqual(col_ghost, at(am, 8 + 4, digits_y + 1));
    // 24h has no AM/PM text; 12h does, so the two renders differ there.
    var differs = false;
    var y: i32 = info_y;
    while (y < info_y + 5) : (y += 1) {
        var x: i32 = bar_x + bar_w - 8;
        while (x < bar_x + bar_w) : (x += 1) {
            if (at(am, x, y) != at(h24, x, y)) differs = true;
        }
    }
    try std.testing.expect(differs);
}

test "render: the colon blinks with the seconds, and stays on without them" {
    var even_px: Px64 = undefined;
    var odd_px: Px64 = undefined;
    var steady_px: Px64 = undefined;
    const even = Canvas.init(&even_px, 64);
    const odd = Canvas.init(&odd_px, 64);
    const steady = Canvas.init(&steady_px, 64);
    render(even, .{ .hour = 1, .min = 2, .sec = 10 }, .{});
    render(odd, .{ .hour = 1, .min = 2, .sec = 11 }, .{});
    render(steady, .{ .hour = 1, .min = 2, .sec = 11 }, .{ .seconds = false });
    const cx = 8 + 22 + 1;
    const cy = digits_y + 5;
    try std.testing.expectEqual(col_lit, at(even, cx, cy));
    try std.testing.expectEqual(col_ghost, at(odd, cx, cy));
    try std.testing.expectEqual(col_lit, at(steady, cx, cy));
}

test "render: the seconds bar fills over the minute and is absent when off" {
    var a_px: Px64 = undefined;
    var b_px: Px64 = undefined;
    var off_px: Px64 = undefined;
    const a = Canvas.init(&a_px, 64);
    const b = Canvas.init(&b_px, 64);
    const off = Canvas.init(&off_px, 64);
    render(a, .{ .sec = 0 }, .{});
    render(b, .{ .sec = 59 }, .{});
    render(off, .{ .sec = 59 }, .{ .seconds = false });
    const y = bar_y + 1;
    // 0 s: about a sixtieth filled; 59 s: all of it.
    try std.testing.expectEqual(col_lit, at(a, bar_x, y));
    try std.testing.expectEqual(col_ghost, at(a, bar_x + bar_w - 1, y));
    try std.testing.expectEqual(col_lit, at(b, bar_x + bar_w - 1, y));
    // Off: the bar's place is just LCD glass.
    try std.testing.expectEqual(col_lcd, at(off, bar_x + 5, y));
}

test "render: a label replaces the month, and a long one is cut" {
    var month_px: Px64 = undefined;
    var label_px: Px64 = undefined;
    var long_px: Px64 = undefined;
    var cut_px: Px64 = undefined;
    const clk: Clock = .{ .mon = 9 };
    render(Canvas.init(&month_px, 64), clk, .{});
    render(Canvas.init(&label_px, 64), clk, .{ .label = "tokyo" });
    render(Canvas.init(&long_px, 64), clk, .{ .label = "abcdefghijklmnop" });
    render(Canvas.init(&cut_px, 64), clk, .{ .label = "abcdefgh" });
    try std.testing.expect(!std.mem.eql(u32, &month_px, &label_px));
    // Everything past max_label is ignored.
    try std.testing.expect(std.mem.eql(u32, &long_px, &cut_px));
}

test "render survives nonsense clock values" {
    var px: Px64 = undefined;
    const cv = Canvas.init(&px, 64);
    render(cv, .{ .hour = 255, .min = 255, .sec = 255, .mday = 255, .mon = 255, .wday = 255 }, .{ .hour12 = true, .label = "\x00\xff" });
    // Nothing to assert beyond "did not crash or overflow"; still opaque.
    try std.testing.expectEqual(@as(u32, 0xff), px[0] >> 24);
    render(cv, .{ .hour = 255, .min = 255, .sec = 255, .mday = 0, .mon = 255, .wday = 255 }, .{});
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

test "renderBase once + renderSeconds per second equals a full render, at any size" {
    var base_px: Pixels = undefined;
    var px_buf: Pixels = undefined;
    var full_px: Pixels = undefined;
    const t0: Clock = .{ .hour = 7, .min = 41, .sec = 3, .mday = 9, .mon = 2, .wday = 4 };
    const views = [_]View{ .{}, .{ .hour12 = true, .label = "x" }, .{ .seconds = false } };
    for ([_]i32{ 64, 96, 128 }) |side| {
        const base = Canvas.init(&base_px, side);
        const px = Canvas.init(&px_buf, side);
        const full = Canvas.init(&full_px, side);
        for (views) |v| {
            renderBase(base, t0, v);
            var s: u8 = 0;
            while (s < 60) : (s += 7) {
                var t = t0;
                t.sec = s;
                @memcpy(px.px, base.px);
                renderSeconds(px, t, v);
                render(full, t, v);
                try std.testing.expect(std.mem.eql(u32, px.px, full.px));
            }
        }
    }
}

test "baseKey ignores the second and sanitizes" {
    const a: Clock = .{ .hour = 1, .min = 2, .sec = 5 };
    const b: Clock = .{ .hour = 1, .min = 2, .sec = 6 };
    const c: Clock = .{ .hour = 1, .min = 3, .sec = 5 };
    try std.testing.expect(std.meta.eql(baseKey(a), baseKey(b)));
    try std.testing.expect(!std.meta.eql(baseKey(a), baseKey(c)));
    try std.testing.expectEqual(@as(u8, 23), baseKey(.{ .hour = 255 }).hour);
}

test "every tile size draws an opaque face without leaving the buffer" {
    var buf: Pixels = undefined;
    var side: i32 = scale.min_side;
    while (side <= scale.max_side) : (side += 9) {
        const cv = Canvas.init(&buf, side);
        render(cv, .{ .hour = 23, .min = 59, .sec = 59, .mday = 31, .mon = 11, .wday = 6 }, .{ .hour12 = true, .label = "abcdefgh" });
        for (cv.px) |p| try std.testing.expectEqual(@as(u32, 0xff), p >> 24);
    }
    const last = Canvas.init(&buf, scale.max_side);
    render(last, .{}, .{});
    for (last.px) |p| try std.testing.expectEqual(@as(u32, 0xff), p >> 24);
}

test "pixel text fits its line at every size, and grows with the tile" {
    var side: i32 = scale.min_side;
    while (side <= scale.max_side) : (side += 1) {
        const m = scale.Metrics.init(side);
        const lay = layout(m);
        const dm = dateMag(m, lay);
        try std.testing.expect(dm >= 1);
        // At least the minimum of 1 px: otherwise it must fit.
        if (dm > 1) {
            try std.testing.expect(textWidth("FRI 02", dm) <= lay.bar.w);
            try std.testing.expect(5 * dm <= lay.digits_y - lay.date_y);
        }
        for (0..max_label + 1) |n| {
            for ([_]bool{ false, true }) |h12| {
                const im = infoMag(m, lay, n, h12);
                try std.testing.expect(im >= 1);
                if (im > 1) {
                    const cells = n + if (h12) @as(usize, 3) else 0;
                    try std.testing.expect(cellsWidth(cells, im) <= lay.bar.w);
                    try std.testing.expect(5 * im <= lay.bar.y - lay.info_y);
                }
            }
        }
    }
    // At 64 px nothing changed; at 128 px the text is twice as big.
    const m64 = scale.Metrics.init(64);
    try std.testing.expectEqual(@as(i32, 2), dateMag(m64, layout(m64)));
    try std.testing.expectEqual(@as(i32, 1), infoMag(m64, layout(m64), 8, true));
    const m128 = scale.Metrics.init(128);
    try std.testing.expectEqual(@as(i32, 4), dateMag(m128, layout(m128)));
    try std.testing.expectEqual(@as(i32, 2), infoMag(m128, layout(m128), 3, false));
}

test "render at 128 px: the picture is drawn at its own size, not stretched" {
    var buf: Pixels = undefined;
    const cv = Canvas.init(&buf, 128);
    render(cv, .{ .hour = 8, .min = 8, .sec = 59, .mday = 2, .mon = 9, .wday = 5 }, .{});

    // The two bevel steps are two pixels each: four light rows on top, and the
    // fifth is gradient again.
    for (0..4) |i| try std.testing.expectEqual(col_light, at(cv, 40, @intCast(i)));
    try std.testing.expect(at(cv, 40, 4) != col_light);
    for (0..4) |i| try std.testing.expectEqual(col_dark, at(cv, 40, @intCast(127 - i)));
    // The LCD frame is two pixels thick: dark at x = 10 and 11, glass from 12.
    try std.testing.expectEqual(col_dark, at(cv, 10, 40));
    try std.testing.expectEqual(col_dark, at(cv, 11, 40));
    try std.testing.expectEqual(col_lcd, at(cv, 14, 40));
    // The top bar of the first 0 sits at 2 x its 64 px place and is lit through.
    try std.testing.expectEqual(col_lit, at(cv, 16 + 9, 46));
    // The seconds bar is full at 59 s and 2 x as wide as at 64 px.
    const lay = layout(cv.m);
    try std.testing.expectEqual(@as(i32, 92), lay.bar.w);
    try std.testing.expectEqual(col_lit, at(cv, lay.bar.x + lay.bar.w - 1, lay.bar.y + 1));
}

test "layout: the LCD stays inside the tile and the parts do not overlap at any size" {
    var side: i32 = scale.min_side;
    while (side <= scale.max_side) : (side += 1) {
        const m = scale.Metrics.init(side);
        const lay = layout(m);
        const gl = lay.glass;
        try std.testing.expect(gl.x - lay.frame >= 0 and gl.y - lay.frame >= 0);
        try std.testing.expect(gl.x + gl.w + lay.frame <= side and gl.y + gl.h + lay.frame <= side);
        try std.testing.expect(lay.digit_x[0] < lay.digit_x[1] and lay.digit_x[1] < lay.digit_x[2] and lay.digit_x[2] < lay.digit_x[3]);
        try std.testing.expect(lay.digit_x[3] + m.edge(digit_w) <= gl.x + gl.w);
        try std.testing.expect(lay.bar.x + lay.bar.w <= gl.x + gl.w);
        try std.testing.expect(lay.bar.y + lay.bar.h <= gl.y + gl.h);
        try std.testing.expect(lay.bar.h >= 1 and lay.colon[0].w >= 1 and lay.colon[1].h >= 1);
    }
}
