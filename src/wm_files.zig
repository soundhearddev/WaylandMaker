// SPDX-License-Identifier: 0BSD
//
// Where Window Maker's configuration lives, and loading it.
//
// Window Maker keeps its files below $WMAKER_USER_ROOT, or ~/GNUstep:
//
//     ~/GNUstep/Defaults/WindowMaker           general options
//     ~/GNUstep/Defaults/WMRootMenu            root menu (property list)
//     ~/GNUstep/Defaults/WMWindowAttributes    per-application rules
//     ~/GNUstep/Defaults/WMState               dock and workspaces
//     ~/GNUstep/Library/WindowMaker/{plmenu,menu}   older root menu files
//     ~/GNUstep/Library/WindowMaker/autostart  session autostart script
//
// A file in wmaker-wl's own directory ($XDG_CONFIG_HOME/wmaker-wl/) wins over
// the Window Maker one, so wmaker-wl can be tuned without touching an existing
// Window Maker setup. Nothing is ever written back to the user's files.
//
// Loading never fails the session: a missing file means "use the defaults", a
// broken file is reported and skipped.
//
// Autostart works exactly like Window Maker's: a single shell script, run
// once, detached, when the session comes up. It is looked up (not parsed)
// the same way as the other files, so it is found automatically below either
// `~/.config/wmaker-wl/autostart` or `~/GNUstep/Library/WindowMaker/autostart`
// -- see `candidates(.autostart, ...)` and `main.zig`, which spawns it.

const std = @import("std");
const plist = @import("plist.zig");
const wm_menu = @import("wm_menu.zig");
const wm_attr = @import("wm_attr.zig");
const dockapp = @import("dockapp.zig");
const config = @import("config.zig");

/// Largest configuration file we read (1 MiB); bigger ones are refused.
const max_file: usize = 1 << 20;

/// Window Maker's user root: $WMAKER_USER_ROOT, else ~/GNUstep.
pub fn userRoot(a: std.mem.Allocator) !?[]const u8 {
    if (std.c.getenv("WMAKER_USER_ROOT")) |r| {
        const s = std.mem.span(r);
        if (s.len > 0) return try a.dupe(u8, std.mem.trimEnd(u8, s, "/"));
    }
    if (std.c.getenv("HOME")) |h| {
        return try std.fmt.allocPrint(a, "{s}/GNUstep", .{std.mem.span(h)});
    }
    return null;
}

/// wmaker-wl's own directory: $XDG_CONFIG_HOME/wmaker-wl, else ~/.config/wmaker-wl.
pub fn ownDir(a: std.mem.Allocator) !?[]const u8 {
    if (config.config_dir_override) |d| return try a.dupe(u8, std.mem.trimEnd(u8, d, "/"));
    if (std.c.getenv("XDG_CONFIG_HOME")) |x| {
        const s = std.mem.span(x);
        if (s.len > 0) return try std.fmt.allocPrint(a, "{s}/wmaker-wl", .{s});
    }
    if (std.c.getenv("HOME")) |h| {
        return try std.fmt.allocPrint(a, "{s}/.config/wmaker-wl", .{std.mem.span(h)});
    }
    return null;
}

/// Where wmaker-wl keeps what the user changed with the mouse in the Dock
/// and the Clip, as a Window Maker WMState property list:
/// `$XDG_STATE_HOME/wmaker-wl/WMState`, else
/// `~/.local/state/wmaker-wl/WMState`. Not under ~/.config on purpose:
/// wmaker-wl writes this file itself, so it must never be a file the user
/// edits, keeps in dotfiles or finds replaced after a reload.
pub fn statePath(a: std.mem.Allocator) !?[]const u8 {
    if (std.c.getenv("XDG_STATE_HOME")) |x| {
        const s = std.mem.span(x);
        if (s.len > 0) return try std.fmt.allocPrint(a, "{s}/wmaker-wl/WMState", .{s});
    }
    if (std.c.getenv("HOME")) |h| {
        return try std.fmt.allocPrint(a, "{s}/.local/state/wmaker-wl/WMState", .{std.mem.span(h)});
    }
    return null;
}

/// Write the Dock state atomically: a temporary file next to the target,
/// then rename(2) over it, so a crash or a full disk leaves the old state
/// untouched. Creates the directory. Entries that cannot be written back
/// faithfully are left out (and logged); see `dockapp.render`. The file is a WMState property list.
pub fn saveDockState(
    io: std.Io,
    gpa: std.mem.Allocator,
    path: []const u8,
    list: dockapp.List,
    state: dockapp.State,
) !void {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const skipped = try dockapp.render(&aw.writer, list, state);
    if (skipped > 0) std.log.warn("dock state: {d} entries cannot be written and were left out", .{skipped});

    const cwd = std.Io.Dir.cwd();
    if (std.fs.path.dirname(path)) |dir| try cwd.createDirPath(io, dir);
    const tmp = try std.fmt.allocPrint(gpa, "{s}.tmp", .{path});
    defer gpa.free(tmp);
    // Registered before the write: a write that fails half way (disk full)
    // must not leave the temporary file behind either.
    errdefer cwd.deleteFile(io, tmp) catch {};
    try cwd.writeFile(io, .{ .sub_path = tmp, .data = aw.written() });
    try cwd.rename(tmp, cwd, path, io);
}

/// Candidate files, best first, for one kind of configuration.
pub const Kind = enum { root_menu, window_attributes, autostart, dockapps };

pub fn candidates(a: std.mem.Allocator, kind: Kind, own: ?[]const u8, root: ?[]const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    switch (kind) {
        .root_menu => {
            if (own) |d| try list.append(a, try std.fmt.allocPrint(a, "{s}/RootMenu", .{d}));
            if (root) |d| {
                try list.append(a, try std.fmt.allocPrint(a, "{s}/Defaults/WMRootMenu", .{d}));
                try list.append(a, try std.fmt.allocPrint(a, "{s}/Library/WindowMaker/plmenu", .{d}));
                try list.append(a, try std.fmt.allocPrint(a, "{s}/Library/WindowMaker/menu", .{d}));
            }
        },
        .window_attributes => {
            if (own) |d| try list.append(a, try std.fmt.allocPrint(a, "{s}/WMWindowAttributes", .{d}));
            if (root) |d| try list.append(a, try std.fmt.allocPrint(a, "{s}/Defaults/WMWindowAttributes", .{d}));
        },
        .autostart => {
            if (own) |d| try list.append(a, try std.fmt.allocPrint(a, "{s}/autostart", .{d}));
            if (root) |d| try list.append(a, try std.fmt.allocPrint(a, "{s}/Library/WindowMaker/autostart", .{d}));
        },
        .dockapps => {
            // wmaker-wl's own copy is the state file (statePath); the only
            // other source is Window Maker's own WMState.
            if (root) |d| try list.append(a, try std.fmt.allocPrint(a, "{s}/Defaults/WMState", .{d}));
        },
    }
    return list.toOwnedSlice(a);
}

/// `wmaker-wl --paths`: every file the session looks at, grouped, in the
/// order it is tried, with `[x]` for the ones that exist. Reads nothing into
/// the session; the first existing file of a group is the one that is used.
pub fn printPaths(w: *std.Io.Writer, io: std.Io, a: std.mem.Allocator, cfg: *const config.Config) !void {
    const own = try ownDir(a);
    const root = if (cfg.enable_wmaker_compat) try userRoot(a) else null;

    try w.writeAll("[x] exists, [ ] not there; in a group the first existing file is used\n");

    try w.writeAll("\nconfig:\n");
    if (try config.userConfigPath(a)) |p| try showPath(w, io, a, p);

    try w.writeAll("\nroot menu:\n");
    for (try candidates(a, .root_menu, own, root)) |p| try showPath(w, io, a, p);

    try w.writeAll("\nwindow attributes:\n");
    for (try candidates(a, .window_attributes, own, root)) |p| try showPath(w, io, a, p);

    try w.writeAll("\nautostart:\n");
    for (try candidates(a, .autostart, own, root)) |p| try showPath(w, io, a, p);

    try w.writeAll("\nDock / Clip state (WMState):\n");
    if (cfg.dock_save_state) {
        if (try statePath(a)) |p| try showPath(w, io, a, p);
    }
    for (try candidates(a, .dockapps, own, root)) |p| try showPath(w, io, a, p);
}

fn showPath(w: *std.Io.Writer, io: std.Io, a: std.mem.Allocator, p: []const u8) !void {
    const there = readCandidate(io, a, p) != null;
    try w.print("  [{s}] {s}\n", .{ if (there) "x" else " ", p });
}

/// Read one candidate file. A missing file is normal (not every candidate
/// exists) and stays silent; anything else -- no permission, larger than
/// `max_file` -- is logged instead of making the file vanish without a trace.
fn readCandidate(io: std.Io, a: std.mem.Allocator, p: []const u8) ?[]const u8 {
    return std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, p, a, .limited(max_file)) catch |err| {
        if (!std.mem.eql(u8, @errorName(err), "FileNotFound")) {
            std.log.warn("cannot read {s}: {t}", .{ p, err });
        }
        return null;
    };
}

fn readFirst(io: std.Io, a: std.mem.Allocator, paths: []const []const u8) ?struct { path: []const u8, text: []const u8 } {
    for (paths) |p| {
        const text = readCandidate(io, a, p) orelse continue;
        return .{ .path = p, .text = text };
    }
    return null;
}

pub const Loaded = struct {
    root_menu: *const wm_menu.Menu,
    attributes: wm_attr.Table,
    /// Path of the autostart script to run once at session start, if any
    /// and if `enable_autostart` allows it. Not parsed here; `main.zig`
    /// spawns it through the shell, exactly like Window Maker does.
    autostart: ?[]const u8,
    /// DockApps to auto-launch once at session start (see dockapp.zig),
    /// empty if `enable_dockapps` disallows it or nothing was found.
    dockapps: dockapp.List,
    /// Where the Dock state is read from and saved to, or null if it is
    /// switched off (`dock_save_state = no`) or there is no home directory.
    dock_state_path: ?[]const u8,
};

/// Load the root menu, the window attributes and the autostart path.
/// Everything is allocated in `a` (the config arena, alive for the whole
/// session).
pub fn load(io: std.Io, a: std.mem.Allocator, cfg: *const config.Config) !Loaded {
    const own = try ownDir(a);
    const root = if (cfg.enable_wmaker_compat) try userRoot(a) else null;

    const state_path = if (cfg.dock_save_state) try statePath(a) else null;
    return .{
        .root_menu = try loadMenu(io, a, cfg, own, root),
        .attributes = try loadAttributes(io, a, own, root),
        .autostart = if (cfg.enable_autostart) try findAutostart(io, a, own, root) else null,
        .dockapps = if (cfg.enable_dockapps) try loadDockApps(io, a, own, root, state_path) else .{},
        .dock_state_path = state_path,
    };
}

fn loadMenu(io: std.Io, a: std.mem.Allocator, cfg: *const config.Config, own: ?[]const u8, root: ?[]const u8) !*const wm_menu.Menu {
    const paths = try candidates(a, .root_menu, own, root);

    // The first file that exists AND parses wins; a broken one is reported
    // and the next candidate is tried.
    for (paths) |p| {
        const text = readCandidate(io, a, p) orelse continue;
        var diag: plist.Diag = .{};
        if (wm_menu.parseDiag(a, text, &diag)) |parsed| {
            for (parsed.warnings) |w| std.log.warn("root menu {s}: {s}", .{ p, w });
            std.log.info("root menu: {d} entries from {s}", .{ parsed.menu.count(), p });
            return parsed.menu;
        } else |err| {
            switch (err) {
                error.Syntax => std.log.warn("root menu {s}, {f}; trying the next file", .{ p, diag }),
                else => std.log.warn("root menu {s} is unusable ({t}); trying the next file", .{ p, err }),
            }
        }
    }

    std.log.info("root menu: no file found, using the built-in one", .{});
    return wm_menu.builtinDefault(a, try join(a, cfg.terminal), try join(a, cfg.launcher), try join(a, cfg.browser));
}

fn loadAttributes(io: std.Io, a: std.mem.Allocator, own: ?[]const u8, root: ?[]const u8) !wm_attr.Table {
    const paths = try candidates(a, .window_attributes, own, root);
    const found = readFirst(io, a, paths) orelse {
        std.log.info("window attributes: no file found, no rules", .{});
        return .{};
    };
    var diag: plist.Diag = .{};
    const loaded = wm_attr.parseDiag(a, found.text, &diag) catch |err| {
        switch (err) {
            error.Syntax => std.log.warn("window attributes {s}, {f}; ignoring the file", .{ found.path, diag }),
            else => std.log.warn("window attributes {s} is unusable ({t}); ignoring it", .{ found.path, err }),
        }
        return .{};
    };
    for (loaded.warnings) |w| std.log.warn("window attributes {s}: {s}", .{ found.path, w });
    std.log.info("window attributes: {d} rules from {s}", .{ loaded.table.rules.len, found.path });
    return loaded.table;
}

/// First existing autostart script, own directory before Window Maker's
/// (see `candidates(.autostart, ...)`). The script is neither parsed nor
/// required to be executable -- `main.zig` runs it through `/bin/sh`, so a
/// missing `+x` bit does not silently do nothing the way a direct exec
/// would. Reading it here (like `readFirst` does for the other files) is
/// the cheapest existence check available through `std.Io.Dir`.
fn findAutostart(io: std.Io, a: std.mem.Allocator, own: ?[]const u8, root: ?[]const u8) !?[]const u8 {
    const paths = try candidates(a, .autostart, own, root);
    const found = readFirst(io, a, paths) orelse return null;
    std.log.info("autostart: found {s}", .{found.path});
    return found.path;
}

/// The Dock and Clip contents: ONE format, Window Maker's WMState property
/// list (see dockapp.zig). The copy wmaker-wl saved itself (`state_path`)
/// wins, because it is what the Dock looked like when the session ended;
/// then, with wmaker compatibility on, ~/GNUstep/Defaults/WMState. A broken
/// file is reported and the next candidate is tried.
fn loadDockApps(io: std.Io, a: std.mem.Allocator, own: ?[]const u8, root: ?[]const u8, state_path: ?[]const u8) !dockapp.List {
    if (state_path) |sp| if (readCandidate(io, a, sp)) |text| {
        var diag: plist.Diag = .{};
        if (dockapp.parseWMStateAllDiag(a, text, &diag)) |l| {
            if (l.state != null) {
                std.log.info("dockapps: {d} entries from the saved state {s}", .{ l.apps.len, sp });
                return l;
            }
            std.log.warn("dockapps: {s} has no Dock or Clip section; ignored", .{sp});
        } else |err| switch (err) {
            error.Syntax => std.log.warn("dockapps: saved state {s}, {f}; using the next file", .{ sp, diag }),
            else => std.log.warn("dockapps: saved state {s} is unusable ({t}); using the next file", .{ sp, err }),
        }
    };

    const paths = try candidates(a, .dockapps, own, root);
    for (paths) |p| {
        const text = readCandidate(io, a, p) orelse continue;
        var diag: plist.Diag = .{};
        if (dockapp.parseWMStateAllDiag(a, text, &diag)) |l| {
            std.log.info("dockapps: {d} entries from {s}", .{ l.apps.len, p });
            return l;
        } else |err| switch (err) {
            error.Syntax => std.log.warn("dockapps {s}, {f}; trying the next file", .{ p, diag }),
            else => std.log.warn("dockapps {s} is unusable ({t}); trying the next file", .{ p, err }),
        }
    }
    std.log.info("dockapps: no WMState found, the Dock starts empty", .{});
    return .{};
}

/// argv -> one command line, for the menu's `exec` entries. `EXEC` lines are
/// split with `config.parseCommand` (blanks separate, "double quotes" group),
/// so a word that contains a blank is put back in quotes here.
fn join(a: std.mem.Allocator, argv: []const []const u8) std.mem.Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (argv, 0..) |word, i| {
        if (i > 0) try out.append(a, ' ');
        const needs_quotes = word.len == 0 or std.mem.indexOfAny(u8, word, " \t") != null;
        // parseCommand has no escapes: a word with a `"` in it cannot be quoted.
        if (needs_quotes and std.mem.indexOfScalar(u8, word, '"') == null) {
            try out.append(a, '"');
            try out.appendSlice(a, word);
            try out.append(a, '"');
        } else try out.appendSlice(a, word);
    }
    return out.toOwnedSlice(a);
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

test "candidate order: wmaker-wl first, then Window Maker's files" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const menu = try candidates(a, .root_menu, "/h/.config/wmaker-wl", "/h/GNUstep");
    try std.testing.expectEqual(@as(usize, 4), menu.len);
    try std.testing.expectEqualStrings("/h/.config/wmaker-wl/RootMenu", menu[0]);
    try std.testing.expectEqualStrings("/h/GNUstep/Defaults/WMRootMenu", menu[1]);
    try std.testing.expectEqualStrings("/h/GNUstep/Library/WindowMaker/plmenu", menu[2]);
    try std.testing.expectEqualStrings("/h/GNUstep/Library/WindowMaker/menu", menu[3]);

    const attr = try candidates(a, .window_attributes, "/h/.config/wmaker-wl", "/h/GNUstep");
    try std.testing.expectEqual(@as(usize, 2), attr.len);
    try std.testing.expectEqualStrings("/h/GNUstep/Defaults/WMWindowAttributes", attr[1]);

    const auto = try candidates(a, .autostart, "/h/.config/wmaker-wl", "/h/GNUstep");
    try std.testing.expectEqual(@as(usize, 2), auto.len);
    try std.testing.expectEqualStrings("/h/.config/wmaker-wl/autostart", auto[0]);
    try std.testing.expectEqualStrings("/h/GNUstep/Library/WindowMaker/autostart", auto[1]);

    const dock = try candidates(a, .dockapps, "/h/.config/wmaker-wl", "/h/GNUstep");
    try std.testing.expectEqual(@as(usize, 1), dock.len);
    try std.testing.expectEqualStrings("/h/GNUstep/Defaults/WMState", dock[0]);
}

test "autostart candidates respect wmaker compat toggle (root omitted)" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Mirrors what `load()` does when enable_wmaker_compat = false: only
    // the own-directory candidate remains.
    const auto = try candidates(a, .autostart, "/h/.config/wmaker-wl", null);
    try std.testing.expectEqual(@as(usize, 1), auto.len);
    try std.testing.expectEqualStrings("/h/.config/wmaker-wl/autostart", auto[0]);
}

test "candidates without a home directory" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const none = try candidates(arena.allocator(), .root_menu, null, null);
    try std.testing.expectEqual(@as(usize, 0), none.len);
}

test "join makes one command line" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("foot -e htop", try join(arena.allocator(), &.{ "foot", "-e", "htop" }));
    // A word with blanks goes back in quotes, so parseCommand gives the same argv.
    try std.testing.expectEqualStrings("foot -e \"htop -d 5\"", try join(arena.allocator(), &.{ "foot", "-e", "htop -d 5" }));
}

test "saveDockState writes atomically and loadDockApps prefers it" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;

    const base = try std.fmt.allocPrint(a, "/tmp/wmaker-wl-state-test-{d}", .{std.c.getpid()});
    defer std.Io.Dir.cwd().deleteTree(io, base) catch {};
    const path = try std.fmt.allocPrint(a, "{s}/nested/wmaker-wl/WMState", .{base});

    const apps = [_]dockapp.DockApp{
        .{ .name = "term", .command = &.{"foot"}, .y = 0 },
        .{ .name = "notes", .command = &.{"notes"}, .place = .clip, .workspace = 1 },
    };
    const st: dockapp.State = .{ .edge = .left, .clip_collapsed = true };
    try saveDockState(io, std.testing.allocator, path, .{ .apps = &apps }, st);
    // Saving again replaces it and leaves no temporary file behind.
    try saveDockState(io, std.testing.allocator, path, .{ .apps = apps[0..1] }, .{ .edge = .right });
    try saveDockState(io, std.testing.allocator, path, .{ .apps = &apps }, st);
    const tmp = try std.fmt.allocPrint(a, "{s}.tmp", .{path});
    try std.testing.expect(readCandidate(io, a, tmp) == null);

    const list = try loadDockApps(io, a, null, null, path);
    try std.testing.expectEqual(@as(usize, 2), list.apps.len);
    try std.testing.expectEqual(config.DockEdge.left, list.state.?.edge.?);
    try std.testing.expectEqual(@as(?u32, 1), list.apps[1].workspace);

    // A saved empty Dock stays empty: it does not fall back to anything.
    try saveDockState(io, std.testing.allocator, path, .{}, .{});
    const empty = try loadDockApps(io, a, null, null, path);
    try std.testing.expectEqual(@as(usize, 0), empty.apps.len);
    try std.testing.expect(empty.state != null);

    // No state file: nothing found (and no crash).
    const none = try loadDockApps(io, a, null, null, try std.fmt.allocPrint(a, "{s}/missing", .{base}));
    try std.testing.expect(none.state == null);
    try std.testing.expect(none.isEmpty());
}
