// SPDX-License-Identifier: 0BSD
//
// The icon of an application window (for the Dock tile of a minimized
// window, dock.zig). Nothing is drawn here: every icon is a file of the
// system's own icon themes, in the order
//
//   1. an icon named like the window's app_id   (hicolor, Adwaita, ...)
//   2. the `Icon=` of the program's `<app_id>.desktop` file
//   3. a PLACEHOLDER of the icon theme ("application-x-executable", ...)
//
// Only PNG and XPM can be loaded (what gfx.Icon and xpm.zig read); an SVG-only
// theme just means "not found". If even the placeholder is missing, `get`
// returns null and the tile shows the application's first letter.
//
// The app_id comes from the client, so it only ever becomes part of a path
// when it is a plain identifier (no '/', no leading '.', see `validName`).
//
// No Wayland types in here, so it is unit-testable without a compositor.

const std = @import("std");
const gfx = @import("gfx.zig");
const xpm = @import("xpm.zig");

/// A name that is safe to put into a file name: letters, digits and . - _ +,
/// not starting with '.' or '-' (same rule as dockapp.validAppId).
pub fn validName(id: []const u8) bool {
    if (id.len == 0 or id.len > 100) return false;
    for (id) |ch| {
        const ok = std.ascii.isAlphanumeric(ch) or ch == '.' or ch == '-' or ch == '_' or ch == '+';
        if (!ok) return false;
    }
    return id[0] != '.' and id[0] != '-';
}

/// Where the files are searched. The defaults are the usual system places.
pub const Dirs = struct {
    /// Root of the icon themes: `<icons>/<theme>/<size>x<size>/<context>/<name>.png`
    /// (and the `<theme>/<context>/<size>/` layout of older themes).
    icons: []const u8 = "/usr/share/icons",
    pixmaps: []const u8 = "/usr/share/pixmaps",
    /// Directories of `<app_id>.desktop`, after the user's own one (see Cache.get).
    desktop: []const []const u8 = &.{
        "/usr/local/share/applications",
        "/usr/share/applications",
        "/var/lib/flatpak/exports/share/applications",
    },
};

const themes = [_][]const u8{ "hicolor", "Adwaita", "Humanity", "gnome", "breeze", "Papirus" };
/// Best size for a 32 px icon first.
const sizes = [_][]const u8{ "64", "48", "128", "256", "32", "24", "22", "16" };

/// What themes call "an application, nothing more specific known".
const placeholder_names = [_][]const u8{
    "application-x-executable",
    "application-default-icon",
    "application-x-generic",
    "image-missing",
};
const placeholder_contexts = [_][]const u8{ "apps", "mimetypes", "status" };
const app_contexts = [_][]const u8{"apps"};

fn loadFile(gpa: std.mem.Allocator, path: [:0]const u8) ?gfx.Icon {
    if (std.ascii.endsWithIgnoreCase(path, ".xpm")) {
        const pm = xpm.load(gpa, path) orelse return null;
        defer pm.deinit(gpa);
        return gfx.Icon.fromPixels(pm.width, pm.height, pm.pixels);
    }
    if (std.ascii.endsWithIgnoreCase(path, ".png")) return gfx.Icon.loadPng(path);
    return null;
}

/// The icon file called `name` in the themes (PNG first, then XPM).
fn findIcon(gpa: std.mem.Allocator, dirs: Dirs, name: []const u8, contexts: []const []const u8) ?gfx.Icon {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    inline for (.{ ".png", ".xpm" }) |ext| {
        for (sizes) |sz| {
            for (themes) |th| {
                for (contexts) |cx| {
                    // <theme>/<size>x<size>/<context>/ (hicolor, Adwaita, ...)
                    if (std.fmt.bufPrintZ(&buf, "{s}/{s}/{s}x{s}/{s}/{s}" ++ ext, .{ dirs.icons, th, sz, sz, cx, name })) |p| {
                        if (loadFile(gpa, p)) |ic| return ic;
                    } else |_| {}
                    // <theme>/<context>/<size>/ (Humanity and other older themes)
                    if (std.fmt.bufPrintZ(&buf, "{s}/{s}/{s}/{s}/{s}" ++ ext, .{ dirs.icons, th, cx, sz, name })) |p| {
                        if (loadFile(gpa, p)) |ic| return ic;
                    } else |_| {}
                }
            }
        }
        if (std.fmt.bufPrintZ(&buf, "{s}/{s}" ++ ext, .{ dirs.pixmaps, name })) |p| {
            if (loadFile(gpa, p)) |ic| return ic;
        } else |_| {}
    }
    return null;
}

/// The value of `Icon=` in the `[Desktop Entry]` group of a .desktop file.
pub fn desktopIcon(text: []const u8) ?[]const u8 {
    var in_entry = false;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            in_entry = std.mem.eql(u8, line, "[Desktop Entry]");
            continue;
        }
        if (!in_entry) continue;
        const key = "Icon=";
        if (!std.mem.startsWith(u8, line, key)) continue;
        const v = std.mem.trim(u8, line[key.len..], " \t");
        if (v.len == 0 or v.len > 512) return null;
        return v;
    }
    return null;
}

/// An icon value of a .desktop file: an absolute path, or a theme name.
fn loadValue(gpa: std.mem.Allocator, dirs: Dirs, value: []const u8) ?gfx.Icon {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (value[0] == '/') {
        const p = std.fmt.bufPrintZ(&buf, "{s}", .{value}) catch return null;
        return loadFile(gpa, p);
    }
    var stem = value;
    inline for (.{ ".png", ".xpm" }) |ext| {
        if (std.mem.endsWith(u8, stem, ext)) stem = stem[0 .. stem.len - ext.len];
    }
    if (!validName(stem)) return null;
    return findIcon(gpa, dirs, stem, &app_contexts);
}

/// The icon the .desktop file `<dir>/<id>.desktop` names.
fn fromDesktopFile(gpa: std.mem.Allocator, dirs: Dirs, dir: []const u8, id: []const u8) ?gfx.Icon {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrintZ(&buf, "{s}/{s}.desktop", .{ dir, id }) catch return null;
    const text = xpm.readFile(gpa, path) orelse return null;
    defer gpa.free(text);
    const value = desktopIcon(text) orelse return null;
    return loadValue(gpa, dirs, value);
}

/// Where to look: the system's icon themes and `.desktop` directories, and
/// the user's own `.desktop` directory (searched first).
pub const Search = struct {
    dirs: Dirs = .{},
    user_desktop: ?[]const u8 = null,
};

/// The icon of one application, or null. `id` must be a `validName`.
fn findForApp(gpa: std.mem.Allocator, s: Search, id: []const u8) ?gfx.Icon {
    var lower_buf: [100]u8 = undefined;
    const lower = std.ascii.lowerString(&lower_buf, id);
    const differs = !std.mem.eql(u8, lower, id);

    if (findIcon(gpa, s.dirs, id, &app_contexts)) |ic| return ic;
    if (differs) if (findIcon(gpa, s.dirs, lower, &app_contexts)) |ic| return ic;

    if (s.user_desktop) |dir| {
        if (fromDesktopFile(gpa, s.dirs, dir, id)) |ic| return ic;
        if (differs) if (fromDesktopFile(gpa, s.dirs, dir, lower)) |ic| return ic;
    }
    for (s.dirs.desktop) |dir| {
        if (fromDesktopFile(gpa, s.dirs, dir, id)) |ic| return ic;
        if (differs) if (fromDesktopFile(gpa, s.dirs, dir, lower)) |ic| return ic;
    }
    return null;
}

/// The theme's placeholder icon, or null if the system has none.
fn findPlaceholder(gpa: std.mem.Allocator, dirs: Dirs) ?gfx.Icon {
    for (placeholder_names) |name| {
        if (findIcon(gpa, dirs, name, &placeholder_contexts)) |ic| return ic;
    }
    return null;
}

/// The icon of the application `app_id`, else the theme's placeholder, else
/// null (no icon theme installed at all). The caller owns it (`deinit`).
pub fn load(gpa: std.mem.Allocator, s: Search, app_id: ?[]const u8) ?gfx.Icon {
    if (app_id) |id| if (validName(id)) {
        if (findForApp(gpa, s, id)) |ic| return ic;
    };
    return findPlaceholder(gpa, s.dirs);
}

/// `load` with the system's default places and the user's own
/// `$XDG_DATA_HOME/applications` (else `~/.local/share/applications`).
pub fn loadOwned(gpa: std.mem.Allocator, app_id: ?[]const u8) ?gfx.Icon {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var s: Search = .{};
    if (std.c.getenv("XDG_DATA_HOME")) |x| {
        const v = std.mem.span(x);
        if (v.len > 0 and v[0] == '/') s.user_desktop = std.fmt.bufPrint(&buf, "{s}/applications", .{v}) catch null;
    }
    if (s.user_desktop == null) {
        if (std.c.getenv("HOME")) |h| {
            const v = std.mem.span(h);
            if (v.len > 0) s.user_desktop = std.fmt.bufPrint(&buf, "{s}/.local/share/applications", .{v}) catch null;
        }
    }
    return load(gpa, s, app_id);
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

test "validName: plain identifiers only" {
    try std.testing.expect(validName("firefox"));
    try std.testing.expect(validName("org.gnome.Nautilus"));
    try std.testing.expect(validName("foo-bar_1+"));
    try std.testing.expect(!validName(""));
    try std.testing.expect(!validName(".hidden"));
    try std.testing.expect(!validName("-x"));
    try std.testing.expect(!validName("../etc/passwd"));
    try std.testing.expect(!validName("a/b"));
    try std.testing.expect(!validName("a b"));
    try std.testing.expect(!validName("a\x00b"));
    try std.testing.expect(!validName("a" ** 101));
}

test "desktopIcon: the Icon= of the Desktop Entry group only" {
    const text =
        \\# comment
        \\[Desktop Action new]
        \\Icon=wrong
        \\[Desktop Entry]
        \\Name=Foo
        \\Icon = nope
        \\Icon=  foo-icon  
        \\[Other]
        \\Icon=late
    ;
    try std.testing.expectEqualStrings("foo-icon", desktopIcon(text).?);
    try std.testing.expect(desktopIcon("[Desktop Entry]\nName=x\n") == null);
    try std.testing.expect(desktopIcon("Icon=outside\n") == null);
    try std.testing.expect(desktopIcon("[Desktop Entry]\nIcon=\n") == null);
}

fn testPng(path: [:0]const u8, side: c_int) !void {
    const s = gfx.c.cairo_image_surface_create(gfx.c.CAIRO_FORMAT_ARGB32, side, side) orelse return error.Cairo;
    defer gfx.c.cairo_surface_destroy(s);
    if (gfx.c.cairo_surface_write_to_png(s, path.ptr) != gfx.c.CAIRO_STATUS_SUCCESS) return error.Cairo;
}

/// Width of the icon `load` finds (0: none), freeing it again.
fn widthOf(gpa: std.mem.Allocator, s: Search, id: ?[]const u8) i32 {
    var ic = load(gpa, s, id) orelse return 0;
    defer ic.deinit();
    return ic.w;
}

test "load: app icon by name, by .desktop Icon=, then the theme's placeholder" {
    const gpa = std.testing.allocator;

    // A little icon theme and application directory under /tmp.
    var root_buf: [64:0]u8 = undefined;
    const root = try std.fmt.bufPrintZ(&root_buf, "/tmp/wmaker-appicon-test-{d}", .{std.c.getpid()});
    const dirs_to_make = [_][]const u8{
        "",
        "/icons",
        "/icons/hicolor",
        "/icons/hicolor/48x48",
        "/icons/hicolor/48x48/apps",
        "/icons/hicolor/48x48/mimetypes",
        "/pixmaps",
        "/applications",
    };
    const files = [_]struct { path: []const u8, side: c_int }{
        .{ .path = "/icons/hicolor/48x48/apps/foo.png", .side = 4 },
        .{ .path = "/icons/hicolor/48x48/apps/real-baz.png", .side = 6 },
        .{ .path = "/icons/hicolor/48x48/mimetypes/application-x-executable.png", .side = 8 },
    };
    var pbuf: [256:0]u8 = undefined;
    for (dirs_to_make) |d| {
        const p = try std.fmt.bufPrintZ(&pbuf, "{s}{s}", .{ root, d });
        _ = std.c.mkdir(p.ptr, 0o755);
    }
    for (files) |f| {
        const p = try std.fmt.bufPrintZ(&pbuf, "{s}{s}", .{ root, f.path });
        try testPng(p, f.side);
    }
    {
        const p = try std.fmt.bufPrintZ(&pbuf, "{s}/applications/baz.desktop", .{root});
        const fh = std.c.fopen(p.ptr, "wb") orelse return error.Fopen;
        const text = "[Desktop Entry]\nName=Baz\nIcon=real-baz\n";
        _ = std.c.fwrite(text.ptr, 1, text.len, fh);
        _ = std.c.fclose(fh);
    }
    defer {
        for (files) |f| {
            const p = std.fmt.bufPrintZ(&pbuf, "{s}{s}", .{ root, f.path }) catch continue;
            _ = std.c.unlink(p.ptr);
        }
        if (std.fmt.bufPrintZ(&pbuf, "{s}/applications/baz.desktop", .{root})) |p| _ = std.c.unlink(p.ptr) else |_| {}
        var i = dirs_to_make.len;
        while (i > 0) : (i -= 1) {
            const p = std.fmt.bufPrintZ(&pbuf, "{s}{s}", .{ root, dirs_to_make[i - 1] }) catch continue;
            _ = std.c.rmdir(p.ptr);
        }
    }

    var icons_dir: [128]u8 = undefined;
    var pix_dir: [128]u8 = undefined;
    var app_dir: [128]u8 = undefined;
    const apps = [_][]const u8{try std.fmt.bufPrint(&app_dir, "{s}/applications", .{root})};
    const s: Search = .{ .dirs = .{
        .icons = try std.fmt.bufPrint(&icons_dir, "{s}/icons", .{root}),
        .pixmaps = try std.fmt.bufPrint(&pix_dir, "{s}/pixmaps", .{root}),
        .desktop = &apps,
    } };

    // 1. named like the app_id (and case-insensitive: "Foo" finds foo.png)
    try std.testing.expectEqual(@as(i32, 4), widthOf(gpa, s, "foo"));
    try std.testing.expectEqual(@as(i32, 4), widthOf(gpa, s, "Foo"));
    // 2. no icon of that name, but baz.desktop says Icon=real-baz
    try std.testing.expectEqual(@as(i32, 6), widthOf(gpa, s, "baz"));
    // 3. unknown program, no app_id, invalid app_id: the placeholder
    try std.testing.expectEqual(@as(i32, 8), widthOf(gpa, s, "nothing-like-it"));
    try std.testing.expectEqual(@as(i32, 8), widthOf(gpa, s, null));
    try std.testing.expectEqual(@as(i32, 8), widthOf(gpa, s, "../../etc/passwd"));
}

test "load: no icon theme at all gives null, never a made-up icon" {
    const gpa = std.testing.allocator;
    const s: Search = .{ .dirs = .{ .icons = "/nonexistent/icons", .pixmaps = "/nonexistent/pixmaps", .desktop = &.{} } };
    try std.testing.expectEqual(@as(i32, 0), widthOf(gpa, s, "foo"));
    try std.testing.expectEqual(@as(i32, 0), widthOf(gpa, s, null));
}
