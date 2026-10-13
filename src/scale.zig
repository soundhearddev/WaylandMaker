// SPDX-License-Identifier: 0BSD
//
// The face is drawn by hand at 64x64 (face.zig). wmaker-wl's `dock_size`
// makes the Dock tile bigger or smaller, and a DockApp that sets no size
// hint is proposed one whole tile (xdg_toplevel.configure). This file turns
// the 64x64 picture into the side the compositor proposed: bilinear when it
// grows, a box average when it shrinks. Pure, so it is testable without a
// compositor. (wl-battery has the same file.)

const std = @import("std");

/// The sides a tile can have (wmaker-wl's dock_size is 16..256).
pub const min_side: i32 = 16;
pub const max_side: i32 = 256;

/// The side to draw for a configure of `w` x `h`: 0 means "no preference"
/// (then `native`); otherwise the smaller edge, kept in range.
pub fn proposedSide(w: i32, h: i32, native: i32) i32 {
    if (w <= 0 or h <= 0) return native;
    return std.math.clamp(@min(w, h), min_side, max_side);
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

test "proposedSide: no preference is the native size, the rest is kept in range" {
    try std.testing.expectEqual(@as(i32, 64), proposedSide(0, 0, 64));
    try std.testing.expectEqual(@as(i32, 64), proposedSide(-1, 96, 64));
    try std.testing.expectEqual(@as(i32, 96), proposedSide(96, 96, 64));
    try std.testing.expectEqual(@as(i32, 80), proposedSide(96, 80, 64));
    try std.testing.expectEqual(@as(i32, min_side), proposedSide(2, 2, 64));
    try std.testing.expectEqual(@as(i32, max_side), proposedSide(1000, 1000, 64));
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
