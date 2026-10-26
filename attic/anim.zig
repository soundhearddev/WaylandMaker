// SPDX-License-Identifier: GPL-3.0
//
// Window Maker's miniaturize / deminiaturize animation, ported from
// window-maker/wmaker `src/actions.c` (`animateResize`, `animateResizeZoom`,
// `animateResizeTwist`, `animateResizeFlip`) with the constants of
// `src/wconfig.h.in` (MINIATURIZE_ANIMATION_*).
//
// Window Maker draws the frames itself, one after the other, straight onto
// the root window: XOR lines, `usleep` between two of them. Neither exists
// here, so this module only does the part that is pure arithmetic: the same
// loops, in `float` like the C code (the same sums, the same truncation to
// the 16 bit `XPoint` / `int` coordinates), but they write the frames into a
// `Plan` instead of drawing them. ui.zig shows frame `k` for `delay_ms`
// milliseconds on a transparent surface, which is Window Maker's
// "draw, sleep, erase" without the sleeping.
//
//   style   frames                    delay per frame
//   zoom    steps + 1 = 17  (7 boxes)  10 ms
//   twist   13 or 14        (1 box)    20 ms   (half a turn)
//   flip    13 or 14        (1 box)    20 ms   (half a turn)
//
// Called with the window's frame and the icon's box to iconify and the other
// way round to deiconify (actions.c: wIconifyWindow / wDeiconifyWindow).
//
// No Wayland types in here: unit-testable without a compositor.

const std = @import("std");
const gfx = @import("gfx.zig");

pub const Style = enum { zoom, twist, flip };

/// A rectangle in global coordinates (x, y, width, height).
pub const Box = struct { x: i32, y: i32, w: i32, h: i32 };

// ---- wconfig.h.in ---------------------------------------------------------
const zoom_frames: usize = 7; // MINIATURIZE_ANIMATION_FRAMES_Z
const zoom_steps: i32 = 16; // ..._STEPS_Z
const zoom_delay_us: u32 = 10000; // ..._DELAY_Z

const twist_frames: i32 = 12; // ..._FRAMES_T
const twist_steps: i32 = 16; // ..._STEPS_T
const twist_delay_us: u32 = 20000; // ..._DELAY_T
const twist_turns: f64 = 0.5; // ..._TWIST_T

const flip_frames: i32 = 12; // ..._FRAMES_F
const flip_steps: i32 = 16; // ..._STEPS_F
const flip_delay_us: u32 = 20000; // ..._DELAY_F
const flip_turns: f64 = 0.5; // ..._TWIST_F

/// Most frames a plan can hold (zoom has 17, twist and flip 13 or 14).
pub const max_frames: usize = 20;

pub const Frame = union(enum) {
    /// Twist and flip: a closed quadrilateral, five points (the last one is
    /// the first), already cut to whole coordinates like an `XPoint`.
    poly: [5][2]i16,
    /// Zoom: seven boxes (x, y, width, height) drawn together, the trail.
    boxes: [zoom_frames][4]i32,
};

pub const Plan = struct {
    style: Style,
    n: usize = 0,
    frames: [max_frames]Frame = undefined,
    /// How long one frame stays: Window Maker's `wusleep` between drawing it
    /// and erasing it.
    delay_ms: u32,
    /// The smallest box that holds every frame (line width included).
    bounds: Box = .{ .x = 0, .y = 0, .w = 0, .h = 0 },

    pub fn frame(p: *const Plan, i: usize) Frame {
        return p.frames[@min(i, p.n -| 1)];
    }

    /// Total time of the animation.
    pub fn durationMs(p: *const Plan) u32 {
        return @intCast(p.n * p.delay_ms);
    }

    fn push(p: *Plan, f: Frame) bool {
        if (p.n >= max_frames) return false;
        p.frames[p.n] = f;
        p.n += 1;
        return true;
    }
};

// ---- C conversions ----------------------------------------------------------

fn fl(v: i32) f32 {
    return @floatFromInt(v);
}

/// float -> `short` (an XPoint coordinate): cut towards zero. Out of range
/// (which C leaves undefined) is clamped.
fn short(v: f32) i16 {
    if (std.math.isNan(v)) return 0;
    return @intFromFloat(std.math.clamp(@trunc(v), -32768.0, 32767.0));
}

/// float -> `int` (an XDrawRectangle argument): cut towards zero.
fn trunc32(v: f32) i32 {
    if (std.math.isNan(v)) return 0;
    return @intFromFloat(std.math.clamp(@trunc(v), -1.0e9, 1.0e9));
}

fn msOf(us: u32) u32 {
    return @max(1, @divTrunc(us, 1000));
}

// ---- the three animations -----------------------------------------------------

/// animateResizeTwist: a rectangle that turns half way round while it
/// travels (centre to centre) and changes its size.
fn twist(p: *Plan, from: Box, to: Box) void {
    const steps: f32 = @floatFromInt(twist_steps);
    // x += w / 2; fx += fw / 2;  (int arithmetic)
    const x = from.x + @divTrunc(from.w, 2);
    const y = from.y + @divTrunc(from.h, 2);
    const fx = to.x + @divTrunc(to.w, 2);
    const fy = to.y + @divTrunc(to.h, 2);

    const xstep: f32 = fl(fx - x) / steps;
    const ystep: f32 = fl(fy - y) / steps;
    const wstep: f32 = fl(to.w - from.w) / steps;
    const hstep: f32 = fl(to.h - from.h) / steps;

    var cx: f32 = fl(x);
    var cy: f32 = fl(y);
    var cw: f32 = fl(from.w);
    var ch: f32 = fl(from.h);

    const pi32: f32 = @floatCast(std.math.pi);
    const final_angle: f32 = @floatCast(2.0 * std.math.pi * twist_turns);
    const delta: f32 = final_angle / @as(f32, @floatFromInt(twist_frames));

    var angle: f32 = 0;
    while (true) {
        if (angle > final_angle) angle = final_angle;

        const a: f32 = std.math.atan2(ch, cw);
        const d: f32 = @sqrt((cw / 2) * (cw / 2) + (ch / 2) * (ch / 2));

        var pts: [5][2]i16 = undefined;
        pts[0] = .{ short(cx + @cos(angle - a) * d), short(cy + @sin(angle - a) * d) };
        pts[1] = .{ short(cx + @cos(angle + a) * d), short(cy + @sin(angle + a) * d) };
        pts[2] = .{ short(cx + @cos(angle - a + pi32) * d), short(cy + @sin(angle - a + pi32) * d) };
        pts[3] = .{ short(cx + @cos(angle + a + pi32) * d), short(cy + @sin(angle + a + pi32) * d) };
        pts[4] = pts[0];
        if (!p.push(.{ .poly = pts })) return;

        cx += xstep;
        cy += ystep;
        cw += wstep;
        ch += hstep;
        if (angle >= final_angle) break;
        angle += delta;
    }
}

/// animateResizeFlip: a rectangle that turns around its horizontal axis (as
/// if it were a card) while it travels and changes its size.
fn flip(p: *Plan, from: Box, to: Box) void {
    const steps: f32 = @floatFromInt(flip_steps);
    const xstep: f32 = fl(to.x - from.x) / steps;
    const ystep: f32 = fl(to.y - from.y) / steps;
    const wstep: f32 = fl(to.w - from.w) / steps;
    const hstep: f32 = fl(to.h - from.h) / steps;

    var cx: f32 = fl(from.x);
    var cy: f32 = fl(from.y);
    var cw: f32 = fl(from.w);
    var ch: f32 = fl(from.h);

    const final_angle: f32 = @floatCast(2.0 * std.math.pi * flip_turns);
    const delta: f32 = final_angle / @as(f32, @floatFromInt(flip_frames));

    var angle: f32 = 0;
    while (true) {
        if (angle > final_angle) angle = final_angle;

        const dx: f32 = (cw / 10) - ((cw / 5) * @sin(angle));
        const dch: f32 = (ch / 2) * @cos(angle);
        const midy: f32 = cy + (ch / 2);

        var pts: [5][2]i16 = undefined;
        pts[0] = .{ short(cx + dx), short(midy - dch) };
        pts[1] = .{ short(cx + cw - dx), pts[0][1] };
        pts[2] = .{ short(cx + cw + dx), short(midy + dch) };
        pts[3] = .{ short(cx - dx), pts[2][1] };
        pts[4] = pts[0];
        if (!p.push(.{ .poly = pts })) return;

        cx += xstep;
        cy += ystep;
        cw += wstep;
        ch += hstep;
        if (angle >= final_angle) break;
        angle += delta;
    }
}

/// animateResizeZoom: a rectangle that grows or shrinks from one box to the
/// other, leaving a trail of `zoom_frames` boxes behind it.
fn zoom(p: *Plan, from: Box, to: Box) void {
    const steps: f32 = @floatFromInt(zoom_steps);
    const xstep: f32 = fl(to.x - from.x) / steps;
    const ystep: f32 = fl(to.y - from.y) / steps;
    const wstep: f32 = fl(to.w - from.w) / steps;
    const hstep: f32 = fl(to.h - from.h) / steps;

    var cx: [zoom_frames]f32 = @splat(fl(from.x));
    var cy: [zoom_frames]f32 = @splat(fl(from.y));
    var cw: [zoom_frames]f32 = @splat(fl(from.w));
    var ch: [zoom_frames]f32 = @splat(fl(from.h));

    // What is on the screen at one moment: all the boxes together.
    const snapshot = struct {
        fn of(x: *const [zoom_frames]f32, y: *const [zoom_frames]f32, w: *const [zoom_frames]f32, h: *const [zoom_frames]f32) Frame {
            var b: [zoom_frames][4]i32 = undefined;
            for (0..zoom_frames) |j| b[j] = .{ trunc32(x[j]), trunc32(y[j]), trunc32(w[j]), trunc32(h[j]) };
            return .{ .boxes = b };
        }
    }.of;

    var i: i32 = 0;
    while (i < zoom_steps) : (i += 1) {
        if (!p.push(snapshot(&cx, &cy, &cw, &ch))) return;
        // The trail moves on: every box takes its successor's place, the
        // last one takes a step.
        for (0..zoom_frames) |j| {
            if (j < zoom_frames - 1) {
                cx[j] = cx[j + 1];
                cy[j] = cy[j + 1];
                cw[j] = cw[j + 1];
                ch[j] = ch[j + 1];
            } else {
                cx[j] += xstep;
                cy[j] += ystep;
                cw[j] += wstep;
                ch[j] += hstep;
            }
        }
    }
    // The last picture, after the loop.
    _ = p.push(snapshot(&cx, &cy, &cw, &ch));
}

fn grow(b: *Box, x0: i32, y0: i32, x1: i32, y1: i32, first: *bool) void {
    if (first.*) {
        b.* = .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
        first.* = false;
        return;
    }
    const nx0 = @min(b.x, x0);
    const ny0 = @min(b.y, y0);
    const nx1 = @max(b.x + b.w, x1);
    const ny1 = @max(b.y + b.h, y1);
    b.* = .{ .x = nx0, .y = ny0, .w = nx1 - nx0, .h = ny1 - ny0 };
}

/// Room around the lines for their width.
const margin: i32 = 4;

fn computeBounds(p: *Plan) void {
    var b: Box = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
    var first = true;
    for (p.frames[0..p.n]) |f| switch (f) {
        .poly => |pts| for (pts) |pt| grow(&b, pt[0], pt[1], pt[0], pt[1], &first),
        .boxes => |bs| for (bs) |bx| grow(&b, bx[0], bx[1], bx[0] + bx[2], bx[1] + bx[3], &first),
    };
    p.bounds = .{ .x = b.x - margin, .y = b.y - margin, .w = b.w + 2 * margin, .h = b.h + 2 * margin };
}

/// The animation from `from` to `to` (both global boxes).
pub fn plan(style: Style, from: Box, to: Box) Plan {
    var p: Plan = .{
        .style = style,
        .delay_ms = switch (style) {
            .zoom => msOf(zoom_delay_us),
            .twist => msOf(twist_delay_us),
            .flip => msOf(flip_delay_us),
        },
    };
    switch (style) {
        .zoom => zoom(&p, from, to),
        .twist => twist(&p, from, to),
        .flip => flip(&p, from, to),
    }
    computeBounds(&p);
    return p;
}

// ---- drawing ----------------------------------------------------------------------

// Window Maker's `frame_gc` is an XOR/invert line that shows on any
// background. There is no XOR on a Wayland surface: a dark line inside a
// light one is visible on every background too.
const col_halo: gfx.Color = .{ .r = 1, .g = 1, .b = 1, .a = 0.85 };
const col_line: gfx.Color = .{ .r = 0, .g = 0, .b = 0, .a = 0.95 };

fn outline(cv: *gfx.Canvas, pts: []const [2]f64) void {
    cv.strokePath(pts, true, 3, col_halo);
    cv.strokePath(pts, true, 1, col_line);
}

/// Draw one frame on `cv`, whose top left is the global point (ox, oy).
pub fn draw(cv: *gfx.Canvas, f: Frame, ox: i32, oy: i32) void {
    const fox: f64 = @floatFromInt(ox);
    const foy: f64 = @floatFromInt(oy);
    switch (f) {
        .poly => |pts| {
            // The fifth point is the first one again: the path is closed.
            var q: [4][2]f64 = undefined;
            for (0..4) |i| q[i] = .{ @as(f64, @floatFromInt(pts[i][0])) - fox + 0.5, @as(f64, @floatFromInt(pts[i][1])) - foy + 0.5 };
            outline(cv, &q);
        },
        .boxes => |bs| for (bs) |b| {
            // XDrawRectangle(x, y, w, h) covers x .. x + w inclusive.
            const x0: f64 = @as(f64, @floatFromInt(b[0])) - fox + 0.5;
            const y0: f64 = @as(f64, @floatFromInt(b[1])) - foy + 0.5;
            const x1: f64 = x0 + @as(f64, @floatFromInt(b[2]));
            const y1: f64 = y0 + @as(f64, @floatFromInt(b[3]));
            outline(cv, &.{ .{ x0, y0 }, .{ x1, y0 }, .{ x1, y1 }, .{ x0, y1 } });
        },
    }
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

fn near(a: i32, b: i32, tol: i32) bool {
    return @abs(a - b) <= tol;
}

test "delays are Window Maker's MINIATURIZE_ANIMATION_DELAY_* in milliseconds" {
    const b: Box = .{ .x = 0, .y = 0, .w = 100, .h = 50 };
    try std.testing.expectEqual(@as(u32, 10), plan(.zoom, b, b).delay_ms);
    try std.testing.expectEqual(@as(u32, 20), plan(.twist, b, b).delay_ms);
    try std.testing.expectEqual(@as(u32, 20), plan(.flip, b, b).delay_ms);
}

test "zoom: 17 pictures of 7 boxes, the trail starts on the first box and ends on the last" {
    const from: Box = .{ .x = 100, .y = 200, .w = 640, .h = 480 };
    const to: Box = .{ .x = 1856, .y = 64, .w = 64, .h = 64 };
    const p = plan(.zoom, from, to);
    try std.testing.expectEqual(@as(usize, 17), p.n);

    // First picture: all seven boxes are still the first box.
    for (p.frames[0].boxes) |b| try std.testing.expectEqual([4]i32{ 100, 200, 640, 480 }, b);

    // The head of the trail (the last box) is `steps` steps further in the
    // last picture: on the target, up to the float rounding.
    const last = p.frames[16].boxes[6];
    try std.testing.expect(near(last[0], to.x, 1) and near(last[1], to.y, 1));
    try std.testing.expect(near(last[2], to.w, 1) and near(last[3], to.h, 1));

    // Each picture the trail takes one more step: box j of picture i+1 is
    // box j+1 of picture i (that is what the shifting loop does).
    for (0..16) |i| {
        for (0..6) |j| try std.testing.expectEqual(p.frames[i].boxes[j + 1], p.frames[i + 1].boxes[j]);
    }
}

test "twist: half a turn in 13 or 14 pictures; the quadrilateral keeps the box's size" {
    const from: Box = .{ .x = 0, .y = 0, .w = 100, .h = 50 };
    const to: Box = .{ .x = 400, .y = 300, .w = 100, .h = 50 }; // same size: only the turn shows
    const p = plan(.twist, from, to);
    try std.testing.expect(p.n == 13 or p.n == 14);

    // Angle 0: the corners of the box itself, centred at (50, 25).
    const f0 = p.frames[0].poly;
    try std.testing.expect(near(f0[0][0], 100, 1) and near(f0[0][1], 0, 1)); // cx + w/2, cy - h/2
    try std.testing.expect(near(f0[1][0], 100, 1) and near(f0[1][1], 50, 1)); // cx + w/2, cy + h/2
    try std.testing.expect(near(f0[2][0], 0, 1) and near(f0[2][1], 50, 1));
    try std.testing.expect(near(f0[3][0], 0, 1) and near(f0[3][1], 0, 1));
    try std.testing.expectEqual(f0[0], f0[4]); // closed

    // Half a turn (pi): the same four corners, in the opposite order. It has
    // moved by n - 1 of the 16 steps towards the target (the loop stops
    // after the last angle, not after the last step).
    const fl_ = p.frames[p.n - 1].poly;
    const k: i32 = @intCast(p.n - 1);
    const mx = @divTrunc(k * 400, 16);
    const my = @divTrunc(k * 300, 16);
    try std.testing.expect(near(fl_[0][0], 0 + mx, 2) and near(fl_[0][1], 50 + my, 2));
}

test "twist: every picture is a rectangle turned, the diagonals stay as long as the box's" {
    const from: Box = .{ .x = 10, .y = 20, .w = 300, .h = 200 };
    const to: Box = .{ .x = 900, .y = 700, .w = 64, .h = 64 };
    const p = plan(.twist, from, to);
    for (p.frames[0..p.n]) |f| {
        const q = f.poly;
        // Opposite corners are the ends of a diagonal: they share the centre.
        const cx0 = @as(i32, q[0][0]) + @as(i32, q[2][0]);
        const cx1 = @as(i32, q[1][0]) + @as(i32, q[3][0]);
        const cy0 = @as(i32, q[0][1]) + @as(i32, q[2][1]);
        const cy1 = @as(i32, q[1][1]) + @as(i32, q[3][1]);
        try std.testing.expect(near(cx0, cx1, 3) and near(cy0, cy1, 3));
    }
}

test "flip: a card turning over; first picture is the box widened by w/10 at both sides" {
    const from: Box = .{ .x = 0, .y = 0, .w = 100, .h = 50 };
    const to: Box = .{ .x = 200, .y = 0, .w = 100, .h = 50 };
    const p = plan(.flip, from, to);
    try std.testing.expect(p.n == 13 or p.n == 14);
    // angle 0: dx = w/10 - (w/5) * sin 0 = 10, dch = h/2: a trapezoid whose
    // corners stick out by 10 px at the bottom and are pulled in at the top.
    const f0 = p.frames[0].poly;
    try std.testing.expect(near(f0[0][0], 10, 1) and near(f0[0][1], 0, 1));
    try std.testing.expect(near(f0[1][0], 90, 1) and near(f0[1][1], 0, 1));
    try std.testing.expect(near(f0[2][0], 110, 1) and near(f0[2][1], 50, 1));
    try std.testing.expect(near(f0[3][0], -10, 1) and near(f0[3][1], 50, 1));
    // Top and bottom edges are level in every picture.
    for (p.frames[0..p.n]) |f| {
        try std.testing.expectEqual(f.poly[0][1], f.poly[1][1]);
        try std.testing.expectEqual(f.poly[2][1], f.poly[3][1]);
    }
}

test "bounds hold every point of every picture, with room for the line" {
    const cases = [_]Box{
        .{ .x = 50, .y = 60, .w = 800, .h = 600 },
        .{ .x = -30, .y = -40, .w = 200, .h = 100 },
    };
    const to: Box = .{ .x = 1800, .y = 900, .w = 64, .h = 64 };
    for ([_]Style{ .zoom, .twist, .flip }) |style| {
        for (cases) |from| {
            const p = plan(style, from, to);
            for (p.frames[0..p.n]) |f| switch (f) {
                .poly => |pts| for (pts) |pt| {
                    try std.testing.expect(pt[0] - 2 >= p.bounds.x and pt[0] + 2 <= p.bounds.x + p.bounds.w);
                    try std.testing.expect(pt[1] - 2 >= p.bounds.y and pt[1] + 2 <= p.bounds.y + p.bounds.h);
                },
                .boxes => |bs| for (bs) |b| {
                    try std.testing.expect(b[0] - 2 >= p.bounds.x and b[0] + b[2] + 2 <= p.bounds.x + p.bounds.w);
                    try std.testing.expect(b[1] - 2 >= p.bounds.y and b[1] + b[3] + 2 <= p.bounds.y + p.bounds.h);
                },
            };
        }
    }
}

test "degenerate boxes never crash and never overflow the plan" {
    const zero: Box = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
    const big: Box = .{ .x = -100000, .y = 100000, .w = 2_000_000, .h = 2_000_000 };
    for ([_]Style{ .zoom, .twist, .flip }) |style| {
        for ([_]Box{ zero, big }) |a| {
            for ([_]Box{ zero, big }) |b| {
                const p = plan(style, a, b);
                try std.testing.expect(p.n >= 1 and p.n <= max_frames);
                try std.testing.expect(p.durationMs() <= 400);
            }
        }
    }
}

test "durations: zoom 170 ms, twist and flip about 270 ms" {
    const b: Box = .{ .x = 0, .y = 0, .w = 100, .h = 50 };
    try std.testing.expectEqual(@as(u32, 170), plan(.zoom, b, b).durationMs());
    const t = plan(.twist, b, b).durationMs();
    try std.testing.expect(t == 260 or t == 280);
}

test "frame() clamps to the last picture" {
    const b: Box = .{ .x = 0, .y = 0, .w = 100, .h = 50 };
    const p = plan(.twist, b, b);
    try std.testing.expectEqual(p.frames[p.n - 1].poly, p.frame(1000).poly);
    try std.testing.expectEqual(p.frames[0].poly, p.frame(0).poly);
}
