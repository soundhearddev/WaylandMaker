// SPDX-License-Identifier: GPL-3.0
//
// Which picture a Dock tile shows. Pure file work, no compositor.
//
// A tile names its icon in one of three ways, and the first that gives a
// picture wins:
//   1. the entry's `Icon` (WMState): a path, or a bare name looked up in
//      `icon_dirs`; PNG, SVG (through librsvg) and Window Maker's own XPM;
//   2. the application's system icon, found by its app_id (the entry's, else
//      the program's name) through the icon theme and its .desktop file
//      (appicon.zig); a minimized window's tile uses this only;
//   3. nothing: the tile draws its placeholder (dock_draw.drawPlaceholder).

const std = @import("std");

const appicon = @import("appicon.zig");
const dockapp = @import("dockapp.zig");
const gfx = @import("gfx.zig");
const svg = @import("svg.zig");
const xpm = @import("xpm.zig");

/// Directories searched for a bare icon name, best size first.
pub const icon_dirs = [_][]const u8{
    "/usr/share/icons/hicolor/64x64/apps",
    "/usr/share/icons/hicolor/48x48/apps",
    "/usr/share/icons/hicolor/128x128/apps",
    "/usr/share/icons/hicolor/256x256/apps",
    "/usr/share/icons/hicolor/32x32/apps",
    "/usr/share/pixmaps",
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
    // A path: the extension decides the decoder.
    if (std.mem.indexOfScalar(u8, wanted, '/') != null) {
        const path = std.fmt.bufPrintZ(&buf, "{s}", .{wanted}) catch return null;
        return loadFile(gpa, path);
    }
    const stem = stemOf(wanted);
    inline for (.{ ".png", ".svg", ".xpm" }) |ext| {
        for (icon_dirs) |dir| {
            const path = std.fmt.bufPrintZ(&buf, "{s}/{s}" ++ ext, .{ dir, stem }) catch continue;
            if (loadFile(gpa, path)) |icon| return icon;
        }
    }
    return null;
}

pub fn loadFile(gpa: std.mem.Allocator, path: [:0]const u8) ?gfx.Icon {
    if (std.ascii.endsWithIgnoreCase(path, ".xpm")) {
        const pm = xpm.load(gpa, path) orelse return null;
        defer pm.deinit(gpa);
        return gfx.Icon.fromPixels(pm.width, pm.height, pm.pixels);
    }
    if (std.ascii.endsWithIgnoreCase(path, ".svg")) return svg.load(path, svg.render_size);
    return gfx.Icon.loadPng(path);
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

test "a path in `icon` that does not exist gives no icon, and does not crash" {
    const gpa = testing.allocator;
    try testing.expect(fromKey(gpa, "/nonexistent/dir/none.png") == null);
    try testing.expect(fromKey(gpa, "/nonexistent/dir/none.xpm") == null);
    try testing.expect(fromKey(gpa, "no-such-icon-name-at-all") == null);
}
