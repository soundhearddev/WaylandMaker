// SPDX-License-Identifier: GPL-3.0
//
// External-monitor management: the part that needs no Wayland.
//
// What river gives a window manager about an output is little: a position, a
// size and the global name of the matching `wl_output`. Everything that makes
// a monitor *recognisable* (connector name, make, model) comes from that
// `wl_output` (output.zig binds it). This file turns that into decisions:
//
//   * `Info`      who a monitor is (fixed buffers, no allocation, copyable).
//   * `Rule`      what the user wants for the monitors that match a pattern
//                 (`monitor("DP-1", { ... })` in config.lua): on/off, primary,
//                 workspace count, first workspace, commands on connect.
//   * `Profile`   what to run when a certain SET of monitors is connected
//                 (`monitor_profile{ ... }`): the hook for tools that really
//                 configure outputs (kanshi, wlr-randr). river does not let a
//                 window manager change modes or positions, so this is how
//                 "plug it in and it is set up" is reached.
//   * `Settle`    hot-plugging announces monitors one after the other; a
//                 change only counts once nothing happened for a while.
//   * `Home`      a window remembers the monitor it was taken from when that
//                 monitor went away, and goes back when it comes back.
//   * `order`, `neighbor`: geometry (left to right, "the monitor to the left").
//
// Everything here is a plain function of plain values, so the whole policy is
// unit-tested without a compositor (see the tests at the end).

const std = @import("std");

/// Upper bounds (the data lives in fixed arrays; types.cycleOutput uses 16).
pub const max_monitors = 16;
pub const max_rules = 32;
pub const max_profiles = 16;
pub const max_needs = 8;
pub const max_text = 96;

// ----------------------------------------------------------------------------
// Identity
// ----------------------------------------------------------------------------

/// A short string in a fixed buffer, so `Info` can sit inside `Output`.
pub const Text = struct {
    buf: [max_text]u8 = undefined,
    len: u8 = 0,

    pub fn set(t: *Text, s: []const u8) void {
        const n = @min(s.len, max_text);
        @memcpy(t.buf[0..n], s[0..n]);
        t.len = @intCast(n);
    }

    pub fn get(t: *const Text) []const u8 {
        return t.buf[0..t.len];
    }

    pub fn isEmpty(t: *const Text) bool {
        return t.len == 0;
    }
};

/// What is known about one monitor. Fields arrive at different times (the
/// `wl_output` events: `name`, `description`, `geometry`, `scale`), any of them
/// may stay empty (`name` and `description` need wl_output v4).
pub const Info = struct {
    /// Global name of the `wl_output` (what river's `wl_output` event carries);
    /// 0: not known yet.
    global: u32 = 0,
    name: Text = .{}, // connector: "DP-1", "eDP-1", "HDMI-A-2"
    make: Text = .{},
    model: Text = .{},
    description: Text = .{},
    scale: i32 = 1,
    /// The `wl_output.done` event came: the fields above are complete.
    complete: bool = false,

    /// Anything that tells monitors apart is known.
    pub fn identified(i: *const Info) bool {
        return !i.name.isEmpty() or !i.model.isEmpty() or !i.description.isEmpty();
    }

    /// "Dell Inc. DELL U2720Q (DP-1)", for logs and dumps.
    pub fn label(i: *const Info, buf: []u8) []const u8 {
        var w: std.Io.Writer = .fixed(buf);
        const any = i.writeLabel(&w) catch false;
        if (!any) return "(unidentified)";
        return w.buffered();
    }

    fn writeLabel(i: *const Info, w: *std.Io.Writer) std.Io.Writer.Error!bool {
        var any = false;
        if (!i.make.isEmpty()) {
            try w.writeAll(i.make.get());
            any = true;
        }
        if (!i.model.isEmpty()) {
            if (any) try w.writeByte(' ');
            try w.writeAll(i.model.get());
            any = true;
        }
        if (!i.name.isEmpty()) {
            if (any) try w.writeAll(" (") else try w.writeByte('(');
            try w.writeAll(i.name.get());
            try w.writeByte(')');
            any = true;
        }
        if (!any and !i.description.isEmpty()) {
            try w.writeAll(i.description.get());
            any = true;
        }
        return any;
    }

    /// Stable identity of this monitor on this port, case-insensitive: the
    /// same monitor on the same connector gives the same value after a
    /// reconnect or a restart. 0 means "cannot tell" (nothing is known).
    pub fn key(i: *const Info) u64 {
        if (!i.identified()) return 0;
        var h = std.hash.Wyhash.init(0x6d6f6e69);
        hashLower(&h, i.make.get());
        h.update("|");
        hashLower(&h, i.model.get());
        h.update("|");
        hashLower(&h, i.name.get());
        if (i.make.isEmpty() and i.model.isEmpty() and i.name.isEmpty()) {
            h.update("|");
            hashLower(&h, i.description.get());
        }
        const v = h.final();
        return if (v == 0) 1 else v;
    }
};

fn hashLower(h: *std.hash.Wyhash, s: []const u8) void {
    for (s) |c| h.update(&.{std.ascii.toLower(c)});
}

/// Case-insensitive "needle occurs in haystack"; an empty needle never does.
pub fn containsNoCase(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > hay.len) return false;
    return std.ascii.indexOfIgnoreCase(hay, needle) != null;
}

// ----------------------------------------------------------------------------
// Patterns
// ----------------------------------------------------------------------------

/// How well a pattern matches a monitor. Higher is more specific; 0 = no.
///
///   4  the connector name, exactly (`DP-1`, case-insensitive)
///   3  "make model" or the model, exactly
///   2  the pattern occurs in the description or in "make model"
///   1  `*`, which matches every monitor
pub fn matchScore(pattern: []const u8, info: *const Info) u8 {
    const p = std.mem.trim(u8, pattern, " \t");
    if (p.len == 0) return 0;
    if (std.mem.eql(u8, p, "*")) return 1;
    const eql = std.ascii.eqlIgnoreCase;
    if (!info.name.isEmpty() and eql(p, info.name.get())) return 4;
    if (!info.model.isEmpty() and eql(p, info.model.get())) return 3;
    var buf: [2 * max_text + 1]u8 = undefined;
    const mm = std.fmt.bufPrint(&buf, "{s} {s}", .{ info.make.get(), info.model.get() }) catch "";
    if (mm.len > 1 and eql(p, std.mem.trim(u8, mm, " "))) return 3;
    if (containsNoCase(info.description.get(), p)) return 2;
    if (containsNoCase(mm, p)) return 2;
    return 0;
}

// ----------------------------------------------------------------------------
// Rules
// ----------------------------------------------------------------------------

/// What the user wants for the monitors a pattern matches. Optional fields
/// that are null leave the global setting alone.
pub const Rule = struct {
    match: []const u8,
    /// false: the monitor is ignored (no windows, no layout), like a screen
    /// that is not there. Its windows move to the other monitors.
    enabled: bool = true,
    /// New windows, the Dock and the Clip go here (when it is connected).
    primary: bool = false,
    /// Number of workspaces on this monitor (default: `workspace_count`).
    workspaces: ?u32 = null,
    /// Workspace shown when the monitor appears (1-based in config.lua, 0-based here).
    start_workspace: ?u32 = null,
    /// Windows that were taken off this monitor when it went away come back
    /// when it returns (default on).
    restore_windows: bool = true,
    /// Started when the monitor appears / goes away (argv, run detached).
    on_connect: []const []const u8 = &.{},
    on_disconnect: []const []const u8 = &.{},
};

/// The rule for `info`: the most specific pattern wins, among equals the one
/// written last (so a later line overrides an earlier one). null: no rule.
pub fn findRule(rules: []const Rule, info: *const Info) ?*const Rule {
    var best: ?*const Rule = null;
    var best_score: u8 = 0;
    for (rules) |*r| {
        const s = matchScore(r.match, info);
        if (s != 0 and s >= best_score) {
            best = r;
            best_score = s;
        }
    }
    return best;
}

/// The settings that apply to a monitor, with the defaults filled in.
pub const Effective = struct {
    enabled: bool = true,
    primary: bool = false,
    workspaces: u32,
    start_workspace: u32 = 0,
    restore_windows: bool = true,
    rule: ?*const Rule = null,
};

pub fn effective(rules: []const Rule, info: *const Info, default_workspaces: u32) Effective {
    const r = findRule(rules, info) orelse return .{ .workspaces = default_workspaces };
    return .{
        .enabled = r.enabled,
        .primary = r.primary,
        .workspaces = r.workspaces orelse default_workspaces,
        .start_workspace = r.start_workspace orelse 0,
        .restore_windows = r.restore_windows,
        .rule = r,
    };
}

// ----------------------------------------------------------------------------
// Profiles
// ----------------------------------------------------------------------------

/// "When exactly these monitors are connected, run this."
pub const Profile = struct {
    name: []const u8,
    /// One pattern per monitor that must be present; every monitor satisfies
    /// at most one pattern.
    needs: []const []const u8,
    /// true: no further monitor may be connected.
    exact: bool = false,
    run: []const []const u8 = &.{},
};

/// Can every pattern in `needs` be given its own monitor of `infos`?
/// (A small matching problem: patterns of different specificity can compete
/// for the same monitor, so this tries the combinations instead of guessing.)
pub fn satisfies(needs: []const []const u8, infos: []const Info) bool {
    if (needs.len > infos.len or needs.len > max_needs) return false;
    var used = [_]bool{false} ** max_monitors;
    return assign(needs, infos, &used, 0);
}

fn assign(needs: []const []const u8, infos: []const Info, used: *[max_monitors]bool, k: usize) bool {
    if (k == needs.len) return true;
    for (infos, 0..) |*info, i| {
        if (i >= max_monitors or used[i]) continue;
        if (matchScore(needs[k], info) == 0) continue;
        used[i] = true;
        if (assign(needs, infos, used, k + 1)) return true;
        used[i] = false;
    }
    return false;
}

/// The profile for the connected `infos`: of those that are satisfied, the one
/// that asks for the most monitors, then an `exact` one over an open one, then
/// the one written last. null: none applies.
pub fn pickProfile(profiles: []const Profile, infos: []const Info) ?usize {
    var best: ?usize = null;
    for (profiles, 0..) |p, i| {
        if (p.exact and p.needs.len != infos.len) continue;
        if (!satisfies(p.needs, infos)) continue;
        if (best) |b| {
            const q = profiles[b];
            const better = p.needs.len > q.needs.len or
                (p.needs.len == q.needs.len and (p.exact or !q.exact));
            if (!better) continue;
        }
        best = i;
    }
    return best;
}

// ----------------------------------------------------------------------------
// Hot-plug settling
// ----------------------------------------------------------------------------

/// Plugging in a monitor makes river announce an output, then its position,
/// then its size, and `wl_output` its name some milliseconds later; a dock
/// with three screens does this three times in a burst. Acting on every
/// intermediate state would move windows back and forth, so a change only
/// counts after `ms` without another one.
pub const Settle = struct {
    ms: u32 = 400,
    /// Time of the last change; null: nothing pending.
    changed_at: ?u64 = null,

    pub fn touch(s: *Settle, now: u64) void {
        s.changed_at = now;
    }

    pub fn pending(s: *const Settle) bool {
        return s.changed_at != null;
    }

    /// The change has been quiet long enough.
    pub fn due(s: *const Settle, now: u64) bool {
        const t = s.changed_at orelse return false;
        return now -| t >= s.ms;
    }

    /// How long the event loop may sleep for this; null: nothing pending.
    pub fn waitMs(s: *const Settle, now: u64) ?i32 {
        const t = s.changed_at orelse return null;
        const left = (t + s.ms) -| now;
        return @intCast(@min(left, std.math.maxInt(i32)));
    }

    pub fn clear(s: *Settle) void {
        s.changed_at = null;
    }
};

// ----------------------------------------------------------------------------
// Where a window came from
// ----------------------------------------------------------------------------

/// Set on a window when its monitor goes away (output.zig), cleared when it
/// is moved back or the user moves it on purpose. A hash and an index, never a
/// pointer: the monitor itself is gone.
pub const Home = struct {
    key: u64 = 0,
    ws: u32 = 0,

    pub fn isSet(h: Home) bool {
        return h.key != 0;
    }

    pub fn matches(h: Home, key: u64) bool {
        return key != 0 and h.key == key;
    }
};

// ----------------------------------------------------------------------------
// Geometry
// ----------------------------------------------------------------------------

pub const Box = struct { x: i32 = 0, y: i32 = 0, w: i32 = 0, h: i32 = 0 };

pub const Order = enum {
    /// Left to right, then top to bottom: what the user sees on the desk.
    position,
    /// The order river announced them in (what wmaker-wl did until now).
    connection,
};

/// Fill `idx` with 0..boxes.len sorted by position (x, then y; ties keep their
/// order). Returns the used part.
pub fn order(boxes: []const Box, idx: []usize) []usize {
    const n = @min(boxes.len, idx.len);
    for (0..n) |i| idx[i] = i;
    const Ctx = struct {
        boxes: []const Box,
        fn less(c: @This(), a: usize, b: usize) bool {
            const p = c.boxes[a];
            const q = c.boxes[b];
            if (p.x != q.x) return p.x < q.x;
            return p.y < q.y;
        }
    };
    std.mem.sortUnstable(usize, idx[0..n], Ctx{ .boxes = boxes }, Ctx.less);
    // Unstable sort + ties: make them deterministic by index.
    var i: usize = 1;
    while (i < n) : (i += 1) {
        var j = i;
        while (j > 0) : (j -= 1) {
            const p = boxes[idx[j - 1]];
            const q = boxes[idx[j]];
            if (p.x == q.x and p.y == q.y and idx[j - 1] > idx[j]) {
                std.mem.swap(usize, &idx[j - 1], &idx[j]);
            } else break;
        }
    }
    return idx[0..n];
}

pub const Direction = enum { left, right, up, down };

/// The monitor next to `from` in `dir`: among those that lie in that
/// direction, the one that shares the most of `from`'s edge, nearest first.
/// Monitors that only touch diagonally count when nothing else is there.
/// null: there is none that way.
pub fn neighbor(boxes: []const Box, from: usize, dir: Direction) ?usize {
    if (from >= boxes.len) return null;
    const a = boxes[from];
    var best: ?usize = null;
    var best_overlap: i64 = -1;
    var best_dist: i64 = std.math.maxInt(i64);
    for (boxes, 0..) |b, i| {
        if (i == from or b.w <= 0 or b.h <= 0) continue;
        const ok = switch (dir) {
            .left => b.x + b.w <= a.x + 1 or b.x + @divTrunc(b.w, 2) < a.x + @divTrunc(a.w, 2) and b.x < a.x,
            .right => b.x >= a.x + a.w - 1 or b.x + @divTrunc(b.w, 2) > a.x + @divTrunc(a.w, 2) and b.x > a.x,
            .up => b.y + b.h <= a.y + 1 or b.y + @divTrunc(b.h, 2) < a.y + @divTrunc(a.h, 2) and b.y < a.y,
            .down => b.y >= a.y + a.h - 1 or b.y + @divTrunc(b.h, 2) > a.y + @divTrunc(a.h, 2) and b.y > a.y,
        };
        if (!ok) continue;
        const horizontal = dir == .left or dir == .right;
        const overlap: i64 = if (horizontal) overlap1d(a.y, a.h, b.y, b.h) else overlap1d(a.x, a.w, b.x, b.w);
        const dist: i64 = switch (dir) {
            .left => @as(i64, a.x) - (@as(i64, b.x) + b.w),
            .right => @as(i64, b.x) - (@as(i64, a.x) + a.w),
            .up => @as(i64, a.y) - (@as(i64, b.y) + b.h),
            .down => @as(i64, b.y) - (@as(i64, a.y) + a.h),
        };
        const d = @max(dist, 0);
        // A monitor that shares an edge beats one that does not; then the
        // bigger overlap; then the nearer one.
        const shares = overlap > 0;
        const best_shares = best_overlap > 0;
        const better = if (best == null) true else if (shares != best_shares) shares else if (shares and overlap != best_overlap and d == best_dist) overlap > best_overlap else d < best_dist or (d == best_dist and overlap > best_overlap);
        if (better) {
            best = i;
            best_overlap = overlap;
            best_dist = d;
        }
    }
    return best;
}

fn overlap1d(a0: i32, alen: i32, b0: i32, blen: i32) i64 {
    const lo = @max(a0, b0);
    const hi = @min(@as(i64, a0) + alen, @as(i64, b0) + blen);
    return @max(0, hi - lo);
}

/// Two monitors show the same pixels (mirrored): same position and size.
pub fn mirrored(a: Box, b: Box) bool {
    return a.x == b.x and a.y == b.y and a.w == b.w and a.h == b.h and a.w > 0;
}

// ----------------------------------------------------------------------------
// The manager: configuration + change detection
// ----------------------------------------------------------------------------

/// What the user configured, plus the state hot-plug handling needs. Lives in
/// `WindowManager`; the rule and profile lists are owned by the config arena
/// (set on every (re)load).
pub const Manager = struct {
    rules: []const Rule = &.{},
    profiles: []const Profile = &.{},
    order: Order = .position,
    settle: Settle = .{},

    /// The set of connected monitors (keys, sorted) the last profile run was
    /// made for: the same set again (a mode change, a reload) does not run it
    /// a second time.
    last_set: u64 = 0,
    /// Index of the profile that ran last, for dumps.
    last_profile: ?usize = null,
    /// Counters for dumps and tests.
    changes: u32 = 0,
    settles: u32 = 0,

    pub fn configure(m: *Manager, rules: []const Rule, profiles: []const Profile, ord: Order, settle_ms: u32) void {
        m.rules = rules;
        m.profiles = profiles;
        m.order = ord;
        m.settle.ms = settle_ms;
        // Names that refer into the old config are gone.
        m.last_profile = null;
    }

    /// Something about the monitors changed (appeared, left, moved, got a name).
    pub fn changed(m: *Manager, now: u64) void {
        m.changes +%= 1;
        m.settle.touch(now);
    }

    /// Hash of a set of monitors, independent of the order they are given in.
    pub fn setKey(infos: []const Info) u64 {
        var sum: u64 = 0;
        var xor: u64 = 0;
        for (infos) |*i| {
            const k = i.key();
            sum +%= k;
            xor ^= std.math.rotl(u64, k, 17);
        }
        return std.hash.Wyhash.hash(infos.len, std.mem.asBytes(&[2]u64{ sum, xor }));
    }

    /// The profile to run for `infos`, if the set differs from the last one a
    /// profile was chosen for. Records the set. Call once per settled change.
    pub fn nextProfile(m: *Manager, infos: []const Info) ?*const Profile {
        const k = setKey(infos);
        if (k == m.last_set) return null;
        m.last_set = k;
        m.settles +%= 1;
        const i = pickProfile(m.profiles, infos) orelse {
            m.last_profile = null;
            return null;
        };
        m.last_profile = i;
        return &m.profiles[i];
    }

    /// The primary monitor among the connected ones: the first one whose rule
    /// says `primary` (in `infos` order). null: none says so.
    pub fn primaryIndex(m: *const Manager, infos: []const Info) ?usize {
        for (infos, 0..) |*info, i| {
            const r = findRule(m.rules, info) orelse continue;
            if (r.primary and r.enabled) return i;
        }
        return null;
    }
};

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

fn mk(name: []const u8, make: []const u8, model: []const u8) Info {
    var i: Info = .{};
    i.name.set(name);
    i.make.set(make);
    i.model.set(model);
    i.complete = true;
    return i;
}

const tt = std.testing;

test "Text keeps what fits and cuts what does not" {
    var x: Text = .{};
    try tt.expect(x.isEmpty());
    x.set("DP-1");
    try tt.expectEqualStrings("DP-1", x.get());
    x.set("a" ** (max_text + 20));
    try tt.expectEqual(@as(usize, max_text), x.get().len);
    x.set("");
    try tt.expect(x.isEmpty());
}

test "Info.key: same monitor on the same port is the same, case does not matter" {
    const a = mk("DP-1", "Dell Inc.", "DELL U2720Q");
    const b = mk("dp-1", "DELL INC.", "dell u2720q");
    try tt.expect(a.key() != 0);
    try tt.expectEqual(a.key(), b.key());
    // Another port or another model is another identity.
    try tt.expect(a.key() != mk("DP-2", "Dell Inc.", "DELL U2720Q").key());
    try tt.expect(a.key() != mk("DP-1", "Dell Inc.", "DELL U2415").key());
    // Nothing known: no key (0), never a collision between unknown monitors.
    try tt.expectEqual(@as(u64, 0), (Info{}).key());
}

test "Info.key falls back to the description when nothing else is known" {
    var a: Info = .{};
    a.description.set("Some Monitor 17\"");
    var b: Info = .{};
    b.description.set("Another Monitor");
    try tt.expect(a.key() != 0);
    try tt.expect(a.key() != b.key());
}

test "Info.label reads well with any subset of the fields" {
    var buf: [200]u8 = undefined;
    try tt.expectEqualStrings("Dell Inc. DELL U2720Q (DP-1)", mk("DP-1", "Dell Inc.", "DELL U2720Q").label(&buf));
    try tt.expectEqualStrings("(eDP-1)", mk("eDP-1", "", "").label(&buf));
    try tt.expectEqualStrings("(unidentified)", (Info{}).label(&buf));
    var d: Info = .{};
    d.description.set("Virtual output");
    try tt.expectEqualStrings("Virtual output", d.label(&buf));
}

test "matchScore: connector beats model beats substring beats star" {
    const i = mk("DP-1", "Dell Inc.", "DELL U2720Q");
    try tt.expectEqual(@as(u8, 4), matchScore("DP-1", &i));
    try tt.expectEqual(@as(u8, 4), matchScore("dp-1", &i));
    try tt.expectEqual(@as(u8, 3), matchScore("DELL U2720Q", &i));
    try tt.expectEqual(@as(u8, 3), matchScore("Dell Inc. DELL U2720Q", &i));
    try tt.expectEqual(@as(u8, 2), matchScore("u2720", &i));
    try tt.expectEqual(@as(u8, 1), matchScore("*", &i));
    try tt.expectEqual(@as(u8, 0), matchScore("DP-2", &i));
    try tt.expectEqual(@as(u8, 0), matchScore("", &i));
    try tt.expectEqual(@as(u8, 0), matchScore("   ", &i));
}

test "matchScore: the description is searched too" {
    var i: Info = .{};
    i.description.set("Samsung Electric Company LS27 (HDMI-A-1)");
    try tt.expectEqual(@as(u8, 2), matchScore("samsung", &i));
    try tt.expectEqual(@as(u8, 0), matchScore("lg", &i));
}

test "findRule: most specific wins, among equals the last one" {
    const rules = [_]Rule{
        .{ .match = "*", .workspaces = 2 },
        .{ .match = "DELL U2720Q", .workspaces = 6 },
        .{ .match = "DP-1", .workspaces = 8 },
        .{ .match = "dp-1", .workspaces = 9 },
    };
    const dell = mk("DP-1", "Dell Inc.", "DELL U2720Q");
    try tt.expectEqual(@as(?u32, 9), findRule(&rules, &dell).?.workspaces);
    const other_port = mk("DP-2", "Dell Inc.", "DELL U2720Q");
    try tt.expectEqual(@as(?u32, 6), findRule(&rules, &other_port).?.workspaces);
    const unknown = mk("HDMI-1", "Acme", "X1");
    try tt.expectEqual(@as(?u32, 2), findRule(&rules, &unknown).?.workspaces);
    try tt.expect(findRule(&.{}, &unknown) == null);
}

test "effective: defaults without a rule, rule values with one" {
    const none = effective(&.{}, &mk("DP-1", "", ""), 4);
    try tt.expect(none.enabled and !none.primary and none.restore_windows);
    try tt.expectEqual(@as(u32, 4), none.workspaces);
    try tt.expect(none.rule == null);

    const rules = [_]Rule{.{ .match = "DP-1", .enabled = false, .primary = true, .workspaces = 2, .start_workspace = 1, .restore_windows = false }};
    const e = effective(&rules, &mk("DP-1", "", ""), 4);
    try tt.expect(!e.enabled and e.primary and !e.restore_windows);
    try tt.expectEqual(@as(u32, 2), e.workspaces);
    try tt.expectEqual(@as(u32, 1), e.start_workspace);
}

test "satisfies: each pattern needs its own monitor" {
    const infos = [_]Info{ mk("eDP-1", "BOE", "0x08AA"), mk("DP-1", "Dell Inc.", "DELL U2720Q") };
    try tt.expect(satisfies(&.{"eDP-1"}, &infos));
    try tt.expect(satisfies(&.{ "eDP-1", "DP-1" }, &infos));
    try tt.expect(!satisfies(&.{ "eDP-1", "DP-2" }, &infos));
    // Two patterns, one monitor that fits both: not enough.
    try tt.expect(!satisfies(&.{ "*", "eDP-1", "DP-1" }, &infos));
    try tt.expect(satisfies(&.{ "*", "*" }, &infos));
    try tt.expect(!satisfies(&.{ "*", "*", "*" }, &infos));
    // Order of the patterns must not matter: the broad one first must not
    // steal the monitor the narrow one needs.
    try tt.expect(satisfies(&.{ "*", "eDP-1" }, &infos));
    try tt.expect(satisfies(&.{ "*", "DP-1" }, &infos));
    try tt.expect(satisfies(&.{}, &infos));
}

test "pickProfile: the most demanding one that fits, exact over open, last over earlier" {
    const profiles = [_]Profile{
        .{ .name = "any", .needs = &.{"*"} },
        .{ .name = "laptop", .needs = &.{"eDP-1"}, .exact = true },
        .{ .name = "docked", .needs = &.{ "eDP-1", "DP-1" } },
        .{ .name = "docked2", .needs = &.{ "eDP-1", "DP-1" } },
    };
    const lap = mk("eDP-1", "BOE", "0x08AA");
    const dell = mk("DP-1", "Dell Inc.", "DELL U2720Q");

    var set1 = [_]Info{lap};
    try tt.expectEqual(@as(?usize, 1), pickProfile(&profiles, &set1));
    var set2 = [_]Info{ lap, dell };
    try tt.expectEqual(@as(?usize, 3), pickProfile(&profiles, &set2));
    var set3 = [_]Info{mk("HDMI-1", "x", "y")};
    try tt.expectEqual(@as(?usize, 0), pickProfile(&profiles, &set3));
    try tt.expect(pickProfile(&profiles, &.{}) == null);
}

test "pickProfile: exact refuses a set with extra monitors" {
    const profiles = [_]Profile{.{ .name = "only-laptop", .needs = &.{"eDP-1"}, .exact = true }};
    const a = [_]Info{ mk("eDP-1", "", ""), mk("DP-1", "", "") };
    try tt.expect(pickProfile(&profiles, &a) == null);
}

test "Settle: nothing pending, then due only after the quiet time" {
    var s: Settle = .{ .ms = 400 };
    try tt.expect(!s.pending() and !s.due(1000) and s.waitMs(1000) == null);
    s.touch(1000);
    try tt.expect(s.pending() and !s.due(1399) and s.due(1400));
    try tt.expectEqual(@as(?i32, 100), s.waitMs(1300));
    try tt.expectEqual(@as(?i32, 0), s.waitMs(5000));
    // Another change restarts the wait.
    s.touch(1390);
    try tt.expect(!s.due(1400) and s.due(1790));
    s.clear();
    try tt.expect(!s.pending());
}

test "Settle: a clock that goes back never underflows" {
    var s: Settle = .{ .ms = 100 };
    s.touch(5000);
    try tt.expect(!s.due(10));
    try tt.expectEqual(@as(?i32, 100 + 4990), s.waitMs(10));
}

test "Home: unset by default, matches only its own key" {
    const h: Home = .{};
    try tt.expect(!h.isSet() and !h.matches(0) and !h.matches(5));
    const g: Home = .{ .key = 5, .ws = 2 };
    try tt.expect(g.isSet() and g.matches(5) and !g.matches(6) and !g.matches(0));
}

test "order: left to right, then top to bottom, ties by index" {
    const boxes = [_]Box{
        .{ .x = 1920, .y = 0, .w = 1920, .h = 1080 }, // 0: right
        .{ .x = 0, .y = 0, .w = 1920, .h = 1080 }, //    1: left
        .{ .x = 0, .y = 1080, .w = 1920, .h = 1080 }, // 2: below the left one
        .{ .x = 0, .y = 0, .w = 1920, .h = 1080 }, //    3: mirror of 1
    };
    var idx: [4]usize = undefined;
    const o = order(&boxes, &idx);
    try tt.expectEqualSlices(usize, &.{ 1, 3, 2, 0 }, o);
}

test "order: handles empty, one, and a too small buffer" {
    var idx: [2]usize = undefined;
    try tt.expectEqual(@as(usize, 0), order(&.{}, &idx).len);
    try tt.expectEqualSlices(usize, &.{0}, order(&.{.{ .w = 1, .h = 1 }}, &idx));
    const three = [_]Box{ .{ .x = 5 }, .{ .x = 1 }, .{ .x = 3 } };
    try tt.expectEqual(@as(usize, 2), order(&three, &idx).len);
}

test "neighbor: left, right, up, down in a row and in an L" {
    const boxes = [_]Box{
        .{ .x = 0, .y = 0, .w = 1920, .h = 1080 }, //    0
        .{ .x = 1920, .y = 0, .w = 2560, .h = 1440 }, // 1: right of 0
        .{ .x = 0, .y = 1080, .w = 1920, .h = 1080 }, // 2: below 0
    };
    try tt.expectEqual(@as(?usize, 1), neighbor(&boxes, 0, .right));
    try tt.expectEqual(@as(?usize, 2), neighbor(&boxes, 0, .down));
    try tt.expectEqual(@as(?usize, 0), neighbor(&boxes, 1, .left));
    try tt.expectEqual(@as(?usize, 0), neighbor(&boxes, 2, .up));
    try tt.expect(neighbor(&boxes, 0, .left) == null);
    try tt.expect(neighbor(&boxes, 0, .up) == null);
    try tt.expect(neighbor(&boxes, 9, .left) == null);
}

test "neighbor: prefers the monitor that shares an edge over a nearer diagonal one" {
    // `a` is wide; `near` sits diagonally close, `far` is exactly to its right.
    const boxes = [_]Box{
        .{ .x = 0, .y = 0, .w = 1000, .h = 1000 }, //     0: a
        .{ .x = 1000, .y = 1000, .w = 500, .h = 500 }, // 1: touches only at a corner
        .{ .x = 1100, .y = 0, .w = 1000, .h = 1000 }, //  2: shares the whole edge
    };
    try tt.expectEqual(@as(?usize, 2), neighbor(&boxes, 0, .right));
}

test "neighbor: ignores monitors that are not ready (no size)" {
    const boxes = [_]Box{ .{ .x = 0, .y = 0, .w = 100, .h = 100 }, .{ .x = 100, .y = 0, .w = 0, .h = 0 } };
    try tt.expect(neighbor(&boxes, 0, .right) == null);
}

test "mirrored: same box" {
    try tt.expect(mirrored(.{ .w = 10, .h = 10 }, .{ .w = 10, .h = 10 }));
    try tt.expect(!mirrored(.{ .w = 10, .h = 10 }, .{ .x = 1, .w = 10, .h = 10 }));
    try tt.expect(!mirrored(.{}, .{}));
}

test "setKey: independent of the order, different for different sets" {
    const a = mk("eDP-1", "BOE", "x");
    const b = mk("DP-1", "Dell", "y");
    try tt.expectEqual(Manager.setKey(&.{ a, b }), Manager.setKey(&.{ b, a }));
    try tt.expect(Manager.setKey(&.{ a, b }) != Manager.setKey(&.{a}));
    try tt.expect(Manager.setKey(&.{a}) != Manager.setKey(&.{b}));
}

test "Manager.nextProfile: one run per set, not per event" {
    const profiles = [_]Profile{
        .{ .name = "docked", .needs = &.{ "eDP-1", "DP-1" }, .run = &.{ "kanshictl", "switch", "docked" } },
    };
    var m: Manager = .{};
    m.configure(&.{}, &profiles, .position, 250);
    try tt.expectEqual(@as(u32, 250), m.settle.ms);

    const a = mk("eDP-1", "BOE", "x");
    const b = mk("DP-1", "Dell", "y");
    const docked = [_]Info{ a, b };
    const lonely = [_]Info{a};

    const first = m.nextProfile(&docked).?;
    try tt.expectEqualStrings("docked", first.name);
    try tt.expect(m.nextProfile(&docked) == null); // same set: nothing new
    try tt.expect(m.nextProfile(&lonely) == null); // new set, no profile for it
    try tt.expect(m.last_profile == null);
    try tt.expect(m.nextProfile(&docked) != null); // docked again: runs again
    try tt.expectEqual(@as(u32, 3), m.settles);
}

test "Manager.changed counts and restarts the settle timer" {
    var m: Manager = .{};
    m.changed(100);
    m.changed(150);
    try tt.expectEqual(@as(u32, 2), m.changes);
    try tt.expect(!m.settle.due(500) and m.settle.due(550));
}

test "Manager.primaryIndex: the first enabled primary, null without one" {
    const rules = [_]Rule{
        .{ .match = "DP-2", .primary = true, .enabled = false },
        .{ .match = "DP-1", .primary = true },
    };
    var m: Manager = .{};
    m.configure(&rules, &.{}, .position, 400);
    const infos = [_]Info{ mk("eDP-1", "", ""), mk("DP-2", "", ""), mk("DP-1", "", "") };
    try tt.expectEqual(@as(?usize, 2), m.primaryIndex(&infos));
    try tt.expect(m.primaryIndex(infos[0..1]) == null);
}
