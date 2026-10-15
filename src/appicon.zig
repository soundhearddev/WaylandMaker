// SPDX-License-Identifier: 0BSD
//
// The icon of an application window (for the strip of minimized windows,
// miniwin.zig). Nothing is drawn here: every icon is a file of the system's
// own icon themes, in the order
//
//   1. an icon named like the window's app_id   (hicolor, Adwaita, ...)
//   2. the `Icon=` of the program's `<app_id>.desktop` file
//   3. a PLACEHOLDER of the icon theme ("application-x-executable", ...)
//
// Only PNG and XPM can be loaded (what gfx.Icon and xpm.zig read); an SVG-only
// theme just means "not found". If even the placeholder is missing, `get`
// returns null and the caller shows the application's first letter.
//
// The app_id comes from the client, so it only ever becomes part of a path
// when it is a plain identifier (no '/', no leading '.', see `validName`).
//
// No Wayland types in here, so it is unit-testable without a compositor.

const std = @import("std");
const gfx = @import("gfx.zig");
const xpm = @import("xpm.zig");

/// Most applications whose icon is remembered; more get the placeholder.
pub const max_cached: usize = 256;

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

/// The icon of one application, or null. `id` must be a `validName`.
fn findForApp(gpa: std.mem.Allocator, c: *Cache, id: []const u8) ?gfx.Icon {
    var lower_buf: [100]u8 = undefined;
    const lower = std.ascii.lowerString(&lower_buf, id);

    if (findIcon(gpa, c.dirs, id, &app_contexts)) |ic| return ic;
    if (!std.mem.eql(u8, lower, id)) {
        if (findIcon(gpa, c.dirs, lower, &app_contexts)) |ic| return ic;
    }

    c.loadUserDir(gpa);
    if (c.user_desktop) |dir| {
        if (fromDesktopFile(gpa, c.dirs, dir, id)) |ic| return ic;
        if (!std.mem.eql(u8, lower, id)) if (fromDesktopFile(gpa, c.dirs, dir, lower)) |ic| return ic;
    }
    for (c.dirs.desktop) |dir| {
        if (fromDesktopFile(gpa, c.dirs, dir, id)) |ic| return ic;
        if (!std.mem.eql(u8, lower, id)) if (fromDesktopFile(gpa, c.dirs, dir, lower)) |ic| return ic;
    }
    return null;
}

/// What was found so far, per app_id. Owns its icons: the ones `get`
/// returns are valid until `deinit`.
pub const Cache = struct {
    /// null = looked for, nothing found (the placeholder is shown).
    map: std.StringHashMapUnmanaged(?gfx.Icon) = .empty,
    placeholder: ?gfx.Icon = null,
    placeholder_tried: bool = false,
    dirs: Dirs = .{},
    /// `$XDG_DATA_HOME/applications` (else `~/.local/share/applications`).
    user_desktop: ?[]u8 = null,
    user_tried: bool = false,

    pub fn deinit(c: *Cache, gpa: std.mem.Allocator) void {
        var it = c.map.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.*) |*ic| ic.deinit();
            gpa.free(e.key_ptr.*);
        }
        c.map.deinit(gpa);
        if (c.placeholder) |*ic| ic.deinit();
        if (c.user_desktop) |d| gpa.free(d);
        c.* = .{};
    }

    fn loadUserDir(c: *Cache, gpa: std.mem.Allocator) void {
        if (c.user_tried) return;
        c.user_tried = true;
        if (std.c.getenv("XDG_DATA_HOME")) |x| {
            const s = std.mem.span(x);
            if (s.len > 0 and s[0] == '/') {
                c.user_desktop = std.fmt.allocPrint(gpa, "{s}/applications", .{s}) catch null;
                return;
            }
        }
        if (std.c.getenv("HOME")) |h| {
            const s = std.mem.span(h);
            if (s.len > 0) c.user_desktop = std.fmt.allocPrint(gpa, "{s}/.local/share/applications", .{s}) catch null;
        }
    }

    fn getPlaceholder(c: *Cache, gpa: std.mem.Allocator) ?gfx.Icon {
        if (!c.placeholder_tried) {
            c.placeholder_tried = true;
            for (placeholder_names) |name| {
                if (findIcon(gpa, c.dirs, name, &placeholder_contexts)) |ic| {
                    c.placeholder = ic;
                    break;
                }
            }
            if (c.placeholder == null) std.log.warn("appicon: no placeholder icon found in {s}", .{c.dirs.icons});
        }
        return c.placeholder;
    }

    /// The icon of the application `app_id`, else the theme's placeholder,
    /// else null (no icon theme installed at all).
    pub fn get(c: *Cache, gpa: std.mem.Allocator, app_id: ?[]const u8) ?gfx.Icon {
        if (app_id) |id| if (validName(id)) {
            if (c.map.get(id)) |hit| return hit orelse c.getPlaceholder(gpa);
            if (c.map.count() < max_cached) {
                var found = findForApp(gpa, c, id);
                const key = gpa.dupe(u8, id) catch {
                    if (found) |*ic| ic.deinit();
                    return c.getPlaceholder(gpa);
                };
                c.map.put(gpa, key, found) catch {
                    gpa.free(key);
                    if (found) |*ic| ic.deinit();
                    return c.getPlaceholder(gpa);
                };
                return found orelse c.getPlaceholder(gpa);
            }
        };
        return c.getPlaceholder(gpa);
    }
};

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

test "Cache: app icon by name, by .desktop Icon=, then the theme's placeholder" {
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
    var cache: Cache = .{ .dirs = .{
        .icons = try std.fmt.bufPrint(&icons_dir, "{s}/icons", .{root}),
        .pixmaps = try std.fmt.bufPrint(&pix_dir, "{s}/pixmaps", .{root}),
        .desktop = &apps,
    } };
    defer cache.deinit(gpa);

    // 1. named like the app_id (and case-insensitive: "Foo" finds foo.png)
    try std.testing.expectEqual(@as(i32, 4), cache.get(gpa, "foo").?.w);
    try std.testing.expectEqual(@as(i32, 4), cache.get(gpa, "Foo").?.w);
    // 2. no icon of that name, but baz.desktop says Icon=real-baz
    try std.testing.expectEqual(@as(i32, 6), cache.get(gpa, "baz").?.w);
    // 3. unknown program, no app_id, invalid app_id: the placeholder
    try std.testing.expectEqual(@as(i32, 8), cache.get(gpa, "nothing-like-it").?.w);
    try std.testing.expectEqual(@as(i32, 8), cache.get(gpa, null).?.w);
    try std.testing.expectEqual(@as(i32, 8), cache.get(gpa, "../../etc/passwd").?.w);
    // asking again gives the same icon without searching again
    try std.testing.expectEqual(@as(i32, 4), cache.get(gpa, "foo").?.w);
    try std.testing.expectEqual(@as(usize, 4), cache.map.count());
}

test "Cache: no icon theme at all gives null, never a made-up icon" {
    const gpa = std.testing.allocator;
    var cache: Cache = .{ .dirs = .{ .icons = "/nonexistent/icons", .pixmaps = "/nonexistent/pixmaps", .desktop = &.{} } };
    defer cache.deinit(gpa);
    try std.testing.expect(cache.get(gpa, "foo") == null);
    try std.testing.expect(cache.get(gpa, null) == null);
}
