// SPDX-License-Identifier: 0BSD
//
// The key bindings the compositor will actually have, for the read-only
// "Keyboard Shortcut Preferences" page: wmaker-wl's shipped defaults, then
// the user's `bind =` and `unbind =` lines on top, with the same rule the
// compositor uses (a `bind` replaces a default on the same key combination,
// `unbind` removes one). Editing is not here yet (docs/TODO.md): this only
// shows what is in effect, and which entries come from the user's file.

const std = @import("std");

pub const Entry = struct {
    /// As written in the file: "Super+Shift+e".
    combo: []const u8,
    /// Everything after the first comma: "exit", "spawn foot -e htop".
    action: []const u8,
    /// Comes from the user's config.conf (new, or replacing a default).
    user: bool,
};

/// "Shift+Super+E" and "super+shift+e" are the same key combination: the
/// modifiers as a sorted lower-case set, then the key. The compositor
/// compares parsed modifier bits and keysyms; this is the text equivalent.
/// Returned string lives in `a`.
pub fn normalize(a: std.mem.Allocator, combo: []const u8) ![]u8 {
    const s = std.mem.trim(u8, combo, " \t");

    // "Super++" is Super and the plus key.
    var key: []const u8 = s;
    var mods_part: []const u8 = "";
    if (std.mem.endsWith(u8, s, "++")) {
        key = "plus";
        mods_part = s[0 .. s.len - 2];
    } else if (std.mem.lastIndexOfScalar(u8, s, '+')) |i| {
        mods_part = s[0..i];
        key = std.mem.trim(u8, s[i + 1 ..], " \t");
    }

    var mods: [8][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, mods_part, '+');
    while (it.next()) |raw| {
        const t = std.mem.trim(u8, raw, " \t");
        if (t.len == 0 or n == mods.len) continue;
        mods[n] = modName(t);
        n += 1;
    }
    std.mem.sort([]const u8, mods[0..n], {}, lessStr);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    for (mods[0..n]) |m| {
        for (m) |ch| try out.append(a, std.ascii.toLower(ch));
        try out.append(a, '+');
    }
    for (key) |ch| try out.append(a, std.ascii.toLower(ch));
    return out.toOwnedSlice(a);
}

fn lessStr(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

/// Canonical name of a modifier token. Unknown tokens are returned as they
/// are (and lower-cased by the caller): they just never match anything.
fn modName(t: []const u8) []const u8 {
    const eq = std.ascii.eqlIgnoreCase;
    if (eq(t, "super") or eq(t, "mod4") or eq(t, "logo")) return "super";
    if (eq(t, "shift")) return "shift";
    if (eq(t, "ctrl") or eq(t, "control")) return "ctrl";
    if (eq(t, "alt") or eq(t, "mod1")) return "alt";
    if (eq(t, "mod3")) return "mod3";
    if (eq(t, "mod5") or eq(t, "altgr")) return "mod5";
    return t;
}

const Line = struct { key: []const u8, value: []const u8 };

fn isColour(s: []const u8) bool {
    if (s.len < 7 or s[0] != '#') return false;
    for (s[1..7]) |ch| if (!std.ascii.isHex(ch)) return false;
    return s.len == 7 or s[7] == ' ' or s[7] == '\t' or s[7] == '\r';
}

/// Same comment rule as config.zig.
fn stripComment(raw: []const u8) []const u8 {
    var end = raw.len;
    for (raw, 0..) |ch, i| {
        if (ch != '#') continue;
        if (!(i == 0 or raw[i - 1] == ' ' or raw[i - 1] == '\t')) continue;
        if (isColour(raw[i..])) continue;
        end = i;
        break;
    }
    return std.mem.trim(u8, raw[0..end], " \t\r");
}

fn splitLine(raw: []const u8) ?Line {
    const line = stripComment(raw);
    if (line.len == 0) return null;
    const eq = std.mem.indexOfScalar(u8, line, '=') orelse return null;
    return .{
        .key = std.mem.trim(u8, line[0..eq], " \t"),
        .value = std.mem.trim(u8, line[eq + 1 ..], " \t\""),
    };
}

const Builder = struct {
    a: std.mem.Allocator,
    list: std.ArrayList(Entry) = .empty,
    /// normalised combo of list[i]
    norm: std.ArrayList([]u8) = .empty,

    fn find(b: *const Builder, n: []const u8) ?usize {
        for (b.norm.items, 0..) |m, i| {
            if (std.mem.eql(u8, m, n)) return i;
        }
        return null;
    }

    fn add(b: *Builder, value: []const u8, user: bool) !void {
        // "combo, action": the combo cannot contain a comma.
        const comma = std.mem.indexOfScalar(u8, value, ',') orelse return;
        const combo = std.mem.trim(u8, value[0..comma], " \t");
        const action = std.mem.trim(u8, value[comma + 1 ..], " \t");
        if (combo.len == 0 or action.len == 0) return;

        const n = try normalize(b.a, combo);
        const entry: Entry = .{
            .combo = try b.a.dupe(u8, combo),
            .action = try b.a.dupe(u8, action),
            .user = user,
        };
        if (b.find(n)) |i| {
            b.list.items[i] = entry;
            b.norm.items[i] = n;
        } else {
            try b.list.append(b.a, entry);
            try b.norm.append(b.a, n);
        }
    }

    fn remove(b: *Builder, value: []const u8) !void {
        const combo = std.mem.trim(u8, value, " \t");
        if (combo.len == 0) return;
        const n = try normalize(b.a, combo);
        if (b.find(n)) |i| {
            _ = b.list.orderedRemove(i);
            _ = b.norm.orderedRemove(i);
        }
    }

    fn feed(b: *Builder, text: []const u8, user: bool) !void {
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const l = splitLine(raw) orelse continue;
            if (std.mem.eql(u8, l.key, "bind")) {
                try b.add(l.value, user);
            } else if (std.mem.eql(u8, l.key, "unbind")) {
                try b.remove(l.value);
            }
        }
    }
};

/// The bindings in effect, in the order the compositor reads them. All
/// strings live in `a` (use an arena).
pub fn effective(a: std.mem.Allocator, defaults: []const u8, user: []const u8) ![]Entry {
    var b: Builder = .{ .a = a };
    try b.feed(defaults, false);
    try b.feed(user, true);
    return b.list.toOwnedSlice(a);
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

test "normalize: modifier order, case and aliases do not matter" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const x = try normalize(a, "Super+Shift+e");
    const y = try normalize(a, "shift + MOD4 + E");
    const z = try normalize(a, "Logo+Shift+e");
    try std.testing.expectEqualStrings("shift+super+e", x);
    try std.testing.expectEqualStrings(x, y);
    try std.testing.expectEqualStrings(x, z);
    // Different key or different modifier set: different combination.
    try std.testing.expect(!std.mem.eql(u8, x, try normalize(a, "Super+e")));
    try std.testing.expect(!std.mem.eql(u8, x, try normalize(a, "Super+Shift+q")));
    // No modifier at all.
    try std.testing.expectEqualStrings("print", try normalize(a, "Print"));
    // The plus key.
    try std.testing.expectEqualStrings("super+plus", try normalize(a, "Super++"));
}

test "effective: defaults, then the user's replace, add and remove" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const defaults =
        \\# comment
        \\bind = Super+Return,       spawn_terminal
        \\bind = Super+q,            close
        \\bind = Super+Shift+e,      exit   # trailing comment
        \\gap = 8
    ;
    const user =
        \\bind = shift+super+E, shell notify-send bye
        \\unbind = Super+q
        \\bind = Super+x, focus_left
        \\bind = Super+Return, spawn foot
    ;
    const list = try effective(a, defaults, user);
    try std.testing.expectEqual(@as(usize, 3), list.len);

    // Super+Return replaced in place by the user's.
    try std.testing.expectEqualStrings("Super+Return", list[0].combo);
    try std.testing.expectEqualStrings("spawn foot", list[0].action);
    try std.testing.expect(list[0].user);
    // Super+q is gone; the replaced exit bind kept its place.
    try std.testing.expectEqualStrings("shift+super+E", list[1].combo);
    try std.testing.expectEqualStrings("shell notify-send bye", list[1].action);
    try std.testing.expect(list[1].user);
    // A new one is appended.
    try std.testing.expectEqualStrings("Super+x", list[2].combo);
}

test "effective: an action keeps its commas, malformed lines are skipped" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const list = try effective(arena.allocator(),
        \\bind = Super+m, shell echo a, b
        \\bind = nocomma
        \\bind = , close
        \\bind = Super+z,
        \\unbind =
        \\bind=Super+k,focus_up
    , "");
    try std.testing.expectEqual(@as(usize, 2), list.len);
    try std.testing.expectEqualStrings("shell echo a, b", list[0].action);
    try std.testing.expectEqualStrings("Super+k", list[1].combo);
    try std.testing.expect(!list[0].user);
}

test "effective: the shipped default config yields a plausible list" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const list = try effective(arena.allocator(), @import("settings.zig").default_config_text, "");
    try std.testing.expect(list.len > 20);
    var found_close = false;
    for (list) |e| {
        try std.testing.expect(!e.user);
        if (std.mem.eql(u8, e.combo, "Super+q") and std.mem.eql(u8, e.action, "close")) found_close = true;
    }
    try std.testing.expect(found_close);
}
