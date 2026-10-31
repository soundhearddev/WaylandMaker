// SPDX-License-Identifier: GPL-3.0
//
// Measuring where the time goes.
//
// The window manager does its work in short bursts (one manage and one render
// sequence per change, one per animation frame), and what the user feels is
// the slowest of them. A mean hides that, so every probe keeps a count, the
// total, the last and the worst value and a log2 histogram from which the
// median and the 95th / 99th percentile are read.
//
//     const span = perf.start(io, .manage);
//     defer perf.stop(io, span);
//
// `perf.report` prints the table (`pkill -USR1 wmaker-wl`, and `zig build
// bench`, which uses the same code to time the model on synthetic loads).
// A pass over `slow_ns` is logged once per second at most, as `warn(perf)`,
// so a stutter shows up in the log without turning debug logging on.

const std = @import("std");
const log = std.log.scoped(.perf);

pub const Probe = enum {
    /// A whole manage pass (Server.runManage): model, config, Dock.
    manage,
    /// layout.compute for all outputs. Not measured at the moment
    /// (manage.run runs in tests without a usable `io`); `manage` includes it.
    layout,
    /// What the scene needs to draw one frame of one output
    /// (`Monitor.onFrame`: wlr_scene_output_commit).
    render,
    /// invariants.check (only with WMAKER_CHECKS=1).
    checks,
    /// Monitor settling: identity, profile, windows moved.
    monitors,
};

pub const probe_count = @typeInfo(Probe).@"enum".fields.len;

/// log2 buckets of microseconds: bucket i holds [2^i, 2^(i+1)) µs, bucket 0
/// also everything below 1 µs, the last one everything above.
pub const buckets = 24;

pub const Stat = struct {
    count: u64 = 0,
    total_ns: u64 = 0,
    max_ns: u64 = 0,
    last_ns: u64 = 0,
    hist: [buckets]u32 = [_]u32{0} ** buckets,

    pub fn record(s: *Stat, ns: u64) void {
        s.count +%= 1;
        s.total_ns +%= ns;
        s.last_ns = ns;
        if (ns > s.max_ns) s.max_ns = ns;
        s.hist[bucketOf(ns)] +|= 1;
    }

    pub fn meanNs(s: *const Stat) u64 {
        return if (s.count == 0) 0 else s.total_ns / s.count;
    }

    /// The value (ns) that `p` percent of the samples stay at or below,
    /// rounded UP to the top of its histogram bucket and never above the
    /// largest sample seen. 0 without samples.
    pub fn percentileNs(s: *const Stat, p: u8) u64 {
        if (s.count == 0) return 0;
        const want: u64 = @max(1, (s.count * @min(p, 100) + 99) / 100);
        var seen: u64 = 0;
        for (s.hist, 0..) |n, i| {
            seen += n;
            if (seen >= want) return @min(bucketTopNs(i), s.max_ns);
        }
        return s.max_ns;
    }

    pub fn reset(s: *Stat) void {
        s.* = .{};
    }
};

pub fn bucketOf(ns: u64) usize {
    const micros = ns / 1000;
    if (micros == 0) return 0;
    const b: usize = std.math.log2_int(u64, micros);
    return @min(b, buckets - 1);
}

/// Upper edge of bucket `i` in ns.
pub fn bucketTopNs(i: usize) u64 {
    if (i >= buckets - 1) return std.math.maxInt(u64);
    return (@as(u64, 2) << @intCast(i)) * 1000;
}

var stats: [probe_count]Stat = [_]Stat{.{}} ** probe_count;

/// A pass that takes longer than this is a stutter worth a warning. The
/// budget for a 60 Hz frame is 16 ms, and the manage sequence is only a part
/// of it.
pub var slow_ns: u64 = 8 * std.time.ns_per_ms;

/// At most one slow-pass warning per this many ns.
const warn_every_ns: u64 = std.time.ns_per_s;
var last_warn_ns: u64 = 0;
var warned_once = false;
/// How many passes were over `slow_ns`, warned about or not.
pub var slow_passes: u64 = 0;

pub fn stat(p: Probe) *Stat {
    return &stats[@intFromEnum(p)];
}

pub fn resetAll() void {
    for (&stats) |*s| s.reset();
    slow_passes = 0;
    warned_once = false;
    last_warn_ns = 0;
}

/// Record a measured duration for `p` (also what tests and the benchmark
/// feed in). A manage pass over `slow_ns` is reported.
pub fn record(p: Probe, ns: u64, now_ns: u64) void {
    stat(p).record(ns);
    if (p == .manage and ns > slow_ns) {
        slow_passes +%= 1;
        if (!warned_once or now_ns -| last_warn_ns >= warn_every_ns) {
            warned_once = true;
            last_warn_ns = now_ns;
            log.warn("a manage sequence took {d:.1} ms (more than {d:.1} ms; {d} so far)", .{
                nsToMs(ns), nsToMs(slow_ns), slow_passes,
            });
        }
    }
}

fn nsToMs(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / @as(f64, std.time.ns_per_ms);
}

pub fn nowNs(io: std.Io) u64 {
    const ts = std.Io.Clock.awake.now(io);
    return @intCast(@max(0, ts.toNanoseconds()));
}

pub const Span = struct { probe: Probe, start_ns: u64 };

pub fn start(io: std.Io, p: Probe) Span {
    return .{ .probe = p, .start_ns = nowNs(io) };
}

/// End a span; returns its length in ns.
pub fn stop(io: std.Io, span: Span) u64 {
    const now = nowNs(io);
    const ns = now -| span.start_ns;
    record(span.probe, ns, now);
    return ns;
}

/// The table of every probe that has samples.
pub fn report(w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeAll("perf (ms):\n");
    try w.print("  {s:<9} {s:>8} {s:>9} {s:>9} {s:>9} {s:>9} {s:>9}\n", .{ "probe", "count", "mean", "p50", "p95", "p99", "max" });
    var any = false;
    inline for (@typeInfo(Probe).@"enum".fields, 0..) |f, i| {
        const s = &stats[i];
        if (s.count > 0) {
            any = true;
            try w.print("  {s:<9} {d:>8} {d:>9.3} {d:>9.3} {d:>9.3} {d:>9.3} {d:>9.3}\n", .{
                f.name,
                s.count,
                nsToMs(s.meanNs()),
                nsToMs(s.percentileNs(50)),
                nsToMs(s.percentileNs(95)),
                nsToMs(s.percentileNs(99)),
                nsToMs(s.max_ns),
            });
        }
    }
    if (!any) try w.writeAll("  (nothing measured yet)\n");
    if (slow_passes > 0) try w.print("  {d} manage sequence(s) took longer than {d:.1} ms\n", .{ slow_passes, nsToMs(slow_ns) });
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

const us = std.time.ns_per_us;
const ms = std.time.ns_per_ms;

test "bucketOf: microsecond powers of two" {
    try std.testing.expectEqual(@as(usize, 0), bucketOf(0));
    try std.testing.expectEqual(@as(usize, 0), bucketOf(999));
    try std.testing.expectEqual(@as(usize, 0), bucketOf(1 * us));
    try std.testing.expectEqual(@as(usize, 1), bucketOf(2 * us));
    try std.testing.expectEqual(@as(usize, 1), bucketOf(3 * us));
    try std.testing.expectEqual(@as(usize, 2), bucketOf(4 * us));
    try std.testing.expectEqual(@as(usize, 9), bucketOf(1 * ms)); // 1000 µs: 512..1023
    try std.testing.expectEqual(@as(usize, buckets - 1), bucketOf(std.math.maxInt(u64)));
}

test "bucketTopNs is the edge of the next bucket" {
    try std.testing.expectEqual(@as(u64, 2 * us), bucketTopNs(0));
    try std.testing.expectEqual(@as(u64, 4 * us), bucketTopNs(1));
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), bucketTopNs(buckets - 1));
    // A value is always below the top of its own bucket.
    for ([_]u64{ 0, 500, 1500, 7 * us, 3 * ms, 900 * ms }) |v| {
        try std.testing.expect(v < bucketTopNs(bucketOf(v)) or bucketOf(v) == buckets - 1);
    }
}

test "Stat: count, total, mean, last and max" {
    var s: Stat = .{};
    try std.testing.expectEqual(@as(u64, 0), s.meanNs());
    s.record(10 * us);
    s.record(30 * us);
    s.record(20 * us);
    try std.testing.expectEqual(@as(u64, 3), s.count);
    try std.testing.expectEqual(@as(u64, 60 * us), s.total_ns);
    try std.testing.expectEqual(@as(u64, 20 * us), s.meanNs());
    try std.testing.expectEqual(@as(u64, 20 * us), s.last_ns);
    try std.testing.expectEqual(@as(u64, 30 * us), s.max_ns);
}

test "Stat.percentileNs: a stutter shows in p99 and max, not in the median" {
    var s: Stat = .{};
    var i: usize = 0;
    while (i < 98) : (i += 1) s.record(100 * us);
    s.record(50 * ms);
    s.record(50 * ms);
    try std.testing.expect(s.percentileNs(50) <= 256 * us);
    try std.testing.expect(s.percentileNs(50) >= 100 * us);
    // 2 of 100 samples are slow: p99 reaches them, p95 does not.
    try std.testing.expect(s.percentileNs(95) <= 256 * us);
    try std.testing.expect(s.percentileNs(99) >= 32 * ms);
    // Never above the largest sample.
    try std.testing.expect(s.percentileNs(100) <= s.max_ns);
    try std.testing.expectEqual(@as(u64, 50 * ms), s.max_ns);
}

test "Stat.percentileNs: no samples is 0, one sample is that sample's bucket capped at max" {
    var s: Stat = .{};
    try std.testing.expectEqual(@as(u64, 0), s.percentileNs(99));
    s.record(5 * us);
    try std.testing.expectEqual(@as(u64, 5 * us), s.percentileNs(50));
    try std.testing.expectEqual(@as(u64, 5 * us), s.percentileNs(99));
}

test "record: a slow manage pass is counted, others are not" {
    resetAll();
    defer resetAll();
    record(.manage, 1 * ms, 1);
    try std.testing.expectEqual(@as(u64, 0), slow_passes);
    record(.manage, 20 * ms, 2);
    try std.testing.expectEqual(@as(u64, 1), slow_passes);
    // Only the manage probe is a stutter alarm.
    record(.layout, 500 * ms, 3);
    try std.testing.expectEqual(@as(u64, 1), slow_passes);
    try std.testing.expectEqual(@as(u64, 2), stat(.manage).count);
    try std.testing.expectEqual(@as(u64, 1), stat(.layout).count);
}

test "record: slow passes are all counted even when the warning is rate limited" {
    resetAll();
    defer resetAll();
    var i: u64 = 0;
    while (i < 5) : (i += 1) record(.manage, 20 * ms, 1000 + i);
    try std.testing.expectEqual(@as(u64, 5), slow_passes);
}

test "start/stop measure real time into the probe" {
    resetAll();
    defer resetAll();
    const sp = start(std.testing.io, .layout);
    const ns = stop(std.testing.io, sp);
    try std.testing.expectEqual(@as(u64, 1), stat(.layout).count);
    try std.testing.expectEqual(ns, stat(.layout).last_ns);
}

test "report: empty, and with a probe" {
    resetAll();
    defer resetAll();
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try report(&w);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "nothing measured") != null);

    record(.layout, 250 * us, 1);
    var w2: std.Io.Writer = .fixed(&buf);
    try report(&w2);
    const out = w2.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "layout") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "manage") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "p99") != null);
}
