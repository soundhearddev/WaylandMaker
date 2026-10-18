// SPDX-License-Identifier: 0BSD
//
// The themes `theme("NAME")` can load, for the list on the Appearance page.
//
// A theme is a file `NAME.lua`. The compositor looks for it in
// `<directory of config.lua>/Themes/` first, then in
// `/usr/local/share/wmaker-wl/Themes/` and `/usr/share/wmaker-wl/Themes/`
// (config.zig, `theme_dirs`); a name found in an earlier directory hides the
// same name in a later one, here as there. Of a theme the list shows the name
// and the three frame colours it sets (what the file does not set, the
// default is shown for).

const std = @import("std");
const configfile = @import("configfile.zig");
const settings = @import("settings.zig");

const c = @cImport({
    @cInclude("dirent.h");
    @cInclude("stdlib.h");
});

pub const max_themes = 48;

pub const system_dirs = [_][]const u8{
    "/usr/local/share/wmaker-wl/Themes",
    "/usr/share/wmaker-wl/Themes",
};

pub const Theme = struct {
    name_buf: [64]u8 = undefined,
    name_len: u8 = 0,
    focused: u32 = 0,
    unfocused: u32 = 0,
    floating: u32 = 0,

    pub fn name(t: *const Theme) []const u8 {
        return t.name_buf[0..t.name_len];
    }
};

pub const List = struct {
    items: [max_themes]Theme = undefined,
    len: usize = 0,

    pub fn get(l: *const List) []const Theme {
        return l.items[0..l.len];
    }

    pub fn find(l: *const List, wanted: []const u8) ?usize {
        for (l.get(), 0..) |t, i| {
            if (std.mem.eql(u8, t.name(), wanted)) return i;
        }
        return null;
    }

    fn lessThan(_: void, a: Theme, b: Theme) bool {
        return std.mem.lessThan(u8, a.name(), b.name());
    }

    fn sort(l: *List) void {
        std.mem.sort(Theme, l.items[0..l.len], {}, lessThan);
    }
};

/// Look for themes next to `config_dir` (the directory of config.lua, null if
/// there is none) and in the system directories. `list` is replaced.
pub fn scan(gpa: std.mem.Allocator, list: *List, config_dir: ?[]const u8) void {
    list.len = 0;
    const defaults = settings.Settings.init();

    if (config_dir) |dir| {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        if (std.fmt.bufPrint(&buf, "{s}/Themes", .{dir})) |p| scanDir(gpa, list, &defaults, p) else |_| {}
    }
    for (system_dirs) |d| scanDir(gpa, list, &defaults, d);
    list.sort();
}

fn scanDir(gpa: std.mem.Allocator, list: *List, defaults: *const settings.Settings, dir: []const u8) void {
    var dir_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    const dz = std.fmt.bufPrintZ(&dir_buf, "{s}", .{dir}) catch return;
    const d = c.opendir(dz.ptr) orelse return;
    defer _ = c.closedir(d);

    while (c.readdir(d)) |ent| {
        if (list.len >= max_themes) return;
        const file = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&ent.*.d_name)), 0);
        if (!std.mem.endsWith(u8, file, ".lua")) continue;
        const stem = file[0 .. file.len - ".lua".len];
        if (!settings.validThemeName(stem)) continue;
        if (list.find(stem) != null) continue; // an earlier directory has it

        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, file }) catch continue;
        const text = switch (configfile.read(gpa, path)) {
            .text => |t| t,
            else => continue,
        };
        defer gpa.free(text);

        var st = defaults.*;
        settings.parse(&st, text);

        var t: Theme = .{ .focused = st.border_focused, .unfocused = st.border_unfocused, .floating = st.border_floating };
        @memcpy(t.name_buf[0..stem.len], stem);
        t.name_len = @intCast(stem.len);
        list.items[list.len] = t;
        list.len += 1;
    }
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

const testing = std.testing;

test "scan: user themes hide system ones of the same name, odd names and non-themes are skipped, sorted" {
    const gpa = testing.allocator;
    var tmpl = "/tmp/wlprefs-themes-XXXXXX".*;
    const made = c.mkdtemp(&tmpl) orelse return error.MkdTemp;
    const root = std.mem.span(made);
    defer {
        var cmd: [128:0]u8 = undefined;
        if (std.fmt.bufPrintZ(&cmd, "rm -rf '{s}'", .{root})) |z| _ = c.system(z.ptr) else |_| {}
    }

    const write = struct {
        fn at(g: std.mem.Allocator, dir: []const u8, name: []const u8, text: []const u8) !void {
            var b: [200]u8 = undefined;
            const p = try std.fmt.bufPrint(&b, "{s}/Themes/{s}", .{ dir, name });
            try configfile.writeAtomic(g, p, text, .{ .backup = false });
        }
    }.at;
    try write(gpa, root, "zeta.lua", "border_focused = \"#112233\"\nborder_floating = 0x445566\n");
    try write(gpa, root, "alpha.lua", "-- nothing set\n");
    try write(gpa, root, "bad name.lua", "gap = 1\n");
    try write(gpa, root, "notes.txt", "not a theme\n");
    try write(gpa, root, ".hidden.lua", "gap = 1\n");

    var list: List = .{};
    scan(gpa, &list, root);
    // Whatever the machine has in /usr/share/wmaker-wl/Themes comes too, but
    // ours are there, and in order.
    const a = list.find("alpha") orelse return error.TestExpectedTheme;
    const z = list.find("zeta") orelse return error.TestExpectedTheme;
    try testing.expect(a < z);
    try testing.expect(list.find("bad name") == null);
    try testing.expect(list.find("notes") == null);
    try testing.expect(list.find(".hidden") == null);

    const def = settings.Settings.init();
    try testing.expectEqual(def.border_focused, list.items[a].focused); // set nothing: the default
    try testing.expectEqual(@as(u32, 0x112233), list.items[z].focused);
    try testing.expectEqual(def.border_unfocused, list.items[z].unfocused);
    try testing.expectEqual(@as(u32, 0x445566), list.items[z].floating);

    // No config directory: only the system ones, and no crash.
    scan(gpa, &list, null);
    try testing.expect(list.find("zeta") == null);
}
