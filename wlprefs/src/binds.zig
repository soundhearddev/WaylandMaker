// SPDX-License-Identifier: 0BSD
//
// The key bindings the compositor will actually have, for the read-only
// "Keyboard Shortcut Preferences" page: wmaker-wl's shipped defaults, then
// the user's `bind =` and `unbind =` lines on top, with the same rule the
// compositor uses (a `bind` replaces a default on the same key combination,
// `unbind` removes one). Editing is not here yet (docs/TODO.md): this only
// shows what is in effect, and which entries come from the user's file.

const std = @import("std");
const xkb = @import("xkbcommon");

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
// Editing: from a list of bindings back to config.conf lines
// ----------------------------------------------------------------------------

extern fn xkb_utf32_to_keysym(ucs: u32) u32;

/// Is `name` a key the compositor can resolve? The same lookup as its
/// config.zig: a keysym name (case-insensitive as a fallback) or one
/// character written as itself.
pub fn keyKnown(a: std.mem.Allocator, name: []const u8) bool {
    if (name.len == 0) return false;
    const z = a.dupeZ(u8, name) catch return false;
    defer a.free(z);
    if (xkb.Keysym.fromName(z, .no_flags) != .NoSymbol) return true;
    if (xkb.Keysym.fromName(z, .case_insensitive) != .NoSymbol) return true;
    const n = std.unicode.utf8ByteSequenceLength(name[0]) catch return false;
    if (n != name.len) return false;
    const cp = std.unicode.utf8Decode(name) catch return false;
    return xkb_utf32_to_keysym(cp) != 0;
}

/// Why `combo` cannot be a key combination, or null if it can.
pub fn comboProblem(a: std.mem.Allocator, combo: []const u8) ?[]const u8 {
    const t = std.mem.trim(u8, combo, " \t");
    if (t.len == 0) return "Keys: empty";
    if (std.mem.indexOfScalar(u8, t, ',') != null) return "Keys: a comma is not allowed";

    var key: []const u8 = t;
    var mods_part: []const u8 = "";
    if (std.mem.endsWith(u8, t, "++")) {
        key = "plus";
        mods_part = t[0 .. t.len - 2];
    } else if (std.mem.lastIndexOfScalar(u8, t, '+')) |i| {
        mods_part = t[0..i];
        key = std.mem.trim(u8, t[i + 1 ..], " \t");
    }
    var it = std.mem.splitScalar(u8, mods_part, '+');
    while (it.next()) |raw| {
        const m = std.mem.trim(u8, raw, " \t");
        if (m.len == 0) {
            if (mods_part.len == 0) continue;
            return "Keys: empty modifier";
        }
        const known = std.mem.eql(u8, modName(m), "super") or std.mem.eql(u8, modName(m), "shift") or
            std.mem.eql(u8, modName(m), "ctrl") or std.mem.eql(u8, modName(m), "alt") or
            std.mem.eql(u8, modName(m), "mod3") or std.mem.eql(u8, modName(m), "mod5");
        if (!known) return "Keys: unknown modifier (Super, Ctrl, Alt, Shift)";
    }
    if (!keyKnown(a, key)) return "Keys: unknown key name";
    return null;
}

/// The `bind =` / `unbind =` lines that turn the shipped defaults into
/// `list`: a line for every entry that is new or different, an `unbind` for
/// every default that is gone. Entries equal to a default need no line.
pub fn userLines(a: std.mem.Allocator, defaults: []const u8, list: []const Entry) ![]const []const u8 {
    const def = try effective(a, defaults, "");

    var lines: std.ArrayList([]const u8) = .empty;

    // Defaults that are gone.
    for (def) |d| {
        const dn = try normalize(a, d.combo);
        var kept = false;
        for (list) |e| {
            if (std.mem.eql(u8, try normalize(a, e.combo), dn)) {
                kept = true;
                break;
            }
        }
        if (!kept) try lines.append(a, try std.fmt.allocPrint(a, "unbind = {s}", .{d.combo}));
    }
    // New or changed entries.
    for (list) |e| {
        const en = try normalize(a, e.combo);
        var same = false;
        for (def) |d| {
            if (std.mem.eql(u8, try normalize(a, d.combo), en) and std.mem.eql(u8, d.action, e.action)) {
                same = true;
                break;
            }
        }
        if (!same) try lines.append(a, try std.fmt.allocPrint(a, "bind = {s}, {s}", .{ e.combo, e.action }));
    }
    return lines.toOwnedSlice(a);
}

/// Replace every `bind`/`unbind` line of `text` by `lines`: they go where the
/// first old one was (or at the end, under a heading, if there was none).
/// Everything else in the file is untouched. Result owned by the caller.
pub fn rewriteUserLines(gpa: std.mem.Allocator, text: []const u8, lines: []const []const u8) ![]u8 {
    var kept: std.ArrayList([]const u8) = .empty;
    defer kept.deinit(gpa);
    var insert_at: ?usize = null;

    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        if (splitLine(raw)) |l| {
            if (std.mem.eql(u8, l.key, "bind") or std.mem.eql(u8, l.key, "unbind")) {
                if (insert_at == null) insert_at = kept.items.len;
                continue;
            }
        }
        try kept.append(gpa, raw);
    }

    // A file ending in a newline splits into a final empty piece: keep it last.
    var trailing_nl = false;
    if (kept.items.len > 0 and kept.items[kept.items.len - 1].len == 0 and text.len > 0 and text[text.len - 1] == '\n') {
        _ = kept.pop();
        trailing_nl = true;
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    const at = insert_at orelse kept.items.len;
    var first = true;
    const Join = struct {
        fn piece(o: *std.ArrayList(u8), g: std.mem.Allocator, f: *bool, s_: []const u8) !void {
            if (!f.*) try o.append(g, '\n');
            f.* = false;
            try o.appendSlice(g, s_);
        }
    };
    for (kept.items[0..@min(at, kept.items.len)]) |p| try Join.piece(&out, gpa, &first, p);
    if (insert_at == null and lines.len > 0) {
        try Join.piece(&out, gpa, &first, "");
        try Join.piece(&out, gpa, &first, "# ---- key bindings (set by wlprefs) ----");
    }
    for (lines) |l| try Join.piece(&out, gpa, &first, l);
    for (kept.items[@min(at, kept.items.len)..]) |p| try Join.piece(&out, gpa, &first, p);

    if (trailing_nl or (insert_at == null and lines.len > 0)) try out.append(gpa, '\n');
    return out.toOwnedSlice(gpa);
}

/// Same list (same combinations with the same actions), order aside?
pub fn sameList(a: std.mem.Allocator, x: []const Entry, y: []const Entry) !bool {
    if (x.len != y.len) return false;
    for (x) |e| {
        const en = try normalize(a, e.combo);
        var found = false;
        for (y) |f| {
            if (std.mem.eql(u8, en, try normalize(a, f.combo)) and std.mem.eql(u8, e.action, f.action)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
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

test "keyKnown and comboProblem" {
    const a = std.testing.allocator;
    try std.testing.expect(keyKnown(a, "Return"));
    try std.testing.expect(keyKnown(a, "q"));
    try std.testing.expect(keyKnown(a, "udiaeresis"));
    try std.testing.expect(keyKnown(a, "ü"));
    try std.testing.expect(!keyKnown(a, "Bogus_Key"));
    try std.testing.expect(!keyKnown(a, ""));
    try std.testing.expect(!keyKnown(a, "üü"));

    try std.testing.expect(comboProblem(a, "Super+q") == null);
    try std.testing.expect(comboProblem(a, "Super+Shift+ü") == null);
    try std.testing.expect(comboProblem(a, "Ctrl+Alt+Delete") == null);
    try std.testing.expect(comboProblem(a, "Print") == null);
    try std.testing.expect(comboProblem(a, "Super++") == null);
    try std.testing.expect(comboProblem(a, "") != null);
    try std.testing.expect(comboProblem(a, "Super+") != null);
    try std.testing.expect(comboProblem(a, "Hyper+q") != null);
    try std.testing.expect(comboProblem(a, "Super+q, close") != null);
    try std.testing.expect(comboProblem(a, "Super+Nonsense") != null);
}

test "userLines: nothing for the defaults, bind for new and changed, unbind for removed" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const defaults =
        \\bind = Super+Return, spawn_terminal
        \\bind = Super+q, close
        \\bind = Super+h, focus_left
    ;
    const unchanged = try effective(a, defaults, "");
    const none = try userLines(a, defaults, unchanged);
    try std.testing.expectEqual(@as(usize, 0), none.len);

    // Same keys, different spelling and order: still no lines.
    const respelled = [_]Entry{
        .{ .combo = "super+h", .action = "focus_left", .user = false },
        .{ .combo = "Mod4+q", .action = "close", .user = false },
        .{ .combo = "Super+Return", .action = "spawn_terminal", .user = false },
    };
    try std.testing.expectEqual(@as(usize, 0), (try userLines(a, defaults, &respelled)).len);

    // q removed, h changed, a new one.
    const edited = [_]Entry{
        .{ .combo = "Super+Return", .action = "spawn_terminal", .user = false },
        .{ .combo = "Super+h", .action = "focus_right", .user = true },
        .{ .combo = "Super+x", .action = "minimize", .user = true },
    };
    const lines = try userLines(a, defaults, &edited);
    try std.testing.expectEqual(@as(usize, 3), lines.len);
    try std.testing.expectEqualStrings("unbind = Super+q", lines[0]);
    try std.testing.expectEqualStrings("bind = Super+h, focus_right", lines[1]);
    try std.testing.expectEqualStrings("bind = Super+x, minimize", lines[2]);

    // And the compositor's own rule turns that back into the same list.
    var text: std.ArrayList(u8) = .empty;
    for (lines) |l| {
        try text.appendSlice(a, l);
        try text.append(a, '\n');
    }
    const back = try effective(a, defaults, text.items);
    try std.testing.expect(try sameList(a, back, &edited));
}

test "rewriteUserLines replaces the bind lines where the first one was" {
    const gpa = std.testing.allocator;
    const text =
        \\# my config
        \\gap = 8
        \\bind = Super+x, close
        \\terminal = foot
        \\unbind = Super+q
        \\bind = Super+y, exit
        \\# end
        \\
    ;
    const out = try rewriteUserLines(gpa, text, &.{ "bind = Super+z, minimize", "unbind = Super+h" });
    defer gpa.free(out);
    try std.testing.expectEqualStrings(
        \\# my config
        \\gap = 8
        \\bind = Super+z, minimize
        \\unbind = Super+h
        \\terminal = foot
        \\# end
        \\
    , out);
}

test "rewriteUserLines: no old bind lines -> a block at the end; no new lines -> they vanish" {
    const gpa = std.testing.allocator;
    const a = try rewriteUserLines(gpa, "gap = 8\n", &.{"bind = Super+z, minimize"});
    defer gpa.free(a);
    try std.testing.expectEqualStrings("gap = 8\n\n# ---- key bindings (set by wlprefs) ----\nbind = Super+z, minimize\n", a);

    const b = try rewriteUserLines(gpa, "gap = 8\nbind = Super+x, close\n", &.{});
    defer gpa.free(b);
    try std.testing.expectEqualStrings("gap = 8\n", b);

    // Nothing to write into a file without bindings: unchanged, byte for byte.
    const c = try rewriteUserLines(gpa, "gap = 8", &.{});
    defer gpa.free(c);
    try std.testing.expectEqualStrings("gap = 8", c);

    // Empty file.
    const d = try rewriteUserLines(gpa, "", &.{"bind = Super+z, minimize"});
    defer gpa.free(d);
    try std.testing.expect(std.mem.indexOf(u8, d, "bind = Super+z, minimize\n") != null);

    // A commented-out bind line is a comment, not a bind.
    const e = try rewriteUserLines(gpa, "# bind = Super+x, close\n", &.{"bind = Super+y, exit"});
    defer gpa.free(e);
    try std.testing.expect(std.mem.startsWith(u8, e, "# bind = Super+x, close\n"));
}

test "sameList ignores order and key spelling" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const x = [_]Entry{ .{ .combo = "Super+a", .action = "close", .user = false }, .{ .combo = "Super+b", .action = "exit", .user = false } };
    const y = [_]Entry{ .{ .combo = "mod4+B", .action = "exit", .user = true }, .{ .combo = "super+a", .action = "close", .user = true } };
    try std.testing.expect(try sameList(a, &x, &y));
    const z = [_]Entry{ .{ .combo = "Super+a", .action = "close", .user = false }, .{ .combo = "Super+b", .action = "close", .user = false } };
    try std.testing.expect(!(try sameList(a, &x, &z)));
    try std.testing.expect(!(try sameList(a, &x, x[0..1])));
}
