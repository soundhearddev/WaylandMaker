// SPDX-License-Identifier: GPL-3.0
//
// The keyboard layout the system itself is set to, for a session that nobody
// configured (a TTY has no XKB_DEFAULT_LAYOUT, and without one xkbcommon
// falls back to `us`: a German keyboard would type QWERTY).
//
// Looked at, in this order, the first that names a layout wins:
//
//   1. /etc/default/keyboard             XKBLAYOUT="de"        (Debian, Ubuntu)
//   2. /etc/X11/xorg.conf.d/00-keyboard.conf   Option "XkbLayout" "de"
//                                                              (localectl, Arch, Fedora)
//   3. /etc/vconsole.conf                XKBLAYOUT=.. or KEYMAP=de-latin1
//   4. the locale: LC_ALL / LC_MESSAGES / LANG = de_DE.UTF-8 -> de
//
// No wlroots and no xkbcommon in here: the text parsing is tested by
// `zig build test`.

const std = @import("std");
const log = std.log.scoped(.keyboard);

extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
const c_read = @extern(*const fn (c_int, [*]u8, usize) callconv(.c) isize, .{ .name = "read" });
extern "c" fn close(fd: c_int) c_int;

pub const max_name = 64;

/// NUL-terminated names, empty when unknown. Fixed buffers: this runs once at
/// start-up and needs no allocator.
pub const Names = struct {
    layout: [max_name + 1]u8 = [_]u8{0} ** (max_name + 1),
    variant: [max_name + 1]u8 = [_]u8{0} ** (max_name + 1),
    options: [max_name + 1]u8 = [_]u8{0} ** (max_name + 1),

    pub fn set(dst: *[max_name + 1]u8, value: []const u8) void {
        const n = @min(value.len, max_name);
        @memcpy(dst[0..n], value[0..n]);
        dst[n] = 0;
    }

    pub fn layoutSlice(n: *const Names) []const u8 {
        return std.mem.sliceTo(&n.layout, 0);
    }
};

pub fn read() Names {
    var names: Names = .{};
    var buf: [8192]u8 = undefined;

    if (readFile("/etc/default/keyboard", &buf)) |text| {
        fromDebian(text, &names);
        if (names.layout[0] != 0) return names;
    }
    if (readFile("/etc/X11/xorg.conf.d/00-keyboard.conf", &buf)) |text| {
        fromXorg(text, &names);
        if (names.layout[0] != 0) return names;
    }
    if (readFile("/etc/vconsole.conf", &buf)) |text| {
        fromVconsole(text, &names);
        if (names.layout[0] != 0) return names;
    }
    // Arch & co. keep the locale here; a TTY login may not have exported it.
    if (readFile("/etc/locale.conf", &buf)) |text| {
        if (shellValue(text, "LC_ALL") orelse shellValue(text, "LC_MESSAGES") orelse shellValue(text, "LANG")) |v| {
            if (localeLayout(v)) |layout| {
                Names.set(&names.layout, layout);
                log.info("no keyboard setting found, taking the layout from /etc/locale.conf ({s})", .{v});
                return names;
            }
        }
    }
    fromLocale(&names);
    return names;
}

fn readFile(path: [*:0]const u8, buf: []u8) ?[]const u8 {
    const fd = open(path, 0); // O_RDONLY
    if (fd < 0) return null;
    defer _ = close(fd);
    var len: usize = 0;
    while (len < buf.len) {
        const n = c_read(fd, buf[len..].ptr, buf.len - len);
        if (n <= 0) break;
        len += @intCast(n);
    }
    return buf[0..len];
}

// ---- parsers (pure) ------------------------------------------------------------------

/// `KEY=value` or `KEY="value"` on its own line.
fn shellValue(text: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (!std.mem.startsWith(u8, line, key)) continue;
        var rest = std.mem.trimStart(u8, line[key.len..], " \t");
        if (rest.len == 0 or rest[0] != '=') continue;
        rest = std.mem.trim(u8, rest[1..], " \t\"'");
        if (rest.len == 0) return null;
        return rest;
    }
    return null;
}

/// /etc/default/keyboard
pub fn fromDebian(text: []const u8, out: *Names) void {
    if (shellValue(text, "XKBLAYOUT")) |v| Names.set(&out.layout, v);
    if (out.layout[0] == 0) return;
    if (shellValue(text, "XKBVARIANT")) |v| Names.set(&out.variant, v);
    if (shellValue(text, "XKBOPTIONS")) |v| Names.set(&out.options, v);
}

/// /etc/vconsole.conf: XKB* if present, else the console KEYMAP.
pub fn fromVconsole(text: []const u8, out: *Names) void {
    fromDebian(text, out);
    if (out.layout[0] != 0) return;
    const keymap = shellValue(text, "KEYMAP") orelse return;
    fromConsoleKeymap(keymap, out);
}

/// `de`, `de-latin1`, `de-latin1-nodeadkeys`, `us`, `uk`, `fr-latin9`: the part
/// before the first `-` is the layout (the console calls the UK one `uk`, xkb
/// `gb`); a `nodeadkeys` in the name is the variant of that name.
pub fn fromConsoleKeymap(keymap: []const u8, out: *Names) void {
    const end = std.mem.indexOfAny(u8, keymap, "-_.") orelse keymap.len;
    var layout = keymap[0..end];
    if (layout.len < 2) return;
    if (std.mem.eql(u8, layout, "uk")) layout = "gb";
    Names.set(&out.layout, layout);
    if (std.mem.indexOf(u8, keymap, "nodeadkeys") != null) Names.set(&out.variant, "nodeadkeys");
}

/// /etc/X11/xorg.conf.d/00-keyboard.conf: `Option "XkbLayout" "de"`.
pub fn fromXorg(text: []const u8, out: *Names) void {
    if (xorgOption(text, "XkbLayout")) |v| Names.set(&out.layout, v);
    if (out.layout[0] == 0) return;
    if (xorgOption(text, "XkbVariant")) |v| Names.set(&out.variant, v);
    if (xorgOption(text, "XkbOptions")) |v| Names.set(&out.options, v);
}

fn xorgOption(text: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        // Option "XkbLayout" "de"
        const a = std.mem.indexOfScalar(u8, line, '"') orelse continue;
        const b = std.mem.indexOfScalarPos(u8, line, a + 1, '"') orelse continue;
        if (!std.mem.eql(u8, line[a + 1 .. b], name)) continue;
        const c = std.mem.indexOfScalarPos(u8, line, b + 1, '"') orelse continue;
        const d = std.mem.indexOfScalarPos(u8, line, c + 1, '"') orelse continue;
        const v = line[c + 1 .. d];
        if (v.len > 0) return v;
    }
    return null;
}

/// `de_DE.UTF-8` -> `de`, `de_AT` -> `at`, `de_CH` -> `ch`. Only the German
/// locales are guessed (a wrong guess for another language is worse than the
/// default); anyone else sets `keyboard_layout`.
pub fn fromLocale(out: *Names) void {
    const vars = [_][*:0]const u8{ "LC_ALL", "LC_MESSAGES", "LANG" };
    for (vars) |name| {
        const v = std.c.getenv(name) orelse continue;
        const text = std.mem.span(v);
        if (text.len == 0) continue;
        if (localeLayout(text)) |layout| {
            Names.set(&out.layout, layout);
            log.info("no keyboard setting found, taking the layout from the locale ({s})", .{text});
        }
        return;
    }
}

pub fn localeLayout(locale: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, locale, "de")) return null;
    if (locale.len > 2 and locale[2] != '_' and locale[2] != '.' and locale[2] != '@') return null;
    if (std.mem.startsWith(u8, locale, "de_AT")) return "at";
    if (std.mem.startsWith(u8, locale, "de_CH")) return "ch";
    return "de";
}

// ---- tests ---------------------------------------------------------------------------

const testing = std.testing;

test "Debian: /etc/default/keyboard" {
    var n: Names = .{};
    fromDebian(
        \\# KEYBOARD CONFIGURATION FILE
        \\XKBMODEL="pc105"
        \\XKBLAYOUT="de"
        \\XKBVARIANT="nodeadkeys"
        \\XKBOPTIONS="caps:escape"
        \\BACKSPACE="guess"
    , &n);
    try testing.expectEqualStrings("de", std.mem.sliceTo(&n.layout, 0));
    try testing.expectEqualStrings("nodeadkeys", std.mem.sliceTo(&n.variant, 0));
    try testing.expectEqualStrings("caps:escape", std.mem.sliceTo(&n.options, 0));
}

test "Debian: empty layout is no layout, a comment is no setting" {
    var n: Names = .{};
    fromDebian("XKBLAYOUT=\"\"\n#XKBLAYOUT=de\n", &n);
    try testing.expectEqual(@as(u8, 0), n.layout[0]);
}

test "Xorg: Option lines" {
    var n: Names = .{};
    fromXorg(
        \\Section "InputClass"
        \\        Identifier "system-keyboard"
        \\        MatchIsKeyboard "on"
        \\        Option "XkbLayout" "de"
        \\        Option "XkbModel" "pc105"
        \\        Option "XkbVariant" "nodeadkeys"
        \\EndSection
    , &n);
    try testing.expectEqualStrings("de", std.mem.sliceTo(&n.layout, 0));
    try testing.expectEqualStrings("nodeadkeys", std.mem.sliceTo(&n.variant, 0));
}

test "console keymaps" {
    var n: Names = .{};
    fromConsoleKeymap("de-latin1", &n);
    try testing.expectEqualStrings("de", n.layoutSlice());
    try testing.expectEqual(@as(u8, 0), n.variant[0]);

    var m: Names = .{};
    fromConsoleKeymap("de-latin1-nodeadkeys", &m);
    try testing.expectEqualStrings("de", m.layoutSlice());
    try testing.expectEqualStrings("nodeadkeys", std.mem.sliceTo(&m.variant, 0));

    var u: Names = .{};
    fromConsoleKeymap("uk", &u);
    try testing.expectEqualStrings("gb", u.layoutSlice());
}

test "vconsole.conf: KEYMAP" {
    var n: Names = .{};
    fromVconsole("KEYMAP=de-latin1\nFONT=eurlatgr\n", &n);
    try testing.expectEqualStrings("de", n.layoutSlice());
}

test "locale guess is German only" {
    try testing.expectEqualStrings("de", localeLayout("de_DE.UTF-8").?);
    try testing.expectEqualStrings("at", localeLayout("de_AT.UTF-8").?);
    try testing.expectEqualStrings("ch", localeLayout("de_CH").?);
    try testing.expectEqualStrings("de", localeLayout("de").?);
    try testing.expect(localeLayout("en_US.UTF-8") == null);
    try testing.expect(localeLayout("dsb_DE") == null);
    try testing.expect(localeLayout("C") == null);
}
