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
const config = @import("config.zig");

const max_file = 1 << 20;

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
    if (std.c.getenv("XDG_CONFIG_HOME")) |x| {
        const s = std.mem.span(x);
        if (s.len > 0) return try std.fmt.allocPrint(a, "{s}/wmaker-wl", .{s});
    }
    if (std.c.getenv("HOME")) |h| {
        return try std.fmt.allocPrint(a, "{s}/.config/wmaker-wl", .{std.mem.span(h)});
    }
    return null;
}

/// Candidate files, best first, for one kind of configuration.
pub const Kind = enum { root_menu, window_attributes, autostart };

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
    }
    return list.toOwnedSlice(a);
}

fn readFirst(io: std.Io, a: std.mem.Allocator, paths: []const []const u8) ?struct { path: []const u8, text: []const u8 } {
    for (paths) |p| {
        const text = std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, p, a, .limited(max_file)) catch continue;
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
};

/// Load the root menu, the window attributes and the autostart path.
/// Everything is allocated in `a` (the config arena, alive for the whole
/// session).
pub fn load(io: std.Io, a: std.mem.Allocator, cfg: *const config.Config) !Loaded {
    const own = try ownDir(a);
    const root = if (cfg.enable_wmaker_compat) try userRoot(a) else null;

    return .{
        .root_menu = try loadMenu(io, a, cfg, own, root),
        .attributes = try loadAttributes(io, a, own, root),
        .autostart = if (cfg.enable_autostart) try findAutostart(io, a, own, root) else null,
    };
}

fn loadMenu(io: std.Io, a: std.mem.Allocator, cfg: *const config.Config, own: ?[]const u8, root: ?[]const u8) !*const wm_menu.Menu {
    const paths = try candidates(a, .root_menu, own, root);

    // The first file that exists AND parses wins; a broken one is reported
    // and the next candidate is tried.
    for (paths) |p| {
        const text = std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, p, a, .limited(max_file)) catch continue;
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
    return wm_menu.builtinDefault(a, join(a, cfg.terminal), join(a, cfg.launcher), join(a, cfg.browser));
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

/// argv -> one command line, for the menu's `exec` entries.
fn join(a: std.mem.Allocator, argv: []const []const u8) []const u8 {
    return std.mem.join(a, " ", argv) catch "";
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
    try std.testing.expectEqualStrings("foot -e htop", join(arena.allocator(), &.{ "foot", "-e", "htop" }));
}
