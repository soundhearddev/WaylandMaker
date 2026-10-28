// SPDX-License-Identifier: GPL-3.0
//
// The scale system of wmaker-wl and of its DockApps.
//
// Window Maker never resamples a finished picture: a Dock tile is `IconSize`
// pixels (64 by default) and whatever sits in it is drawn at that size, or
// (a DockApp that is smaller than the tile) simply centred. wmaker-wl has a
// `dock_size` (16..256 px), so the same has to hold for every size in that
// range. This file is the one place that knows how:
//
//   * `Metrics` is the *design grid*. Everything is designed on a 64x64 tile
//     ("design units"); a Metrics for a `side` x `side` tile turns design
//     units into whole device pixels. Positions are snapped as EDGES
//     (`edge`), sizes as the distance of two snapped edges (`len`/`box`), so
//     neighbouring shapes never get a gap or an overlap and nothing ends up
//     on a half pixel (= blurry). Strokes never get thinner than 1 px
//     (`stroke`), pixel-font scales are whole numbers (`whole`), and font
//     point sizes are scaled (`fontDesc`).
//   * `proposedSide` is what a client draws at: the side the compositor
//     proposed in xdg_toplevel.configure.
//   * `resize` / `centre` are the fallbacks for a picture that cannot be
//     redrawn (a bitmap): resampled (bilinear up, box average down), or the
//     way Window Maker does it, at its native size in the middle of the tile.
//
// Pure (no Wayland, no cairo, no libc), so it is unit-tested without a
// compositor. The DockApps in examples/ carry a copy of this file; keep them
// identical (`diff src/scale.zig examples/*/src/scale.zig`).

const std = @import("std");

/// The side of the design tile: Window Maker's default `IconSize`.
pub const native: i32 = 64;
/// The sides a tile can have (wmaker-wl's dock_size is 16..256).
pub const min_side: i32 = 16;
pub const max_side: i32 = 256;
/// Pixels of the biggest tile (size a fixed buffer with this).
pub const max_pixels: usize = @as(usize, @intCast(max_side)) * @as(usize, @intCast(max_side));

pub fn clampSide(side: i32) i32 {
    return std.math.clamp(side, min_side, max_side);
}

/// The side to draw for a configure of `w` x `h`: 0 (or less) means "no
/// preference" (then `fallback`); otherwise the smaller edge, kept in range.
pub fn proposedSide(w: i32, h: i32, fallback: i32) i32 {
    if (w <= 0 or h <= 0) return fallback;
    return clampSide(@min(w, h));
}

/// Where a design-unit shape ends up, in device pixels.
pub const Box = struct { x: i32, y: i32, w: i32, h: i32 };

/// The design grid (64x64) mapped onto a `side` x `side` tile.
pub const Metrics = struct {
    side: i32 = native,

    pub fn init(side: i32) Metrics {
        return .{ .side = clampSide(side) };
    }

    /// Design units -> the nearest device pixel EDGE (half rounds up).
    /// 0 stays 0 and `native` is always `side`, whatever the side.
    pub fn edge(m: Metrics, v: i32) i32 {
        return @divFloor(v * m.side * 2 + native, native * 2);
    }

    /// A position (alias of `edge`, reads better at the call site).
    pub fn pos(m: Metrics, v: i32) i32 {
        return m.edge(v);
    }

    /// The length of the span [at, at + size) in design units, in pixels:
    /// the distance of two snapped edges, so spans that touch still touch.
    pub fn len(m: Metrics, at: i32, size: i32) i32 {
        return m.edge(at + size) - m.edge(at);
    }

    /// A rectangle in design units, snapped edge to edge.
    pub fn box(m: Metrics, x: i32, y: i32, w: i32, h: i32) Box {
        return .{ .x = m.edge(x), .y = m.edge(y), .w = m.len(x, w), .h = m.len(y, h) };
    }

    /// A line width: scaled, but never below one pixel.
    pub fn stroke(m: Metrics, v: i32) i32 {
        return @max(1, m.edge(v));
    }

    /// A whole-number magnification (the scale of a pixel font): rounded
    /// DOWN so text is never wider than the proportional layout, and at
    /// least 1.
    pub fn whole(m: Metrics, v: i32) i32 {
        return @max(1, @divFloor(v * m.side, native));
    }

    /// Design units -> exact pixels, for antialiased geometry (polygons).
    pub fn f(m: Metrics, v: f32) f32 {
        return v * @as(f32, @floatFromInt(m.side)) / @as(f32, @floatFromInt(native));
    }

    pub fn isNative(m: Metrics) bool {
        return m.side == native;
    }

    /// The pixels of one `side` x `side` frame.
    pub fn pixels(m: Metrics) usize {
        return @as(usize, @intCast(m.side)) * @as(usize, @intCast(m.side));
    }

    /// `desc` is a Pango font description ("Sans Bold 22"): the same font
    /// with the point size scaled. Unchanged at the native size and for a
    /// description that does not end in a size. `buf` holds the result.
    pub fn fontDesc(m: Metrics, buf: []u8, desc: []const u8) [:0]const u8 {
        const plain = std.fmt.bufPrintZ(buf, "{s}", .{desc}) catch return "Sans 10";
        if (m.isNative()) return plain;
        const sp = std.mem.lastIndexOfScalar(u8, desc, ' ') orelse return plain;
        const size = std.fmt.parseFloat(f32, desc[sp + 1 ..]) catch return plain;
        if (!(size > 0)) return plain;
        const scaled = @max(1.0, m.f(size));
        return std.fmt.bufPrintZ(buf, "{s} {d:.1}", .{ desc[0..sp], scaled }) catch plain;
    }
};

// ----------------------------------------------------------------------------
// Pictures that cannot be redrawn
// ----------------------------------------------------------------------------

/// What to do with a finished `src_side` picture in a bigger or smaller tile.
pub const Fit = enum {
    /// Window Maker's way: no resampling, the picture stays as it is, in the
    /// middle of the tile (cropped if the tile is smaller).
    centred,
    /// Resample: bilinear when it grows, a box average when it shrinks.
    resampled,
};

pub fn place(fit: Fit, dst: []u32, dst_side: usize, src: []const u32, src_side: usize) void {
    switch (fit) {
        .centred => centre(dst, dst_side, src, src_side),
        .resampled => resize(dst, dst_side, src, src_side),
    }
}

/// `src` unchanged in the middle of `dst`; the rest of `dst` is transparent.
pub fn centre(dst: []u32, dst_side: usize, src: []const u32, src_side: usize) void {
    std.debug.assert(dst.len >= dst_side * dst_side and src.len >= src_side * src_side);
    @memset(dst[0 .. dst_side * dst_side], 0);
    const n = @min(dst_side, src_side);
    const dst_off = (dst_side - n) / 2;
    const src_off = (src_side - n) / 2;
    for (0..n) |y| {
        const d = dst[(dst_off + y) * dst_side + dst_off ..][0..n];
        const s = src[(src_off + y) * src_side + src_off ..][0..n];
        @memcpy(d, s);
    }
}

/// Draw `src` (src_side x src_side, ARGB) into `dst` (dst_side x dst_side).
pub fn resize(dst: []u32, dst_side: usize, src: []const u32, src_side: usize) void {
    std.debug.assert(dst.len >= dst_side * dst_side and src.len >= src_side * src_side);
    if (dst_side == src_side) {
        @memcpy(dst[0 .. dst_side * dst_side], src[0 .. src_side * src_side]);
    } else if (dst_side > src_side) {
        bilinear(dst, dst_side, src, src_side);
    } else {
        box(dst, dst_side, src, src_side);
    }
}

fn clampIndex(v: f32, n: usize) usize {
    const hi: f32 = @floatFromInt(n - 1);
    return @intFromFloat(std.math.clamp(v, 0, hi));
}

fn bilinear(dst: []u32, dst_side: usize, src: []const u32, src_side: usize) void {
    const ratio: f32 = @as(f32, @floatFromInt(src_side)) / @as(f32, @floatFromInt(dst_side));
    for (0..dst_side) |y| {
        const fy = (@as(f32, @floatFromInt(y)) + 0.5) * ratio - 0.5;
        const fy0 = @floor(fy);
        const ty = fy - fy0;
        const y0 = clampIndex(fy0, src_side);
        const y1 = clampIndex(fy0 + 1, src_side);
        for (0..dst_side) |x| {
            const fx = (@as(f32, @floatFromInt(x)) + 0.5) * ratio - 0.5;
            const fx0 = @floor(fx);
            const tx = fx - fx0;
            const x0 = clampIndex(fx0, src_side);
            const x1 = clampIndex(fx0 + 1, src_side);
            dst[y * dst_side + x] = mix4(
                src[y0 * src_side + x0],
                src[y0 * src_side + x1],
                src[y1 * src_side + x0],
                src[y1 * src_side + x1],
                tx,
                ty,
            );
        }
    }
}

fn mix4(p00: u32, p10: u32, p01: u32, p11: u32, tx: f32, ty: f32) u32 {
    var out: u32 = 0;
    inline for (.{ 0, 8, 16, 24 }) |shift| {
        const sh: u5 = shift;
        const a: f32 = @floatFromInt((p00 >> sh) & 0xff);
        const b: f32 = @floatFromInt((p10 >> sh) & 0xff);
        const c: f32 = @floatFromInt((p01 >> sh) & 0xff);
        const d: f32 = @floatFromInt((p11 >> sh) & 0xff);
        const top = a + (b - a) * tx;
        const bottom = c + (d - c) * tx;
        const v = std.math.clamp(@round(top + (bottom - top) * ty), 0, 255);
        const byte: u32 = @intFromFloat(v);
        out |= byte << sh;
    }
    return out;
}

fn box(dst: []u32, dst_side: usize, src: []const u32, src_side: usize) void {
    for (0..dst_side) |y| {
        const sy0 = y * src_side / dst_side;
        const sy1 = @max(sy0 + 1, (y + 1) * src_side / dst_side);
        for (0..dst_side) |x| {
            const sx0 = x * src_side / dst_side;
            const sx1 = @max(sx0 + 1, (x + 1) * src_side / dst_side);
            var sum = [4]u32{ 0, 0, 0, 0 };
            var n: u32 = 0;
            for (sy0..sy1) |sy| {
                for (sx0..sx1) |sx| {
                    const p = src[sy * src_side + sx];
                    sum[0] += p & 0xff;
                    sum[1] += (p >> 8) & 0xff;
                    sum[2] += (p >> 16) & 0xff;
                    sum[3] += (p >> 24) & 0xff;
                    n += 1;
                }
            }
            dst[y * dst_side + x] = (sum[0] / n) |
                ((sum[1] / n) << 8) |
                ((sum[2] / n) << 16) |
                ((sum[3] / n) << 24);
        }
    }
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

test "proposedSide: no preference is the fallback, the rest is kept in range" {
    try std.testing.expectEqual(@as(i32, 64), proposedSide(0, 0, 64));
    try std.testing.expectEqual(@as(i32, 64), proposedSide(-1, 96, 64));
    try std.testing.expectEqual(@as(i32, 96), proposedSide(96, 96, 64));
    try std.testing.expectEqual(@as(i32, 80), proposedSide(96, 80, 64));
    try std.testing.expectEqual(@as(i32, min_side), proposedSide(2, 2, 64));
    try std.testing.expectEqual(@as(i32, max_side), proposedSide(1000, 1000, 64));
}

test "Metrics: the native grid is the identity" {
    const m = Metrics.init(64);
    try std.testing.expect(m.isNative());
    var v: i32 = -8;
    while (v <= 80) : (v += 1) {
        try std.testing.expectEqual(v, m.edge(v));
        try std.testing.expectEqual(@as(i32, 3), m.len(v, 3));
    }
    try std.testing.expectEqual(@as(i32, 2), m.stroke(2));
    try std.testing.expectEqual(@as(i32, 2), m.whole(2));
    try std.testing.expectEqual(@as(f32, 10), m.f(10));
}

test "Metrics: the end of the design tile is the end of every tile" {
    var side: i32 = min_side;
    while (side <= max_side) : (side += 1) {
        const m = Metrics.init(side);
        try std.testing.expectEqual(@as(i32, 0), m.edge(0));
        try std.testing.expectEqual(side, m.edge(native));
        try std.testing.expectEqual(side, m.len(0, native));
    }
}

test "Metrics: edges only ever move forward, spans that touch still touch" {
    var side: i32 = min_side;
    while (side <= max_side) : (side += 7) {
        const m = Metrics.init(side);
        var v: i32 = 0;
        while (v < native) : (v += 1) {
            try std.testing.expect(m.edge(v + 1) >= m.edge(v));
        }
        // 6 + 52 + 6 tiles the whole 64 without a gap or an overlap.
        const a = m.box(0, 0, 6, 64);
        const b = m.box(6, 0, 52, 64);
        const c = m.box(58, 0, 6, 64);
        try std.testing.expectEqual(a.x + a.w, b.x);
        try std.testing.expectEqual(b.x + b.w, c.x);
        try std.testing.expectEqual(side, c.x + c.w);
    }
}

test "Metrics: a stroke is never thinner than a pixel, a whole scale never zero" {
    const small = Metrics.init(16);
    try std.testing.expectEqual(@as(i32, 1), small.stroke(1));
    try std.testing.expectEqual(@as(i32, 1), small.whole(1));
    try std.testing.expectEqual(@as(i32, 1), small.whole(2));
    const big = Metrics.init(128);
    try std.testing.expectEqual(@as(i32, 2), big.stroke(1));
    try std.testing.expectEqual(@as(i32, 4), big.whole(2));
    // 96 px: a 2x pixel font becomes 3x (rounded down from 3.0), 1x stays 1x.
    const mid = Metrics.init(96);
    try std.testing.expectEqual(@as(i32, 3), mid.whole(2));
    try std.testing.expectEqual(@as(i32, 1), mid.whole(1));
    // 80 px: 2 * 1.25 = 2.5 -> 2, never wider than the proportional layout.
    try std.testing.expectEqual(@as(i32, 2), Metrics.init(80).whole(2));
}

test "Metrics: 96 px is exactly one and a half" {
    const m = Metrics.init(96);
    try std.testing.expectEqual(@as(i32, 12), m.edge(8));
    try std.testing.expectEqual(@as(i32, 9), m.edge(6));
    try std.testing.expectEqual(@as(i32, 78), m.len(6, 52));
    try std.testing.expectEqual(@as(f32, 15), m.f(10));
}

test "Metrics.fontDesc scales the size and leaves the rest alone" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Sans Bold 22", Metrics.init(64).fontDesc(&buf, "Sans Bold 22"));
    try std.testing.expectEqualStrings("Sans Bold 44.0", Metrics.init(128).fontDesc(&buf, "Sans Bold 22"));
    try std.testing.expectEqualStrings("Sans 6.0", Metrics.init(96).fontDesc(&buf, "Sans 4"));
    // No size: unchanged. A tiny tile never goes below 1 pt.
    try std.testing.expectEqualStrings("Sans Bold", Metrics.init(128).fontDesc(&buf, "Sans Bold"));
    try std.testing.expectEqualStrings("Sans 1.0", Metrics.init(16).fontDesc(&buf, "Sans 1"));
}

test "centre: the picture is not resampled, only moved" {
    const src: [4]u32 = .{ 1, 2, 3, 4 };
    var dst: [16]u32 = undefined;
    centre(&dst, 4, &src, 2);
    const want = [16]u32{ 0, 0, 0, 0, 0, 1, 2, 0, 0, 3, 4, 0, 0, 0, 0, 0 };
    try std.testing.expectEqualSlices(u32, &want, &dst);
    // A smaller tile crops around the middle.
    const big: [16]u32 = .{ 0, 0, 0, 0, 0, 1, 2, 0, 0, 3, 4, 0, 0, 0, 0, 0 };
    var small: [4]u32 = undefined;
    centre(&small, 2, &big, 4);
    try std.testing.expectEqualSlices(u32, &src, &small);
}

test "resize: same size copies, a flat colour stays flat, the corners stay" {
    const src: [4]u32 = .{ 0xff112233, 0xff445566, 0xff778899, 0xffaabbcc };
    var same: [4]u32 = undefined;
    resize(&same, 2, &src, 2);
    try std.testing.expectEqualSlices(u32, &src, &same);

    const flat_src: [16]u32 = @splat(0xff336699);
    var up: [64]u32 = undefined;
    resize(&up, 8, &flat_src, 4);
    for (up) |p| try std.testing.expectEqual(@as(u32, 0xff336699), p);
    var down: [4]u32 = undefined;
    resize(&down, 2, &flat_src, 4);
    for (down) |p| try std.testing.expectEqual(@as(u32, 0xff336699), p);

    var big: [16]u32 = undefined;
    resize(&big, 4, &src, 2);
    try std.testing.expectEqual(src[0], big[0]);
    try std.testing.expectEqual(src[1], big[3]);
    try std.testing.expectEqual(src[2], big[12]);
    try std.testing.expectEqual(src[3], big[15]);
}

test "resize: shrinking averages the pixels of a box" {
    // 2x2 of 0x00 and 0xff in one channel -> one pixel of 0x7f (integer mean).
    const src = [4]u32{ 0xff000000, 0xff0000fe, 0xff000000, 0xff0000fe };
    var dst: [1]u32 = undefined;
    resize(&dst, 1, &src, 2);
    try std.testing.expectEqual(@as(u32, 0xff00007f), dst[0]);
}
