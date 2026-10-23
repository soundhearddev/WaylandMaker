// SPDX-License-Identifier: GPL-3.0
//
// Window animations: spring and easing curves, ported from niri
// (https://github.com/YaLTeR/niri, GPL-3.0-or-later), files
//
//   src/animation/spring.rs   -> `SpringParams`, `Spring`
//   src/animation/mod.rs      -> `Curve`, `Animation`
//   src/animation/clock.rs    -> `Clock`
//   niri-config/src/animations.rs -> the default values and limits in `Spec`
//
// Credits of the originals, as niri names them:
//   * `Spring.duration` / `Spring.oscillate` are based on libadwaita's
//     adw-spring-animation.c (LGPL-2.1-or-later, GNOME), which in turn is based
//     on RBBSpringAnimation.m of robb/RBBAnimation (MIT).
//   * ease-out-quad and ease-out-cubic are the functions of the `keyframe`
//     crate (MIT); ease-out-expo is niri's own `1 - 2^(-10 x)`.
//
// What changed in the port: `std::time::Duration` became milliseconds in an
// `f64` (the clock) and seconds in an `f64` (durations); the `cubic-bezier`
// curve and the `Deceleration` kind were left out because nothing here needs
// them. The arithmetic is otherwise the same, line for line.
//
// No Wayland types in here: unit-testable without a compositor.

const std = @import("std");

const f64_eps = std.math.floatEps(f64);
// niri compares with f32::EPSILON on purpose, "even though it's doubles".
const f32_eps: f64 = std.math.floatEps(f32);

// ---- curves ---------------------------------------------------------------

pub const Curve = enum {
    linear,
    @"ease-out-quad",
    @"ease-out-cubic",
    @"ease-out-expo",

    pub fn y(c: Curve, x: f64) f64 {
        return switch (c) {
            .linear => x,
            .@"ease-out-quad" => -(x * (x - 2.0)),
            .@"ease-out-cubic" => blk: {
                const t = x - 1.0;
                break :blk t * t * t + 1.0;
            },
            .@"ease-out-expo" => 1.0 - std.math.pow(f64, 2.0, -10.0 * x),
        };
    }
};

// ---- spring (spring.rs) -------------------------------------------------------

pub const SpringParams = struct {
    damping: f64,
    mass: f64,
    stiffness: f64,
    epsilon: f64,

    pub fn init(damping_ratio: f64, stiffness: f64, epsilon: f64) SpringParams {
        const dr = @max(damping_ratio, 0.0);
        const st = @max(stiffness, 0.0);
        const ep = @max(epsilon, 0.0);

        const mass = 1.0;
        const critical_damping = 2.0 * @sqrt(mass * st);
        return .{ .damping = dr * critical_damping, .mass = mass, .stiffness = st, .epsilon = ep };
    }
};

pub const Spring = struct {
    from: f64,
    to: f64,
    initial_velocity: f64,
    params: SpringParams,

    /// The position `t` seconds after the start.
    pub fn valueAt(s: Spring, t: f64) f64 {
        return s.oscillate(t);
    }

    /// Seconds until the spring is at rest (infinity: never).
    pub fn duration(s: Spring) f64 {
        const delta = 0.001;

        const beta = s.params.damping / (2.0 * s.params.mass);

        if (@abs(beta) <= f64_eps or beta < 0.0) return std.math.inf(f64);

        if (@abs(s.to - s.from) <= f64_eps) return 0.0;

        const omega0 = @sqrt(s.params.stiffness / s.params.mass);

        // As first ansatz for the overdamped solution, and general estimation
        // for the oscillating ones, take the value of the envelope when it is
        // < epsilon.
        var x0 = -@log(s.params.epsilon) / beta;

        if (@abs(beta - omega0) <= f32_eps or beta < omega0) return @max(x0, 0.0);

        // The overdamped solution decays far slower than the envelope, so the
        // value of the oscillation itself is used: Newton's root finding.
        var y0 = s.oscillate(x0);
        var m = (s.oscillate(x0 + delta) - y0) / delta;

        var x1 = (s.to - y0 + m * x0) / m;
        var y1 = s.oscillate(x1);

        var i: u32 = 0;
        while (@abs(s.to - y1) > s.params.epsilon) {
            if (i > 1000) return 0.0;

            x0 = x1;
            y0 = y1;

            m = (s.oscillate(x0 + delta) - y0) / delta;

            x1 = (s.to - y0 + m * x0) / m;
            y1 = s.oscillate(x1);

            // Overdamped springs have some numerical stability issues.
            if (!std.math.isFinite(y1)) return @max(x0, 0.0);

            i += 1;
        }

        return @max(x1, 0.0);
    }

    /// Seconds until the spring first reaches its target (null: not within 3 s).
    pub fn clampedDuration(s: Spring) ?f64 {
        const beta = s.params.damping / (2.0 * s.params.mass);

        if (@abs(beta) <= f64_eps or beta < 0.0) return std.math.inf(f64);

        if (@abs(s.to - s.from) <= f64_eps) return 0.0;

        // The first frame is not that important and it avoids finding the
        // trivial 0 for in-place animations.
        var i: u32 = 1;
        var v = s.oscillate(@as(f64, @floatFromInt(i)) / 1000.0);

        while ((s.to - s.from > f64_eps and s.to - v > s.params.epsilon) or
            (s.from - s.to > f64_eps and v - s.to > s.params.epsilon))
        {
            if (i > 3000) return null;

            i += 1;
            v = s.oscillate(@as(f64, @floatFromInt(i)) / 1000.0);
        }

        return @as(f64, @floatFromInt(i)) / 1000.0;
    }

    /// The position at `t` seconds.
    fn oscillate(s: Spring, t: f64) f64 {
        const b = s.params.damping;
        const m = s.params.mass;
        const k = s.params.stiffness;
        const v0 = s.initial_velocity;

        const beta = b / (2.0 * m);
        const omega0 = @sqrt(k / m);

        const x0 = s.from - s.to;

        const envelope = @exp(-beta * t);

        // Solutions of the form C1*e^(lambda1*x) + C2*e^(lambda2*x) for the
        // differential equation m*x'' + b*x' + k*x = 0.
        if (@abs(beta - omega0) <= f32_eps) {
            // Critically damped.
            return s.to + envelope * (x0 + (beta * x0 + v0) * t);
        } else if (beta < omega0) {
            // Underdamped.
            const omega1 = @sqrt((omega0 * omega0) - (beta * beta));
            return s.to + envelope * (x0 * @cos(omega1 * t) + ((beta * x0 + v0) / omega1) * @sin(omega1 * t));
        } else {
            // Overdamped.
            const omega2 = @sqrt((beta * beta) - (omega0 * omega0));
            return s.to + envelope * (x0 * std.math.cosh(omega2 * t) + ((beta * x0 + v0) / omega2) * std.math.sinh(omega2 * t));
        }
    }
};

// ---- the settings (niri-config/animations.rs) -----------------------------------

pub const SpringSpec = struct { damping_ratio: f64, stiffness: f64, epsilon: f64 };
pub const EasingSpec = struct { curve: Curve, duration_ms: u32 };

/// How one kind of animation runs: off, a spring or an easing curve.
pub const Spec = union(enum) {
    off,
    spring: SpringSpec,
    easing: EasingSpec,

    /// niri's default for window movement, resize and the horizontal view.
    pub const default_movement: Spec = .{ .spring = .{ .damping_ratio = 1.0, .stiffness = 800.0, .epsilon = 0.0001 } };
    /// A window that opens. niri uses `ease-out-expo 150`, which shows about
    /// half of the window in the very first frame and is over after five: it
    /// looks like a pop. A cubic over 250 ms starts gently and ends about when
    /// the spring of the windows making room for it settles (~0.33 s).
    pub const default_open: Spec = .{ .easing = .{ .curve = .@"ease-out-cubic", .duration_ms = 250 } };

    // niri's limits (niri-config/src/animations.rs).
    pub const max_duration_ms: u32 = 60_000;

    /// "off", "spring DAMPING_RATIO STIFFNESS EPSILON" or "CURVE DURATION_MS"
    /// (curve: linear, ease-out-quad, ease-out-cubic, ease-out-expo).
    /// null: not valid, with niri's limits (damping ratio 0.1 .. 10,
    /// stiffness >= 1, epsilon 0.00001 .. 0.1).
    pub fn parse(text: []const u8) ?Spec {
        var it = std.mem.tokenizeAny(u8, text, " \t");
        const first = it.next() orelse return null;

        if (std.mem.eql(u8, first, "off")) {
            if (it.next() != null) return null;
            return .off;
        }

        if (std.mem.eql(u8, first, "spring")) {
            const dr = std.fmt.parseFloat(f64, it.next() orelse return null) catch return null;
            const st = std.fmt.parseFloat(f64, it.next() orelse return null) catch return null;
            const ep = std.fmt.parseFloat(f64, it.next() orelse return null) catch return null;
            if (it.next() != null) return null;
            if (!(dr >= 0.1 and dr <= 10.0)) return null;
            if (!(st >= 1.0 and st <= 1.0e6)) return null;
            if (!(ep >= 0.00001 and ep <= 0.1)) return null;
            return .{ .spring = .{ .damping_ratio = dr, .stiffness = st, .epsilon = ep } };
        }

        const curve = std.meta.stringToEnum(Curve, first) orelse return null;
        const ms = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
        if (it.next() != null) return null;
        if (ms == 0 or ms > max_duration_ms) return null;
        return .{ .easing = .{ .curve = curve, .duration_ms = ms } };
    }

    /// The text `parse` reads back.
    pub fn format(s: Spec, buf: []u8) []const u8 {
        return (switch (s) {
            .off => std.fmt.bufPrint(buf, "off", .{}),
            .spring => |p| std.fmt.bufPrint(buf, "spring {d} {d} {d}", .{ p.damping_ratio, p.stiffness, p.epsilon }),
            .easing => |p| std.fmt.bufPrint(buf, "{s} {d}", .{ @tagName(p.curve), p.duration_ms }),
        }) catch "off";
    }

    pub fn isOff(s: Spec) bool {
        return s == .off;
    }
};

// ---- clock (clock.rs) -------------------------------------------------------------

/// Time for the animations. Like niri's, it is read once per manage/render
/// sequence (`advance`), so everything animated in one sequence sees the same
/// moment, and it has a rate: `slowdown` 2 runs everything half as fast.
pub const Clock = struct {
    /// Milliseconds, adjusted for the rate.
    current: f64 = 0,
    last_seen: ?u64 = null,
    rate: f64 = 1.0,

    pub fn setSlowdown(c: *Clock, slowdown: f64) void {
        const r = if (slowdown <= 0.001) 1000.0 else 1.0 / slowdown;
        c.rate = std.math.clamp(r, 0.0, 1000.0);
    }

    /// Feed it the real time, in milliseconds on a clock that only goes forward.
    pub fn advance(c: *Clock, real_ms: u64) void {
        const last = c.last_seen orelse {
            c.last_seen = real_ms;
            return;
        };
        if (real_ms > last) {
            c.current += @as(f64, @floatFromInt(real_ms - last)) * c.rate;
        } else if (real_ms < last) {
            c.current = @max(0.0, c.current - @as(f64, @floatFromInt(last - real_ms)) * c.rate);
        }
        c.last_seen = real_ms;
    }

    pub fn now(c: *const Clock) f64 {
        return c.current;
    }
};

// ---- the animation (mod.rs) ------------------------------------------------------------

pub const Animation = struct {
    from: f64,
    to: f64,
    initial_velocity: f64,
    /// Seconds.
    duration: f64,
    start: f64,
    kind: Kind,

    const Kind = union(enum) { easing: Curve, spring: Spring };

    /// From `from` to `to`, starting at `now` (clock milliseconds). null for
    /// `.off`: nothing to animate.
    pub fn init(spec: Spec, from: f64, to: f64, initial_velocity: f64, now: f64) ?Animation {
        switch (spec) {
            .off => return null,
            .spring => |p| {
                const spring: Spring = .{
                    .from = from,
                    .to = to,
                    .initial_velocity = initial_velocity,
                    .params = SpringParams.init(p.damping_ratio, p.stiffness, p.epsilon),
                };
                return .{
                    .from = from,
                    .to = to,
                    .initial_velocity = initial_velocity,
                    .duration = spring.duration(),
                    .start = now,
                    .kind = .{ .spring = spring },
                };
            },
            .easing => |p| return .{
                .from = from,
                .to = to,
                .initial_velocity = initial_velocity,
                .duration = @as(f64, @floatFromInt(p.duration_ms)) / 1000.0,
                .start = now,
                .kind = .{ .easing = p.curve },
            },
        }
    }

    pub fn isDone(a: *const Animation, now: f64) bool {
        return now >= a.start + a.duration * 1000.0;
    }

    pub fn valueAt(a: *const Animation, at: f64) f64 {
        if (at <= a.start) {
            return a.from;
        } else if (a.start + a.duration * 1000.0 <= at) {
            return a.to;
        }

        const passed = (at - a.start) / 1000.0;

        switch (a.kind) {
            .easing => |curve| {
                const x = std.math.clamp(passed / a.duration, 0.0, 1.0);
                return curve.y(x) * (a.to - a.from) + a.from;
            },
            .spring => |spring| {
                const value = spring.valueAt(passed);

                const range = (a.to - a.from) * 10.0;
                const lo = a.from - range;
                const hi = a.to + range;
                if (a.from <= a.to) {
                    return std.math.clamp(value, lo, hi);
                } else {
                    return std.math.clamp(value, hi, lo);
                }
            },
        }
    }
};

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

fn near(a: f64, b: f64, tol: f64) bool {
    return @abs(a - b) <= tol;
}

test "curves start at 0, end at 1" {
    inline for (@typeInfo(Curve).@"enum".fields) |f| {
        const c: Curve = @enumFromInt(f.value);
        try std.testing.expect(near(c.y(0.0), 0.0, 0.001));
        try std.testing.expect(near(c.y(1.0), 1.0, 0.001));
    }
    try std.testing.expect(near(Curve.@"ease-out-quad".y(0.5), 0.75, 1e-12));
    try std.testing.expect(near(Curve.@"ease-out-cubic".y(0.5), 0.875, 1e-12));
    // Out curves are ahead of the straight line.
    try std.testing.expect(Curve.@"ease-out-expo".y(0.25) > 0.5);
}

test "niri's default movement spring: critically damped, no overshoot, about 0.3 s" {
    const s: Spring = .{ .from = 0, .to = 100, .initial_velocity = 0, .params = SpringParams.init(1.0, 800.0, 0.0001) };
    const d = s.duration();
    try std.testing.expect(d > 0.1 and d < 0.6);

    var t: f64 = 0;
    var prev: f64 = -1;
    while (t <= d) : (t += 0.001) {
        const v = s.valueAt(t);
        try std.testing.expect(v >= prev - 1e-9); // monotonic
        try std.testing.expect(v <= 100.0 + 1e-9); // never past the target
        prev = v;
    }
    // epsilon is the size of the envelope, so over a distance of 100 the rest
    // is a few times 100 * epsilon.
    try std.testing.expect(near(s.valueAt(d), 100.0, 0.5));
    try std.testing.expect(near(s.valueAt(0), 0.0, 1e-12));
    // The first moment it is within epsilon of the target (not of the envelope).
    try std.testing.expect(s.clampedDuration().? > d and s.clampedDuration().? < 3.0);
}

test "underdamped springs overshoot and settle" {
    const s: Spring = .{ .from = 0, .to = 1, .initial_velocity = 0, .params = SpringParams.init(0.6, 1000.0, 0.001) };
    var peak: f64 = 0;
    var t: f64 = 0;
    while (t < s.duration()) : (t += 0.001) peak = @max(peak, s.valueAt(t));
    try std.testing.expect(peak > 1.0);
    try std.testing.expect(near(s.valueAt(s.duration()), 1.0, 0.002));
}

test "overdamped springs: no NaN, no crash (niri's two regression tests)" {
    const a: Spring = .{ .from = 0, .to = 0, .initial_velocity = 0, .params = SpringParams.init(1.15, 850.0, 0.0001) };
    _ = a.duration();
    _ = a.clampedDuration();
    _ = a.valueAt(0);

    const b: Spring = .{ .from = 0, .to = 1, .initial_velocity = 0, .params = SpringParams.init(6.0, 1200.0, 0.0001) };
    try std.testing.expect(std.math.isFinite(b.duration()));
    _ = b.clampedDuration();
    try std.testing.expect(near(b.valueAt(b.duration()), 1.0, 0.01));
}

test "Animation: easing runs for its duration, spring from -> to" {
    const open = Animation.init(Spec.default_open, 0, 1, 0, 1000).?;
    try std.testing.expect(near(open.duration, 0.250, 1e-12));
    try std.testing.expectEqual(@as(f64, 0), open.valueAt(900)); // before the start
    try std.testing.expect(open.valueAt(1125) > 0.5); // ease-out-cubic is fast at first ...
    try std.testing.expect(open.valueAt(1016) < 0.25); // ... but the first 16 ms frame is no jump
    try std.testing.expectEqual(@as(f64, 1), open.valueAt(1250));
    try std.testing.expect(!open.isDone(1249));
    try std.testing.expect(open.isDone(1250));

    const mv = Animation.init(Spec.default_movement, 500, 100, 0, 0).?; // downwards: from > to
    try std.testing.expectEqual(@as(f64, 500), mv.valueAt(0));
    const mid = mv.valueAt(100);
    try std.testing.expect(mid < 500 and mid > 100);
    try std.testing.expectEqual(@as(f64, 100), mv.valueAt(mv.duration * 1000.0 + 1));

    try std.testing.expectEqual(@as(?Animation, null), Animation.init(.off, 0, 1, 0, 0));
}

test "Clock: one reading per sequence, slowdown halves the speed" {
    var c: Clock = .{};
    c.advance(10_000);
    try std.testing.expectEqual(@as(f64, 0), c.now());
    c.advance(10_100);
    try std.testing.expectEqual(@as(f64, 100), c.now());
    c.advance(10_100); // same reading
    try std.testing.expectEqual(@as(f64, 100), c.now());

    c.setSlowdown(2.0);
    c.advance(10_300);
    try std.testing.expectEqual(@as(f64, 200), c.now()); // 200 real ms = 100 of animation
}

test "Spec: parse / format round trip and niri's limits" {
    var buf: [64]u8 = undefined;
    for ([_][]const u8{ "off", "spring 1 800 0.0001", "spring 0.6 1000 0.001", "ease-out-expo 150", "ease-out-quad 150", "linear 200" }) |txt| {
        const s = Spec.parse(txt).?;
        try std.testing.expectEqualStrings(txt, s.format(&buf));
    }
    try std.testing.expectEqual(Spec.default_movement, Spec.parse("spring 1.0 800 0.0001").?);
    try std.testing.expectEqual(Spec.default_open, Spec.parse("  ease-out-cubic   250 ").?);

    for ([_][]const u8{
        "",                       "spring",               "spring 1 800",        "spring 1 800 0.0001 9",
        "spring 0.05 800 0.0001", "spring 11 800 0.0001", "spring 1 0.5 0.0001", "spring 1 800 0.000001",
        "spring 1 800 0.5",       "ease-out-expo",        "ease-out-expo 0",     "ease-out-expo -5",
        "ease-in 150",            "ease-out-expo 150 1",  "off 1",               "spring a b c",
        "ease-out-expo 99999999",
    }) |txt| try std.testing.expectEqual(@as(?Spec, null), Spec.parse(txt));
}
