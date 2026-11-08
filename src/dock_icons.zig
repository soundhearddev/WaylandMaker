// SPDX-License-Identifier: GPL-3.0
//
// Which picture a Dock tile shows. Pure file work, no compositor.
//
// A tile names its icon in one of three ways, and the first that gives a
// picture wins:
//   1. the entry's `Icon` (WMState): a path (`~/` is the home directory), or
//      a bare name looked up in `icon_dirs` and then in the icon themes
//      (user, Flatpak, Nix, $XDG_DATA_DIRS: appicon.zig); PNG, XPM (Window
//      Maker's own), SVG (librsvg) and any other format gdk-pixbuf reads;
//   2. the application's system icon, found by its app_id (the entry's, else
//      the program's name) through the icon theme and its .desktop file
//      (appicon.zig); a minimized window's tile uses this only;
//   3. nothing: the tile stays empty (frame only).

const std = @import("std");

const appicon = @import("appicon.zig");
const dockapp = @import("dockapp.zig");
const gfx = @import("gfx.zig");

/// Directories searched for a bare icon name, best size first.
pub const icon_dirs = [_][]const u8{
    "/usr/share/icons/hicolor/64x64/apps",
    "/usr/share/icons/hicolor/48x48/apps",
    "/usr/share/icons/hicolor/96x96/apps",
    "/usr/share/icons/hicolor/128x128/apps",
    "/usr/share/icons/hicolor/256x256/apps",
    "/usr/share/icons/hicolor/scalable/apps",
    "/usr/share/icons/hicolor/32x32/apps",
    "/usr/local/share/icons/hicolor/64x64/apps",
    "/usr/local/share/icons/hicolor/scalable/apps",
    "/usr/share/pixmaps",
    "/usr/local/share/pixmaps",
};

/// The app_id the system icon is looked up by: the entry's own, else the
/// program's file name, else the entry's name. Null: nothing to go by.
pub fn appIdOf(app: dockapp.DockApp) ?[]const u8 {
    if (app.app_id) |id| if (id.len > 0) return id;
    if (app.command.len > 0) {
        const base = std.fs.path.basename(app.command[0]);
        if (base.len > 0) return base;
    }
    return if (app.name.len > 0) app.name else null;
}

/// `name` without a ".png" / ".svg" / ".xpm" somebody wrote anyway.
pub fn stemOf(name: []const u8) []const u8 {
    inline for (.{ ".png", ".svg", ".xpm" }) |ext| {
        if (std.ascii.endsWithIgnoreCase(name, ext)) return name[0 .. name.len - ext.len];
    }
    return name;
}

/// The icon of `app`, or null. The caller owns it (`Icon.deinit`).
pub fn resolve(gpa: std.mem.Allocator, app: dockapp.DockApp) ?gfx.Icon {
    if (app.mini_window == 0) if (app.icon) |wanted| if (wanted.len > 0) {
        if (fromKey(gpa, wanted)) |ic| return ic;
    };
    return appicon.loadOwned(gpa, appIdOf(app));
}

fn fromKey(gpa: std.mem.Allocator, wanted: []const u8) ?gfx.Icon {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    // A path: the extension decides the decoder. `~/` is the home directory
    // (nobody else expands it: WMState is not read by a shell).
    if (std.mem.indexOfScalar(u8, wanted, '/') != null) {
        const path = expandHome(&buf, wanted) orelse return null;
        return loadFile(gpa, path);
    }
    const stem = stemOf(wanted);
    inline for (.{ ".png", ".svg", ".xpm" }) |ext| {
        for (icon_dirs) |dir| {
            const path = std.fmt.bufPrintZ(&buf, "{s}/{s}" ++ ext, .{ dir, stem }) catch continue;
            if (loadFile(gpa, path)) |icon| return icon;
        }
    }
    // Not in the fixed directories: a name in any icon theme, the user's own
    // ones included (`Icon = "firefox"` is what a .desktop file says too).
    return appicon.loadNamedOwned(gpa, stem);
}

/// `path` with a leading `~/` replaced by $HOME, NUL-terminated in `buf`.
fn expandHome(buf: []u8, path: []const u8) ?[:0]const u8 {
    if (std.mem.startsWith(u8, path, "~/")) {
        const home = std.c.getenv("HOME") orelse return null;
        const h = std.mem.span(home);
        if (h.len == 0) return null;
        return std.fmt.bufPrintZ(buf, "{s}/{s}", .{ std.mem.trimEnd(u8, h, "/"), path[2..] }) catch null;
    }
    return std.fmt.bufPrintZ(buf, "{s}", .{path}) catch null;
}

pub fn loadFile(gpa: std.mem.Allocator, path: [:0]const u8) ?gfx.Icon {
    return appicon.loadFile(gpa, path);
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

const testing = std.testing;

test "appIdOf: the entry's app_id, else the program, else the name" {
    try testing.expectEqualStrings("org.x.Foo", appIdOf(.{ .name = "n", .command = &.{"/usr/bin/foo"}, .app_id = "org.x.Foo" }).?);
    try testing.expectEqualStrings("foo", appIdOf(.{ .name = "n", .command = &.{ "/usr/bin/foo", "-x" } }).?);
    try testing.expectEqualStrings("n", appIdOf(.{ .name = "n", .command = &.{} }).?);
    try testing.expect(appIdOf(.{ .name = "", .command = &.{} }) == null);
}

test "stemOf strips a known extension, case-insensitively, and nothing else" {
    try testing.expectEqualStrings("foo", stemOf("foo.png"));
    try testing.expectEqualStrings("foo", stemOf("foo.SVG"));
    try testing.expectEqualStrings("foo.bar", stemOf("foo.bar"));
    try testing.expectEqualStrings("", stemOf(".xpm"));
}

test "expandHome: only a leading ~/ is the home directory" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectEqualStrings("/a/b.png", expandHome(&buf, "/a/b.png").?);
    try testing.expectEqualStrings("x/~/b.png", expandHome(&buf, "x/~/b.png").?);
    if (std.c.getenv("HOME")) |h| {
        const home = std.mem.trimEnd(u8, std.mem.span(h), "/");
        var want: [std.fs.max_path_bytes]u8 = undefined;
        const w = try std.fmt.bufPrint(&want, "{s}/icons/a.png", .{home});
        try testing.expectEqualStrings(w, expandHome(&buf, "~/icons/a.png").?);
    }
}

test "a path in `icon` that does not exist gives no icon, and does not crash" {
    const gpa = testing.allocator;
    try testing.expect(fromKey(gpa, "/nonexistent/dir/none.png") == null);
    try testing.expect(fromKey(gpa, "/nonexistent/dir/none.xpm") == null);
    try testing.expect(fromKey(gpa, "no-such-icon-name-at-all") == null);
}
