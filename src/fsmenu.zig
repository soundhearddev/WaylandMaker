// SPDX-License-Identifier: 0BSD
//
// Window Maker's OPEN_MENU for the root menu:
//
//     "Documents"  OPEN_MENU  ~/Documents
//     "Pictures"   OPEN_MENU  ~/Pictures WITH imv
//     "More"       OPEN_MENU  ~/.config/wmaker-wl/more.menu
//
//   DIRECTORY     one entry per file, one submenu per sub-directory (to a
//                 fixed depth). Choosing a file runs `WITH-command file`; with
//                 no WITH it is opened with `xdg-open`.
//   FILE          a menu in either of the root menu's formats, included in
//                 place.
//   | COMMAND     (Window Maker runs the command and reads a menu from its
//                 output) is NOT supported: running a program every time a
//                 menu opens, inside the window manager, would stall the whole
//                 desktop whenever that program is slow. The entry is shown
//                 disabled.
//
// The menu is built when the root menu is OPENED, so a directory listing is
// never stale. Pure apart from reading the file system (libc opendir/stat),
// and bounded in every direction: depth, entries per directory, entries in
// total, file size -- a huge or hostile directory cannot hang or exhaust the
// window manager.

const std = @import("std");
const wm_menu = @import("wm_menu.zig");
const xpm = @import("xpm.zig");

const c = @cImport({
    @cInclude("dirent.h");
    @cInclude("sys/stat.h");
    @cInclude("stdlib.h");
    @cInclude("string.h");
});

pub const max_depth: u32 = 3;
pub const max_entries_per_dir: usize = 200;
pub const max_total_entries: usize = 1000;

/// Run when a file is chosen and there is no `WITH`.
pub const default_opener = "xdg-open";

pub const Spec = struct {
    paths: []const []const u8,
    /// The command after WITH, if any.
    with: ?[]const u8,
    /// A `| command` source.
    pipe: bool,
};

/// Split `arg` ("~/a ~/b WITH cmd args") into its parts.
pub fn parseSpec(a: std.mem.Allocator, arg: []const u8) !Spec {
    const text = std.mem.trim(u8, arg, " \t");
    if (text.len > 0 and text[0] == '|') return .{ .paths = &.{}, .with = null, .pipe = true };

    var with: ?[]const u8 = null;
    var path_part = text;
    if (std.mem.indexOf(u8, text, " WITH ")) |i| {
        path_part = std.mem.trim(u8, text[0..i], " \t");
        const w = std.mem.trim(u8, text[i + " WITH ".len ..], " \t");
        if (w.len > 0) with = w;
    }

    var paths: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, path_part, " \t");
    while (it.next()) |tok| try paths.append(a, tok);
    return .{ .paths = try paths.toOwnedSlice(a), .with = with, .pipe = false };
}

/// `~` and `~/x` -> $HOME/x. Anything else unchanged.
pub fn expandHome(a: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (path.len == 0 or path[0] != '~') return path;
    if (path.len > 1 and path[1] != '/') return path; // ~user: not supported
    const home = c.getenv("HOME") orelse return path;
    return std.fmt.allocPrint(a, "{s}{s}", .{ std.mem.span(home), path[1..] });
}

/// 'it'\''s' -- safe to put into `/bin/sh -c`.
pub fn shellQuote(a: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(a, '\'');
    for (s) |ch| {
        if (ch == '\'') {
            try out.appendSlice(a, "'\\''");
        } else try out.append(a, ch);
    }
    try out.append(a, '\'');
    return out.toOwnedSlice(a);
}

const Kind = enum { dir, file, other, missing };

fn kindOf(path: [:0]const u8) Kind {
    var st: c.struct_stat = undefined;
    if (c.stat(path.ptr, &st) != 0) return .missing;
    return switch (st.st_mode & c.S_IFMT) {
        c.S_IFDIR => .dir,
        c.S_IFREG => .file,
        else => .other,
    };
}

const Entry = struct { name: []const u8, is_dir: bool };

fn lessEntry(_: void, x: Entry, y: Entry) bool {
    if (x.is_dir != y.is_dir) return x.is_dir; // directories first
    return std.ascii.lessThanIgnoreCase(x.name, y.name);
}

/// The entries of `path`: no dot files, directories first, then by name.
/// null if it cannot be read. Never more than `max_entries_per_dir`.
fn listDir(a: std.mem.Allocator, path: [:0]const u8) ?[]Entry {
    const d = c.opendir(path.ptr) orelse return null;
    defer _ = c.closedir(d);

    var list: std.ArrayList(Entry) = .empty;
    while (c.readdir(d)) |ent| {
        const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&ent.*.d_name)), 0);
        if (name.len == 0 or name[0] == '.') continue;
        if (list.items.len >= max_entries_per_dir) break;

        const full = std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ path, name }, 0) catch return null;
        const k = kindOf(full); // follows symlinks, like a file manager
        if (k != .dir and k != .file) continue;
        list.append(a, .{ .name = a.dupe(u8, name) catch return null, .is_dir = k == .dir }) catch return null;
    }
    const items = list.toOwnedSlice(a) catch return null;
    std.mem.sort(Entry, items, {}, lessEntry);
    return items;
}

const Builder = struct {
    a: std.mem.Allocator,
    with: ?[]const u8,
    total: usize = 0,

    fn opener(b: *const Builder) []const u8 {
        return b.with orelse default_opener;
    }

    fn dirMenu(b: *Builder, path: [:0]const u8, title: []const u8, depth: u32) ?*const wm_menu.Menu {
        const entries = listDir(b.a, path) orelse return null;
        var items: std.ArrayList(wm_menu.Item) = .empty;

        for (entries) |e| {
            if (b.total >= max_total_entries) break;
            b.total += 1;
            const full = std.fmt.allocPrintSentinel(b.a, "{s}/{s}", .{ path, e.name }, 0) catch return null;
            if (e.is_dir) {
                if (depth + 1 >= max_depth) continue;
                const sub = b.dirMenu(full, e.name, depth + 1) orelse continue;
                if (sub.items.len == 0) continue; // an empty directory is not worth a submenu
                items.append(b.a, .{ .label = e.name, .action = .{ .submenu = sub } }) catch return null;
            } else {
                const q = shellQuote(b.a, full) catch return null;
                const cmd = std.fmt.allocPrint(b.a, "{s} {s}", .{ b.opener(), q }) catch return null;
                items.append(b.a, .{ .label = e.name, .action = .{ .shexec = cmd } }) catch return null;
            }
        }

        const menu = b.a.create(wm_menu.Menu) catch return null;
        menu.* = .{ .title = title, .items = items.toOwnedSlice(b.a) catch return null };
        return menu;
    }
};

/// The menu for an OPEN_MENU `spec`, or null if it cannot be made (missing
/// path, unsupported `| command`, nothing readable). The strings live in `a`
/// (an arena that the caller keeps as long as it uses the menu).
pub fn expand(a: std.mem.Allocator, arg: []const u8, title: []const u8) ?*const wm_menu.Menu {
    const spec = parseSpec(a, arg) catch return null;
    if (spec.pipe or spec.paths.len == 0) return null;

    var b: Builder = .{ .a = a, .with = spec.with };

    // One path: that directory (or file) is the menu. Several: their entries
    // together under one title.
    if (spec.paths.len == 1) {
        const p = expandHome(a, spec.paths[0]) catch return null;
        const pz = a.dupeZ(u8, p) catch return null;
        return switch (kindOf(pz)) {
            .dir => b.dirMenu(pz, title, 0),
            .file => fileMenu(a, pz),
            .other, .missing => null,
        };
    }

    var items: std.ArrayList(wm_menu.Item) = .empty;
    for (spec.paths) |raw| {
        const p = expandHome(a, raw) catch continue;
        const pz = a.dupeZ(u8, p) catch continue;
        if (kindOf(pz) != .dir) continue;
        const m = b.dirMenu(pz, std.fs.path.basename(p), 0) orelse continue;
        items.appendSlice(a, m.items) catch return null;
    }
    if (items.items.len == 0) return null;
    const menu = a.create(wm_menu.Menu) catch return null;
    menu.* = .{ .title = title, .items = items.toOwnedSlice(a) catch return null };
    return menu;
}

/// A menu file (either format), with the file's own title if it has one.
fn fileMenu(a: std.mem.Allocator, path: [:0]const u8) ?*const wm_menu.Menu {
    const text = xpm.readFile(a, path) orelse return null;
    const parsed = wm_menu.parse(a, text) catch return null;
    return parsed.menu;
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

const testing = std.testing;

const TmpTree = struct {
    path: [:0]u8,

    fn make(gpa: std.mem.Allocator) !TmpTree {
        var tmpl = "/tmp/wmaker-fsmenu-XXXXXX".*;
        const d = c.mkdtemp(&tmpl) orelse return error.MkdTemp;
        return .{ .path = try gpa.dupeZ(u8, std.mem.span(d)) };
    }

    fn file(t: TmpTree, gpa: std.mem.Allocator, rel: []const u8, content: []const u8) !void {
        const full = try std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ t.path, rel }, 0);
        defer gpa.free(full);
        // mkdir -p of every directory on the way.
        var from: usize = 0;
        while (std.mem.indexOfScalarPos(u8, rel, from, '/')) |i| : (from = i + 1) {
            const dir = try std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ t.path, rel[0..i] }, 0);
            defer gpa.free(dir);
            _ = c.mkdir(dir.ptr, 0o755);
        }
        const f = std.c.fopen(full.ptr, "wb") orelse return error.Open;
        if (content.len > 0) _ = std.c.fwrite(content.ptr, 1, content.len, f);
        _ = std.c.fclose(f);
    }

    fn cleanup(t: TmpTree, gpa: std.mem.Allocator) void {
        var buf: [128]u8 = undefined;
        if (std.fmt.bufPrintZ(&buf, "rm -rf '{s}'", .{t.path})) |z| _ = c.system(z.ptr) else |_| {}
        gpa.free(t.path);
    }
};

test "parseSpec: path, several paths, WITH, and the unsupported pipe form" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const one = try parseSpec(a, " /usr/share/doc ");
    try testing.expectEqual(@as(usize, 1), one.paths.len);
    try testing.expect(one.with == null and !one.pipe);

    const w = try parseSpec(a, "~/Pictures ~/Wallpapers WITH imv -f");
    try testing.expectEqual(@as(usize, 2), w.paths.len);
    try testing.expectEqualStrings("imv -f", w.with.?);

    try testing.expect((try parseSpec(a, "| find /x")).pipe);
    // An empty WITH is no WITH.
    try testing.expect((try parseSpec(a, "/x WITH ")).with == null);
}

test "shellQuote survives quotes and spaces" {
    const a = testing.allocator;
    const q = try shellQuote(a, "it's a file");
    defer a.free(q);
    try testing.expectEqualStrings("'it'\\''s a file'", q);
}

test "expandHome" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("/etc", try expandHome(a, "/etc"));
    try testing.expectEqualStrings("~root/x", try expandHome(a, "~root/x")); // not supported: untouched
    const h = try expandHome(a, "~/x");
    try testing.expect(std.mem.endsWith(u8, h, "/x"));
}

test "a directory becomes a menu: directories first, dot files and junk skipped" {
    const gpa = testing.allocator;
    const t = try TmpTree.make(gpa);
    defer t.cleanup(gpa);
    try t.file(gpa, "b.txt", "x");
    try t.file(gpa, "A.txt", "x");
    try t.file(gpa, ".hidden", "x");
    try t.file(gpa, "sub/inner.txt", "x");
    try t.file(gpa, "emptydir/.keep", ""); // only a dot file: no entries

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const m = expand(arena.allocator(), t.path, "Docs") orelse return error.NoMenu;
    try testing.expectEqualStrings("Docs", m.title);
    // sub (a directory) first, then A.txt, b.txt; no .hidden, no empty dir.
    try testing.expectEqual(@as(usize, 3), m.items.len);
    try testing.expectEqualStrings("sub", m.items[0].label);
    try testing.expect(m.items[0].action == .submenu);
    try testing.expectEqualStrings("A.txt", m.items[1].label);
    try testing.expectEqualStrings("b.txt", m.items[2].label);

    // A file runs through the opener, with a quoted path.
    const cmd = m.items[1].action.shexec;
    try testing.expect(std.mem.startsWith(u8, cmd, "xdg-open '"));
    try testing.expect(std.mem.endsWith(u8, cmd, "/A.txt'"));
    // The submenu has its file.
    const sub = m.items[0].action.submenu;
    try testing.expectEqual(@as(usize, 1), sub.items.len);
    try testing.expectEqualStrings("inner.txt", sub.items[0].label);
}

test "WITH picks the program that opens the files" {
    const gpa = testing.allocator;
    const t = try TmpTree.make(gpa);
    defer t.cleanup(gpa);
    try t.file(gpa, "pic one.png", "x");

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const spec = try std.fmt.allocPrint(arena.allocator(), "{s} WITH imv -f", .{t.path});
    const m = expand(arena.allocator(), spec, "Pics") orelse return error.NoMenu;
    try testing.expectEqual(@as(usize, 1), m.items.len);
    const cmd = m.items[0].action.shexec;
    try testing.expect(std.mem.startsWith(u8, cmd, "imv -f '"));
    // A name with a space is one quoted word.
    try testing.expect(std.mem.endsWith(u8, cmd, "/pic one.png'"));
}

test "directories nest to a fixed depth only" {
    const gpa = testing.allocator;
    const t = try TmpTree.make(gpa);
    defer t.cleanup(gpa);
    try t.file(gpa, "a/b/c/d/deep.txt", "x");
    try t.file(gpa, "a/b/c/shallow.txt", "x");
    try t.file(gpa, "a/top.txt", "x");

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const m = expand(arena.allocator(), t.path, "T") orelse return error.NoMenu;
    // Root (0) -> a (1) -> b (2) -> c would be depth 3: not entered.
    const a_menu = m.items[0].action.submenu;
    var found_b = false;
    for (a_menu.items) |it| {
        if (std.mem.eql(u8, it.label, "b")) {
            found_b = true;
            // `b` holds only `c`, which is cut off, so b itself is empty
            // and was dropped from `a`... unless it has files of its own.
        }
    }
    try testing.expect(!found_b);
    try testing.expectEqual(@as(usize, 1), a_menu.items.len);
    try testing.expectEqualStrings("top.txt", a_menu.items[0].label);
}

test "a menu file is included in place" {
    const gpa = testing.allocator;
    const t = try TmpTree.make(gpa);
    defer t.cleanup(gpa);
    try t.file(gpa, "extra.menu",
        \\("Extras",
        \\  ("Terminal", EXEC, "xterm"),
        \\  ("Editor", EXEC, "gedit")
        \\)
    );
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const spec = try std.fmt.allocPrint(arena.allocator(), "{s}/extra.menu", .{t.path});
    const m = expand(arena.allocator(), spec, "ignored") orelse return error.NoMenu;
    try testing.expectEqual(@as(usize, 2), m.items.len);
    try testing.expectEqualStrings("Terminal", m.items[0].label);
}

test "what cannot be made is null, never a crash: missing path, pipe, empty, binary junk" {
    const gpa = testing.allocator;
    const t = try TmpTree.make(gpa);
    defer t.cleanup(gpa);
    try t.file(gpa, "junk.menu", "\x00\x01\x02 not a menu");

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expect(expand(a, "/nonexistent/wmaker-wl/dir", "x") == null);
    try testing.expect(expand(a, "| echo hi", "x") == null);
    try testing.expect(expand(a, "", "x") == null);
    try testing.expect(expand(a, "   ", "x") == null);
    const junk = try std.fmt.allocPrint(a, "{s}/junk.menu", .{t.path});
    try testing.expect(expand(a, junk, "x") == null);
    // A character device is neither a directory nor a menu file.
    try testing.expect(expand(a, "/dev/null", "x") == null);
}

test "a directory with too many entries is cut, not hung on" {
    const gpa = testing.allocator;
    const t = try TmpTree.make(gpa);
    defer t.cleanup(gpa);
    var i: usize = 0;
    while (i < max_entries_per_dir + 50) : (i += 1) {
        var name: [24]u8 = undefined;
        const n = try std.fmt.bufPrint(&name, "f{d:0>4}.txt", .{i});
        try t.file(gpa, n, "");
    }
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const m = expand(arena.allocator(), t.path, "Big") orelse return error.NoMenu;
    try testing.expect(m.items.len <= max_entries_per_dir);
    try testing.expect(m.items.len > 0);
}
