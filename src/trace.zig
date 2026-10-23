// SPDX-License-Identifier: GPL-3.0
//
// A flight recorder: the last `capacity` log lines, kept in a ring in memory.
//
// A log that is filtered to `info` does not show what happened right before a
// problem, and a log at `debug` is too much to leave on. The ring is the
// middle: log.zig hands it every message that is at least `info` (and every
// `debug` one too when WMAKER_TRACE=1 is set), and `pkill -USR1 wmaker-wl`
// writes the last ones next to the state dump (dump.zig).
//
// No allocation, no locking (wmaker-wl is single threaded), a message that
// does not fit is cut. Recording costs one `bufPrint` into a fixed slot.

const std = @import("std");

pub const capacity = 256;
pub const text_len = 160;

pub const Entry = struct {
    /// Counts up from 1; 0 marks a slot that was never used.
    seq: u64 = 0,
    /// Milliseconds on the clock `tick` is fed with (0: not fed yet).
    ms: u64 = 0,
    level: std.log.Level = .info,
    scope: []const u8 = "",
    len: u8 = 0,
    text: [text_len]u8 = undefined,

    pub fn message(e: *const Entry) []const u8 {
        return e.text[0..e.len];
    }
};

var ring: [capacity]Entry = [_]Entry{.{}} ** capacity;
var next_seq: u64 = 1;
var clock_ms: u64 = 0;

/// Record `debug` messages too (WMAKER_TRACE=1). Off: info, warn and err only.
pub var capture_debug = false;

/// Feed the clock the entries are stamped with. The event loop calls it once
/// per manage sequence, so entries of one sequence share a time.
pub fn tick(ms: u64) void {
    clock_ms = ms;
}

/// WMAKER_TRACE=1 turns the recording of `debug` messages on.
pub fn initFromEnv() void {
    const p = std.c.getenv("WMAKER_TRACE") orelse return;
    const v = std.mem.span(p);
    capture_debug = v.len > 0 and !std.mem.eql(u8, v, "0");
}

/// Is a message of this level kept?
pub fn wants(level: std.log.Level) bool {
    return level != .debug or capture_debug;
}

pub fn record(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (!wants(level)) return;
    const slot = &ring[@intCast((next_seq - 1) % capacity)];
    slot.seq = next_seq;
    slot.ms = clock_ms;
    slot.level = level;
    slot.scope = @tagName(scope);
    var w: std.Io.Writer = .fixed(&slot.text);
    w.print(format, args) catch {}; // too long: what fitted stays
    slot.len = @intCast(w.buffered().len);
    next_seq += 1;
}

/// How many entries there are right now.
pub fn count() usize {
    return @intCast(@min(next_seq - 1, capacity));
}

/// Total ever recorded (the ring may hold fewer).
pub fn total() u64 {
    return next_seq - 1;
}

/// The `n`-th entry counting from the oldest one kept (0 = oldest).
pub fn at(n: usize) ?*const Entry {
    const have = count();
    if (n >= have) return null;
    const first_seq = next_seq - have;
    const seq = first_seq + n;
    return &ring[@intCast((seq - 1) % capacity)];
}

pub fn clear() void {
    for (&ring) |*e| e.* = .{};
    next_seq = 1;
}

/// Write the last `max` entries, oldest first.
pub fn dump(w: *std.Io.Writer, max: usize) std.Io.Writer.Error!void {
    const have = count();
    const skip = have -| max;
    try w.print("recent log ({d} of {d} messages kept, {d} shown):\n", .{ have, total(), have - skip });
    var i = skip;
    while (i < have) : (i += 1) {
        const e = at(i).?;
        try w.print("  #{d:<6} {d:>9}ms {s:<5} ({s}) {s}\n", .{ e.seq, e.ms, @tagName(e.level), e.scope, e.message() });
    }
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

test "record keeps level, scope, text and the clock" {
    clear();
    defer clear();
    tick(1234);
    record(.info, .window, "opened {d} windows", .{3});
    try std.testing.expectEqual(@as(usize, 1), count());
    const e = at(0).?;
    try std.testing.expectEqual(@as(u64, 1), e.seq);
    try std.testing.expectEqual(@as(u64, 1234), e.ms);
    try std.testing.expectEqual(std.log.Level.info, e.level);
    try std.testing.expectEqualStrings("window", e.scope);
    try std.testing.expectEqualStrings("opened 3 windows", e.message());
    try std.testing.expect(at(1) == null);
}

test "debug messages are only kept when asked for" {
    clear();
    defer {
        capture_debug = false;
        clear();
    }
    capture_debug = false;
    record(.debug, .anim, "tick", .{});
    try std.testing.expectEqual(@as(usize, 0), count());
    record(.warn, .anim, "w", .{});
    try std.testing.expectEqual(@as(usize, 1), count());
    capture_debug = true;
    record(.debug, .anim, "tick", .{});
    try std.testing.expectEqual(@as(usize, 2), count());
}

test "a message that is too long is cut, not lost and not an overflow" {
    clear();
    defer clear();
    record(.info, .main, "{s}", .{"x" ** (text_len + 50)});
    const e = at(0).?;
    try std.testing.expectEqual(@as(usize, text_len), e.message().len);
    try std.testing.expect(e.message()[0] == 'x');
}

test "the ring forgets the oldest and keeps the order" {
    clear();
    defer clear();
    var i: usize = 0;
    while (i < capacity + 10) : (i += 1) record(.info, .main, "m{d}", .{i});
    try std.testing.expectEqual(@as(usize, capacity), count());
    try std.testing.expectEqual(@as(u64, capacity + 10), total());
    // Oldest kept is message 10, newest is capacity + 9.
    try std.testing.expectEqualStrings("m10", at(0).?.message());
    var buf: [16]u8 = undefined;
    const last = std.fmt.bufPrint(&buf, "m{d}", .{capacity + 9}) catch unreachable;
    try std.testing.expectEqualStrings(last, at(capacity - 1).?.message());
    try std.testing.expect(at(capacity) == null);
    // Sequence numbers rise by one across the wrap.
    try std.testing.expectEqual(at(0).?.seq + 1, at(1).?.seq);
}

test "dump prints the newest entries, oldest of them first" {
    clear();
    defer clear();
    record(.info, .main, "one", .{});
    record(.warn, .ui, "two", .{});
    record(.err, .seat, "three", .{});
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try dump(&w, 2);
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "one") == null);
    const pos_two = std.mem.indexOf(u8, out, "two").?;
    const pos_three = std.mem.indexOf(u8, out, "three").?;
    try std.testing.expect(pos_two < pos_three);
    try std.testing.expect(std.mem.indexOf(u8, out, "(ui)") != null);
}

test "an empty recorder dumps just its header" {
    clear();
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try dump(&w, 10);
    try std.testing.expect(std.mem.startsWith(u8, w.buffered(), "recent log (0 of 0"));
}
