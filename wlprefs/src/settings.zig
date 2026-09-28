// SPDX-License-Identifier: 0BSD
//
// wlprefs settings layer: read/edit/write wmaker-wl's config.conf.
//
// Intentionally WITHOUT Wayland/Cairo dependency so that it can be tested in isolation.
// The format is exactly that of src/config.zig: `key = value`, `#` starts
// a comment (except in `#rrggbb` colors).
//
// Saving replaces only the lines of changed keys IN-PLACE (the rest of the
// file remains byte-identical, comments are preserved); unknown
// keys and `bind`/`unbind` are never touched. New keys are appended
// to the end. This keeps config.conf as the single source of truth
// (see docs/WMPREFS.md §5).

const std = @import("std");

pub const max_workspaces = 16;

pub const CenterMode = enum { on_overflow, always, never };
pub const NewWindowMode = enum { new_column, stack };

/// Modifier for mouse_mod. config.zig supports more combinations; the GUI
/// offers the four standard individual modifiers and leaves foreign values
/// unmodified (see `mouse_mod_raw`).
pub const MouseMod = enum {
    super,
    alt,
    ctrl,
    shift,

    pub fn text(m: MouseMod) []const u8 {
        return switch (m) {
            .super => "Super",
            .alt => "Alt",
            .ctrl => "Ctrl",
            .shift => "Shift",
        };
    }

    pub fn parse(s: []const u8) ?MouseMod {
        const eq = std.ascii.eqlIgnoreCase;
        if (eq(s, "super") or eq(s, "mod4") or eq(s, "logo")) return .super;
        if (eq(s, "alt") or eq(s, "mod1")) return .alt;
        if (eq(s, "ctrl") or eq(s, "control")) return .ctrl;
        if (eq(s, "shift")) return .shift;
        return null;
    }
};

/// All keys edited by wlprefs. Defaults = src/share/default_config.conf.
pub const Settings = struct {
    // layout
    gap: i32 = 8,
    outer_gap: i32 = 8,
    default_column_width: f64 = 0.5,
    width_step: f64 = 0.1,
    min_window_size: i32 = 120,
    center_focused_column: CenterMode = .on_overflow,
    new_window: NewWindowMode = .new_column,

    // look
    border_width: i32 = 2,
    border_focused: u32 = 0xd8a657,
    border_unfocused: u32 = 0x3c3836,
    border_floating: u32 = 0x7daea3,

    // workspaces
    workspace_count: u32 = 4,

    // floating / mouse
    drag_threshold: i32 = 24,
    floating_size: f64 = 0.6,
    focus_follows_mouse: bool = false,
    mouse_mod: MouseMod = .super,
    /// true if mouse_mod in the file is a value that the GUI cannot
    /// represent (e.g. `Super+Shift`): then the key will not be touched
    /// during saving unless the user changes it themselves.
    mouse_mod_raw: bool = false,

    // programs (as a single line, as in the file)
    terminal: Text = .{},
    launcher: Text = .{},
    browser: Text = .{},

    // wmaker compat / session
    enable_wmaker_compat: bool = false,
    enable_autostart: bool = true,
    enable_dockapps: bool = true,

    pub fn init() Settings {
        var s: Settings = .{};
        s.terminal.set("alacritty");
        s.launcher.set("fuzzel");
        s.browser.set("firefox");
        return s;
    }
};

/// Small inline text buffer (no allocator needed, suitable for GUI).
pub const Text = struct {
    buf: [160]u8 = undefined,
    len: usize = 0,

    pub fn set(t: *Text, s: []const u8) void {
        t.len = @min(s.len, t.buf.len);
        @memcpy(t.buf[0..t.len], s[0..t.len]);
    }

    pub fn get(t: *const Text) []const u8 {
        return t.buf[0..t.len];
    }

    pub fn append(t: *Text, ch: u8) void {
        if (t.len < t.buf.len) {
            t.buf[t.len] = ch;
            t.len += 1;
        }
    }

    pub fn backspace(t: *Text) void {
        if (t.len > 0) t.len -= 1;
    }
};

// ---------------------------------------------------------------------------
// Parsing -- same rules as config.zig (stripComment/applyOption)
// ---------------------------------------------------------------------------

fn isColour(s: []const u8) bool {
    if (s.len < 7 or s[0] != '#') return false;
    for (s[1..7]) |ch| if (!std.ascii.isHex(ch)) return false;
    return s.len == 7 or s[7] == ' ' or s[7] == '\t' or s[7] == '\r';
}

/// Length of content excluding comments (without trim).
fn commentStart(raw: []const u8) usize {
    for (raw, 0..) |c, i| {
        if (c != '#') continue;
        if (!(i == 0 or raw[i - 1] == ' ' or raw[i - 1] == '\t')) continue;
        if (isColour(raw[i..])) continue;
        return i;
    }
    return raw.len;
}

pub fn parseBool(s: []const u8) ?bool {
    inline for (.{ "true", "yes", "on", "1" }) |t| if (std.mem.eql(u8, s, t)) return true;
    inline for (.{ "false", "no", "off", "0" }) |t| if (std.mem.eql(u8, s, t)) return false;
    return null;
}

fn parseColour(value: []const u8) ?u32 {
    var v = std.mem.trimStart(u8, value, "#");
    if (std.mem.startsWith(u8, v, "0x")) v = v[2..];
    return std.fmt.parseInt(u32, v, 16) catch null;
}

/// Applies a single `key = value` line. Unknown/invalid entries are ignored
/// as in the compositor (the value then remains the default).
pub fn apply(s: *Settings, key: []const u8, value: []const u8) void {
    const eql = std.mem.eql;

    inline for (.{ "gap", "outer_gap", "border_width", "min_window_size", "drag_threshold" }) |name| {
        if (eql(u8, key, name)) {
            const v = std.fmt.parseInt(i32, value, 10) catch return;
            if (v >= 0) @field(s, name) = v;
            return;
        }
    }
    inline for (.{ "default_column_width", "width_step", "floating_size" }) |name| {
        if (eql(u8, key, name)) {
            const v = std.fmt.parseFloat(f64, value) catch return;
            if (v > 0 and v <= 1) @field(s, name) = v;
            return;
        }
    }
    inline for (.{ "border_focused", "border_unfocused", "border_floating" }) |name| {
        if (eql(u8, key, name)) {
            if (parseColour(value)) |c| @field(s, name) = c;
            return;
        }
    }
    inline for (.{ "focus_follows_mouse", "enable_wmaker_compat", "enable_autostart", "enable_dockapps" }) |name| {
        if (eql(u8, key, name)) {
            if (parseBool(value)) |b| @field(s, name) = b;
            return;
        }
    }
    inline for (.{ "terminal", "launcher", "browser" }) |name| {
        if (eql(u8, key, name)) {
            @field(s, name).set(value);
            return;
        }
    }

    if (eql(u8, key, "workspace_count")) {
        const v = std.fmt.parseInt(u32, value, 10) catch return;
        if (v >= 1 and v <= max_workspaces) s.workspace_count = v;
    } else if (eql(u8, key, "center_focused_column")) {
        if (std.meta.stringToEnum(CenterMode, value)) |m| s.center_focused_column = m;
    } else if (eql(u8, key, "new_window")) {
        if (std.meta.stringToEnum(NewWindowMode, value)) |m| s.new_window = m;
    } else if (eql(u8, key, "mouse_mod")) {
        if (MouseMod.parse(value)) |m| {
            s.mouse_mod = m;
            s.mouse_mod_raw = false;
        } else {
            s.mouse_mod_raw = true;
        }
    }
}

pub fn parse(s: *Settings, text: []const u8) void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const body = std.mem.trim(u8, raw[0..commentStart(raw)], " \t\r");
        if (body.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, body, '=') orelse continue;
        const key = std.mem.trim(u8, body[0..eq], " \t");
        const value = std.mem.trim(u8, body[eq + 1 ..], " \t\"");
        apply(s, key, value);
    }
}

// ---------------------------------------------------------------------------
// Writing
// ---------------------------------------------------------------------------

/// Formats the value of a key in the way config.zig reads it back.
/// Returns null for keys unknown to this layer.
pub fn format(s: *const Settings, key: []const u8, out: []u8) ?[]const u8 {
    const eql = std.mem.eql;

    inline for (.{ "gap", "outer_gap", "border_width", "min_window_size", "drag_threshold" }) |name| {
        if (eql(u8, key, name)) return std.fmt.bufPrint(out, "{d}", .{@field(s, name)}) catch null;
    }
    inline for (.{ "default_column_width", "width_step", "floating_size" }) |name| {
        if (eql(u8, key, name)) return std.fmt.bufPrint(out, "{d:.3}", .{@field(s, name)}) catch null;
    }
    inline for (.{ "border_focused", "border_unfocused", "border_floating" }) |name| {
        if (eql(u8, key, name)) return std.fmt.bufPrint(out, "{x:0>6}", .{@field(s, name)}) catch null;
    }
    inline for (.{ "focus_follows_mouse", "enable_wmaker_compat", "enable_autostart", "enable_dockapps" }) |name| {
        if (eql(u8, key, name)) return if (@field(s, name)) "true" else "false";
    }
    inline for (.{ "terminal", "launcher", "browser" }) |name| {
        if (eql(u8, key, name)) return @field(s, name).get();
    }
    if (eql(u8, key, "workspace_count")) return std.fmt.bufPrint(out, "{d}", .{s.workspace_count}) catch null;
    if (eql(u8, key, "center_focused_column")) return @tagName(s.center_focused_column);
    if (eql(u8, key, "new_window")) return @tagName(s.new_window);
    if (eql(u8, key, "mouse_mod")) return if (s.mouse_mod_raw) null else s.mouse_mod.text();
    return null;
}

/// All keys written by the GUI (order = order when appending).
pub const keys = [_][]const u8{
    "gap",              "outer_gap",            "default_column_width",
    "width_step",       "min_window_size",      "center_focused_column",
    "new_window",       "border_width",         "border_focused",
    "border_unfocused", "border_floating",      "workspace_count",
    "drag_threshold",   "floating_size",        "focus_follows_mouse",
    "mouse_mod",        "terminal",             "launcher",
    "browser",          "enable_wmaker_compat", "enable_autostart",
    "enable_dockapps",
};

/// Builds the new file content: `original` with all keys from `keys`
/// set in-place to the value from `s`. Only lines whose value has
/// actually changed (compared to `base`, the state read when loading)
/// are modified -- everything else remains byte-identical.
/// Keys missing in the file that differ from the default are appended to
/// the end. Result belongs to the caller (`gpa`).
pub fn render(
    gpa: std.mem.Allocator,
    original: []const u8,
    s: *const Settings,
    base: *const Settings,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var seen = [_]bool{false} ** keys.len;
    var vbuf: [64]u8 = undefined;
    var bbuf: [64]u8 = undefined;

    var lines = std.mem.splitScalar(u8, original, '\n');
    var first = true;
    while (lines.next()) |raw| {
        if (!first) try out.append(gpa, '\n');
        first = false;

        const cs = commentStart(raw);
        const body = std.mem.trim(u8, raw[0..cs], " \t\r");
        const eq = std.mem.indexOfScalar(u8, body, '=');
        if (body.len == 0 or eq == null) {
            try out.appendSlice(gpa, raw);
            continue;
        }
        const key = std.mem.trim(u8, body[0..eq.?], " \t");

        const idx = keyIndex(key) orelse {
            try out.appendSlice(gpa, raw);
            continue;
        };
        seen[idx] = true;

        const new_v = format(s, key, &vbuf);
        const old_v = format(base, key, &bbuf);
        const changed = if (new_v == null or old_v == null)
            (new_v == null) != (old_v == null)
        else
            !std.mem.eql(u8, new_v.?, old_v.?);

        if (!changed or new_v == null) {
            try out.appendSlice(gpa, raw);
            continue;
        }

        // Rewrite line, preserving indentation + comment.
        const indent_len = raw.len - std.mem.trimStart(u8, raw, " \t").len;
        try out.appendSlice(gpa, raw[0..indent_len]);
        try out.appendSlice(gpa, key);
        try out.appendSlice(gpa, " = ");
        try out.appendSlice(gpa, new_v.?);
        if (cs < raw.len) {
            // Preserve comment along with preceding whitespace.
            var ws = cs;
            while (ws > 0 and (raw[ws - 1] == ' ' or raw[ws - 1] == '\t')) ws -= 1;
            try out.appendSlice(gpa, "  ");
            try out.appendSlice(gpa, raw[cs..]);
        }
    }

    // Append missing keys, but only if they differ from the default
    // (otherwise saving would bloat a minimal config file).
    const def = Settings.init();
    var header_done = false;
    for (keys, 0..) |key, i| {
        if (seen[i]) continue;
        const new_v = format(s, key, &vbuf) orelse continue;
        const def_v = format(&def, key, &bbuf) orelse continue;
        if (std.mem.eql(u8, new_v, def_v)) continue;
        if (!header_done) {
            if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.append(gpa, '\n');
            try out.appendSlice(gpa, "\n# ---- set by wlprefs ----\n");
            header_done = true;
        }
        try out.appendSlice(gpa, key);
        try out.appendSlice(gpa, " = ");
        try out.appendSlice(gpa, new_v);
        try out.append(gpa, '\n');
    }

    return out.toOwnedSlice(gpa);
}

fn keyIndex(key: []const u8) ?usize {
    for (keys, 0..) |k, i| if (std.mem.eql(u8, k, key)) return i;
    return null;
}

// ---------------------------------------------------------------------------
// File + Reload
// ---------------------------------------------------------------------------

/// Sends SIGHUP to all running `wmaker-wl` processes of the user
/// (existing live-reload mechanism, see src/main.zig installSighupHandler).
/// Deliberately using `pkill`: no IPC, no PID file required.
pub fn signalReload() void {
    const argv = [_:null]?[*:0]const u8{ "pkill", "-HUP", "-x", "wmaker-wl" };
    const pid = std.os.linux.fork();
    if (std.posix.errno(pid) != .SUCCESS) return;
    if (pid == 0) {
        _ = std.os.linux.execve("/usr/bin/pkill", &argv, @ptrCast(std.c.environ));
        std.os.linux.exit(127);
    }
    var status: u32 = 0;
    _ = std.os.linux.wait4(@intCast(pid), &status, 0, null);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "parse reads values like config.zig" {
    var s = Settings.init();
    parse(&s,
        \\gap = 12   # comment
        \\border_focused = #ff0000
        \\focus_follows_mouse = yes
        \\center_focused_column = always
        \\terminal = foot -e "htop -d 5"
        \\mouse_mod = Alt
        \\workspace_count = 99
        \\
    );
    try std.testing.expectEqual(@as(i32, 12), s.gap);
    try std.testing.expectEqual(@as(u32, 0xff0000), s.border_focused);
    try std.testing.expect(s.focus_follows_mouse);
    try std.testing.expectEqual(CenterMode.always, s.center_focused_column);
    try std.testing.expectEqualStrings("foot -e \"htop -d 5\"", s.terminal.get());
    try std.testing.expectEqual(MouseMod.alt, s.mouse_mod);
    // invalid (>16) -> default remains
    try std.testing.expectEqual(@as(u32, 4), s.workspace_count);
}

test "render replaces only modified lines and preserves comments" {
    const gpa = std.testing.allocator;
    const original =
        \\# my config
        \\gap = 8                          # between windows
        \\outer_gap = 8
        \\bind = Super+q, close
        \\unknown_thing = 5
        \\focus_follows_mouse = false
        \\
    ;
    var base = Settings.init();
    parse(&base, original);
    var s = base;
    s.gap = 20;
    s.focus_follows_mouse = true;

    const out = try render(gpa, original, &s, &base);
    defer gpa.free(out);
    try std.testing.expectEqualStrings(
        \\# my config
        \\gap = 20  # between windows
        \\outer_gap = 8
        \\bind = Super+q, close
        \\unknown_thing = 5
        \\focus_follows_mouse = true
        \\
    , out);
}

test "render without changes is byte-identical" {
    const gpa = std.testing.allocator;
    const original = "gap = 8 # x\r\nfoo\n\n  border_width = 3\n";
    var base = Settings.init();
    parse(&base, original);
    const out = try render(gpa, original, &base, &base);
    defer gpa.free(out);
    try std.testing.expectEqualStrings(original, out);
}

test "render appends missing keys that differ from the default" {
    const gpa = std.testing.allocator;
    const original = "gap = 8\n";
    var base = Settings.init();
    parse(&base, original);
    var s = base;
    s.border_focused = 0x112233;
    s.workspace_count = 6; // differs
    s.gap = 8; // same -> nothing
    const out = try render(gpa, original, &s, &base);
    defer gpa.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "border_focused = 112233\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "workspace_count = 6\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "outer_gap") == null);
}

test "render round-trip: written file parses back to GUI values" {
    const gpa = std.testing.allocator;
    var base = Settings.init();
    var s = base;
    s.gap = 3;
    s.border_focused = 0xabcdef;
    s.new_window = .stack;
    s.mouse_mod = .ctrl;
    s.default_column_width = 0.667;
    s.terminal.set("foot");
    const out = try render(gpa, "", &s, &base);
    defer gpa.free(out);
    var back = Settings.init();
    parse(&back, out);
    try std.testing.expectEqual(@as(i32, 3), back.gap);
    try std.testing.expectEqual(@as(u32, 0xabcdef), back.border_focused);
    try std.testing.expectEqual(NewWindowMode.stack, back.new_window);
    try std.testing.expectEqual(MouseMod.ctrl, back.mouse_mod);
    try std.testing.expectApproxEqAbs(@as(f64, 0.667), back.default_column_width, 0.0005);
    try std.testing.expectEqualStrings("foot", back.terminal.get());
}

test "unrecognized mouse_mod is not overwritten" {
    const gpa = std.testing.allocator;
    const original = "mouse_mod = Super+Shift\n";
    var base = Settings.init();
    parse(&base, original);
    try std.testing.expect(base.mouse_mod_raw);
    const out = try render(gpa, original, &base, &base);
    defer gpa.free(out);
    try std.testing.expectEqualStrings(original, out);
}
