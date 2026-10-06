// SPDX-License-Identifier: 0BSD
//
// wlprefs settings layer: read, edit and write wmaker-wl's config.conf.
//
// Deliberately free of Wayland and cairo, so it can be tested in isolation.
// It mirrors src/config.zig of the compositor rule for rule (comment
// stripping, `key = value`, value trimming, what counts as a valid value,
// the renamed options), because "what wlprefs shows" has to be exactly
// "what the compositor will use".
//
// SAVING NEVER REGENERATES THE FILE. `render()` takes the text that is on
// disk and changes only the lines of keys the user actually changed:
//
//   * every other byte stays: comments, blank lines, `bind`/`unbind`, keys
//     this program does not know, the user's own formatting, CRLF endings;
//   * a changed key keeps its position, indentation and trailing comment;
//   * a key that is not in the file yet is appended at the end, but only if
//     it differs from the default (a minimal config stays minimal);
//   * a value wlprefs cannot represent (e.g. `mouse_mod = Super+Mod5`) is
//     never touched unless the user changes it.
//
// "Changed" is decided against `base`, the settings as they were when the
// file was read. Because the caller re-reads the file right before saving
// (window.zig), an edit made to the file by hand in the meantime survives
// as long as the GUI did not change that same key.

const std = @import("std");

pub const max_workspaces = 16;

/// wmaker-wl's own default config, embedded at build time (build.zig). The
/// defaults below are *this file*, not a copy of it: a default changed in
/// the compositor changes here with the next build.
pub const default_config_text = @embedFile("default_config.conf");

pub const CenterMode = enum { on_overflow, always, never };
pub const NewWindowMode = enum { new_column, stack };
pub const DockEdge = enum { left, right };
pub const ClipCorner = enum { top_left, top_right, bottom_left, bottom_right };
pub const SubmenuAlign = enum { right, left };

/// `mouse_mod`: any combination of the four common modifiers. `raw` marks a
/// value the GUI cannot show faithfully (Mod3/Mod5, or something that does
/// not parse): the line is then left alone unless the user edits it.
pub const MouseMods = struct {
    super: bool = true,
    alt: bool = false,
    ctrl: bool = false,
    shift: bool = false,
    raw: bool = false,

    pub fn any(m: MouseMods) bool {
        return m.super or m.alt or m.ctrl or m.shift;
    }

    /// Same tokens as config.zig's parseMods. null if nothing valid.
    pub fn parse(s: []const u8) ?MouseMods {
        var m: MouseMods = .{ .super = false };
        var seen = false;
        var it = std.mem.tokenizeScalar(u8, s, '+');
        while (it.next()) |tok| {
            const t = std.mem.trim(u8, tok, " \t");
            if (t.len == 0) continue;
            seen = true;
            const eq = std.ascii.eqlIgnoreCase;
            if (eq(t, "super") or eq(t, "mod4") or eq(t, "logo")) {
                m.super = true;
            } else if (eq(t, "shift")) {
                m.shift = true;
            } else if (eq(t, "ctrl") or eq(t, "control")) {
                m.ctrl = true;
            } else if (eq(t, "alt") or eq(t, "mod1")) {
                m.alt = true;
            } else if (eq(t, "mod3") or eq(t, "mod5") or eq(t, "altgr")) {
                m.raw = true; // valid for the compositor, not for this GUI
            } else return null;
        }
        return if (seen) m else null;
    }

    pub fn format(m: MouseMods, out: []u8) ?[]const u8 {
        if (m.raw or !m.any()) return null;
        var w: std.Io.Writer = .fixed(out);
        var first = true;
        inline for (.{ .{ "Super", "super" }, .{ "Ctrl", "ctrl" }, .{ "Alt", "alt" }, .{ "Shift", "shift" } }) |p| {
            if (@field(m, p[1])) {
                if (!first) w.writeByte('+') catch return null;
                w.writeAll(p[0]) catch return null;
                first = false;
            }
        }
        return w.buffered();
    }
};

/// A small inline text buffer: no allocator, suitable for a GUI field.
pub const Text = struct {
    pub const capacity = 256;
    buf: [capacity]u8 = undefined,
    len: usize = 0,
    /// The caret: a byte index, 0..len. Not part of the value.
    pos: usize = 0,

    pub fn set(t: *Text, s: []const u8) void {
        t.len = @min(s.len, t.buf.len);
        @memcpy(t.buf[0..t.len], s[0..t.len]);
        t.pos = t.len;
    }

    pub fn get(t: *const Text) []const u8 {
        return t.buf[0..t.len];
    }

    /// Typing at the caret. Refuses what a config line cannot hold: control
    /// characters, and a `#` that would start a comment (at the start or
    /// after whitespace -- the compositor cuts the line there).
    pub fn append(t: *Text, ch: u8) void {
        if (t.len >= t.buf.len) return;
        if (ch < 0x20 or ch == 0x7f) return;
        const p = @min(t.pos, t.len);
        if (ch == '#' and (p == 0 or t.buf[p - 1] == ' ' or t.buf[p - 1] == '\t')) return;
        // A '#' typed in front of what is already there would also become
        // a comment start if that is whitespace-led -- the caret check above
        // covers the character before; the one after is not the typist's
        // problem (a `#` never turns a following char into a comment).
        std.mem.copyBackwards(u8, t.buf[p + 1 .. t.len + 1], t.buf[p..t.len]);
        t.buf[p] = ch;
        t.len += 1;
        t.pos = p + 1;
    }

    /// Backspace: the character before the caret.
    pub fn backspace(t: *Text) void {
        const p = @min(t.pos, t.len);
        if (p == 0) return;
        std.mem.copyForwards(u8, t.buf[p - 1 .. t.len - 1], t.buf[p..t.len]);
        t.len -= 1;
        t.pos = p - 1;
    }

    /// Delete: the character at the caret.
    pub fn delete(t: *Text) void {
        const p = @min(t.pos, t.len);
        if (p >= t.len) return;
        std.mem.copyForwards(u8, t.buf[p .. t.len - 1], t.buf[p + 1 .. t.len]);
        t.len -= 1;
    }

    pub fn left(t: *Text) void {
        if (t.pos > 0) t.pos = @min(t.pos, t.len) - 1;
    }

    pub fn right(t: *Text) void {
        if (t.pos < t.len) t.pos += 1;
    }

    pub fn home(t: *Text) void {
        t.pos = 0;
    }

    pub fn end(t: *Text) void {
        t.pos = t.len;
    }

    pub fn clear(t: *Text) void {
        t.len = 0;
        t.pos = 0;
    }
};

/// A theme name is a file name (config.zig has the same rule).
pub fn validThemeName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64 or name[0] == '.') return false;
    for (name) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '-' and ch != '.') return false;
    }
    return std.mem.indexOf(u8, name, "..") == null;
}

/// Every key edited by wlprefs.
pub const Settings = struct {
    // ---- layout
    gap: i32 = 8,
    outer_gap: i32 = 8,
    default_column_width: f64 = 0.5,
    /// As typed: "0.333, 0.5, 0.667, 1.0".
    width_presets: Text = .{},
    width_step: f64 = 0.1,
    min_window_size: i32 = 120,
    center_focused_column: CenterMode = .on_overflow,
    new_window: NewWindowMode = .new_column,
    focus_new_windows: bool = true,

    // ---- fonts (Pango descriptions)
    font_menu_title: Text = .{},
    font_menu: Text = .{},
    font_dock: Text = .{},

    // ---- menus
    menu_submenu_align: SubmenuAlign = .right,

    // ---- look
    border_width: i32 = 2,
    border_focused: u32 = 0xd8a657,
    border_unfocused: u32 = 0x3c3836,
    border_floating: u32 = 0x7daea3,

    // ---- workspaces
    workspace_count: u32 = 4,
    workspace_wrap: bool = true,
    clip_scroll_workspaces: bool = true,
    /// As typed: "Main, Web, Code". An empty entry means "no name".
    workspace_names: Text = .{},

    // ---- floating / mouse
    drag_threshold: i32 = 24,
    floating_size: f64 = 0.6,
    focus_follows_mouse: bool = false,
    mouse_mod: MouseMods = .{},

    // ---- programs (one line each, as in the file)
    terminal: Text = .{},
    launcher: Text = .{},
    browser: Text = .{},

    // ---- compatibility / session
    enable_wmaker_compat: bool = false,
    enable_autostart: bool = true,
    enable_dockapps: bool = true,

    // ---- keyboard / theme
    /// -1: bindings follow the active layout ("current"); 0..3: pinned.
    bind_layout: i32 = -1,
    /// Theme name ("" = none). `theme = NAME` includes Themes/NAME.conf.
    theme: Text = .{},

    // ---- Dock and Clip
    dock_enabled: bool = true,
    dock_edge: DockEdge = .right,
    dock_offset: i32 = 0,
    dock_on_top: bool = true,
    dock_reserve_space: bool = true,
    clip_enabled: bool = true,
    clip_corner: ClipCorner = .top_left,
    clip_on_top: bool = true,
    clip_collapsed: bool = false,

    /// The compositor's defaults: wmaker-wl's shipped default_config.conf.
    pub fn init() Settings {
        var s: Settings = .{};
        parse(&s, default_config_text);
        return s;
    }
};

// ----------------------------------------------------------------------------
// Parsing: the rules of config.zig
// ----------------------------------------------------------------------------

fn isColour(s: []const u8) bool {
    if (s.len < 7 or s[0] != '#') return false;
    for (s[1..7]) |ch| if (!std.ascii.isHex(ch)) return false;
    return s.len == 7 or s[7] == ' ' or s[7] == '\t' or s[7] == '\r';
}

/// Where a comment starts in `raw` (raw.len if none): a `#` at the start or
/// after whitespace, unless it introduces a `#rrggbb` colour.
fn commentStart(raw: []const u8) usize {
    for (raw, 0..) |ch, i| {
        if (ch != '#') continue;
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

/// Renamed options of the previous config format keep working in the
/// compositor; so they do here.
pub fn canonicalKey(key: []const u8) []const u8 {
    if (std.mem.eql(u8, key, "default_column_width_fraction")) return "default_column_width";
    if (std.mem.eql(u8, key, "min_column_width")) return "min_window_size";
    return key;
}

/// A Pango font description the compositor accepts (config.validFont).
pub fn validFont(text: []const u8) bool {
    if (text.len == 0 or text.len > 63) return false;
    for (text) |ch| if (ch < 0x20 or ch == 0x7f) return false;
    return true;
}

/// Is `text` a list the compositor accepts for width_presets: at least one
/// number, each in (0, 1]?
pub fn validPresets(text: []const u8) bool {
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, text, ", \t");
    while (it.next()) |tok| {
        const f = std.fmt.parseFloat(f64, tok) catch return false;
        if (!(f > 0 and f <= 1)) return false;
        n += 1;
    }
    return n > 0;
}

/// Apply one `key = value` pair. Invalid values are ignored, exactly as the
/// compositor ignores them (it then keeps the earlier/default value).
pub fn apply(s: *Settings, raw_key: []const u8, value: []const u8) void {
    const eql = std.mem.eql;
    const key = canonicalKey(raw_key);

    inline for (.{ "gap", "outer_gap", "border_width", "min_window_size", "drag_threshold", "dock_offset" }) |name| {
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
    inline for (.{
        "focus_follows_mouse", "enable_wmaker_compat", "enable_autostart",   "enable_dockapps",
        "dock_enabled",        "dock_on_top",          "dock_reserve_space", "clip_enabled",
        "clip_on_top",         "clip_collapsed",
    }) |name| {
        if (eql(u8, key, name)) {
            if (parseBool(value)) |b| @field(s, name) = b;
            return;
        }
    }
    inline for (.{ "terminal", "launcher", "browser" }) |name| {
        if (eql(u8, key, name)) {
            // The compositor rejects an empty command and keeps the old one.
            if (value.len > 0) @field(s, name).set(value);
            return;
        }
    }

    if (eql(u8, key, "width_presets")) {
        if (validPresets(value)) s.width_presets.set(value);
    } else if (eql(u8, key, "workspace_names")) {
        s.workspace_names.set(value);
    } else if (eql(u8, key, "workspace_count")) {
        const v = std.fmt.parseInt(u32, value, 10) catch return;
        if (v >= 1 and v <= max_workspaces) s.workspace_count = v;
    } else if (eql(u8, key, "center_focused_column")) {
        if (std.meta.stringToEnum(CenterMode, value)) |m| s.center_focused_column = m;
    } else if (eql(u8, key, "new_window")) {
        if (std.meta.stringToEnum(NewWindowMode, value)) |m| s.new_window = m;
    } else if (eql(u8, key, "bind_layout")) {
        if (eql(u8, value, "current") or eql(u8, value, "active")) {
            s.bind_layout = -1;
        } else if (std.fmt.parseInt(i32, value, 10)) |n| {
            if (n >= 0 and n < 4) s.bind_layout = n;
        } else |_| {}
    } else if (eql(u8, key, "theme")) {
        // An invalid name is ignored by the compositor (a warning): keep it
        // out of the GUI state too.
        if (validThemeName(value)) s.theme.set(value);
    } else if (eql(u8, key, "dock_edge")) {
        if (std.meta.stringToEnum(DockEdge, value)) |m| s.dock_edge = m;
    } else if (eql(u8, key, "clip_corner")) {
        if (std.meta.stringToEnum(ClipCorner, value)) |m| s.clip_corner = m;
    } else if (eql(u8, key, "mouse_mod")) {
        if (MouseMods.parse(value)) |m| {
            s.mouse_mod = m;
        } else {
            // The compositor keeps its default; the GUI must not "fix" it.
            s.mouse_mod.raw = true;
        }
    }
}

/// Split one line of the file the way config.zig does. null for lines that
/// carry no `key = value`.
const Line = struct {
    key: []const u8,
    value: []const u8,
    /// Where the comment starts in the raw line (raw.len if none).
    comment: usize,
};

fn splitLine(raw: []const u8) ?Line {
    const cs = commentStart(raw);
    const body = std.mem.trim(u8, raw[0..cs], " \t\r");
    if (body.len == 0) return null;
    const eq = std.mem.indexOfScalar(u8, body, '=') orelse return null;
    return .{
        .key = std.mem.trim(u8, body[0..eq], " \t"),
        .value = std.mem.trim(u8, body[eq + 1 ..], " \t\""),
        .comment = cs,
    };
}

pub fn parse(s: *Settings, text: []const u8) void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const l = splitLine(raw) orelse continue;
        apply(s, l.key, l.value);
    }
}

// ----------------------------------------------------------------------------
// Validation: what we refuse to write
// ----------------------------------------------------------------------------

pub const Problem = struct {
    key: []const u8,
    message: []const u8,
};

fn commandProblem(key: []const u8, label: []const u8, t: *const Text, storage: *[96]u8) ?Problem {
    const v = std.mem.trim(u8, t.get(), " \t");
    if (v.len == 0) {
        return .{ .key = key, .message = std.fmt.bufPrint(storage, "{s}: must not be empty", .{label}) catch "must not be empty" };
    }
    // A leading quote is stripped from the line by the compositor, which
    // changes the meaning of what follows.
    if (v[0] == '"') {
        return .{ .key = key, .message = std.fmt.bufPrint(storage, "{s}: must not start with a quote", .{label}) catch "must not start with a quote" };
    }
    return null;
}

/// The first reason the current settings cannot be saved faithfully, or
/// null. `storage` backs the returned message.
pub fn problem(s: *const Settings, storage: *[96]u8) ?Problem {
    if (commandProblem("terminal", "Terminal", &s.terminal, storage)) |p| return p;
    if (commandProblem("launcher", "Launcher", &s.launcher, storage)) |p| return p;
    if (commandProblem("browser", "Browser", &s.browser, storage)) |p| return p;
    inline for (.{
        .{ "font_menu_title", "Menu title font", &s.font_menu_title },
        .{ "font_menu", "Menu font", &s.font_menu },
        .{ "font_dock", "Clip font", &s.font_dock },
    }) |f| {
        if (!validFont(std.mem.trim(u8, f[2].get(), " \t"))) {
            return .{ .key = f[0], .message = std.fmt.bufPrint(storage, "{s}: e.g. \"Sans 10\" (1-63 characters)", .{f[1]}) catch "invalid font" };
        }
    }
    if (!validPresets(s.width_presets.get())) {
        return .{ .key = "width_presets", .message = "Presets: numbers between 0 and 1, separated by commas" };
    }
    if (!s.mouse_mod.raw and !s.mouse_mod.any()) {
        return .{ .key = "mouse_mod", .message = "Mouse: select at least one modifier" };
    }
    const th = std.mem.trim(u8, s.theme.get(), " \t");
    if (th.len > 0 and !validThemeName(th)) {
        return .{ .key = "theme", .message = "Theme: letters, digits, - _ . only (a file name)" };
    }
    return null;
}

// ----------------------------------------------------------------------------
// Formatting + rendering
// ----------------------------------------------------------------------------

/// The value of `key` as it is written to the file (no `#` before a colour;
/// render() adds one when the line already used one). null for keys this
/// layer does not know, and for values it must not write.
pub fn format(s: *const Settings, raw_key: []const u8, out: []u8) ?[]const u8 {
    const eql = std.mem.eql;
    const key = canonicalKey(raw_key);

    inline for (.{ "gap", "outer_gap", "border_width", "min_window_size", "drag_threshold", "dock_offset" }) |name| {
        if (eql(u8, key, name)) return std.fmt.bufPrint(out, "{d}", .{@field(s, name)}) catch null;
    }
    inline for (.{ "default_column_width", "width_step", "floating_size" }) |name| {
        if (eql(u8, key, name)) return std.fmt.bufPrint(out, "{d:.3}", .{@field(s, name)}) catch null;
    }
    inline for (.{ "border_focused", "border_unfocused", "border_floating" }) |name| {
        if (eql(u8, key, name)) return std.fmt.bufPrint(out, "{x:0>6}", .{@field(s, name)}) catch null;
    }
    inline for (.{
        "focus_follows_mouse", "enable_wmaker_compat", "enable_autostart",   "enable_dockapps",
        "dock_enabled",        "dock_on_top",          "dock_reserve_space", "clip_enabled",
        "clip_on_top",         "clip_collapsed",
    }) |name| {
        if (eql(u8, key, name)) return if (@field(s, name)) "true" else "false";
    }
    inline for (.{ "terminal", "launcher", "browser" }) |name| {
        if (eql(u8, key, name)) return std.mem.trim(u8, @field(s, name).get(), " \t");
    }
    inline for (.{ "font_menu_title", "font_menu", "font_dock" }) |name| {
        if (eql(u8, key, name)) return std.mem.trim(u8, @field(s, name).get(), " \t");
    }
    if (eql(u8, key, "menu_submenu_align")) return @tagName(s.menu_submenu_align);
    if (eql(u8, key, "width_presets")) return std.mem.trim(u8, s.width_presets.get(), " \t");
    if (eql(u8, key, "workspace_names")) return std.mem.trim(u8, s.workspace_names.get(), " \t");
    if (eql(u8, key, "workspace_count")) return std.fmt.bufPrint(out, "{d}", .{s.workspace_count}) catch null;
    if (eql(u8, key, "center_focused_column")) return @tagName(s.center_focused_column);
    if (eql(u8, key, "new_window")) return @tagName(s.new_window);
    if (eql(u8, key, "bind_layout")) {
        if (s.bind_layout < 0) return "current";
        return std.fmt.bufPrint(out, "{d}", .{s.bind_layout}) catch null;
    }
    if (eql(u8, key, "theme")) return std.mem.trim(u8, s.theme.get(), " \t");
    if (eql(u8, key, "dock_edge")) return @tagName(s.dock_edge);
    if (eql(u8, key, "clip_corner")) return @tagName(s.clip_corner);
    if (eql(u8, key, "mouse_mod")) return s.mouse_mod.format(out);
    return null;
}

/// All keys written by the GUI (the order is the order of appending).
pub const keys = [_][]const u8{
    "gap",                 "outer_gap",            "default_column_width",  "width_presets",
    "width_step",          "min_window_size",      "center_focused_column", "new_window",
    "border_width",        "border_focused",       "border_unfocused",      "border_floating",
    "workspace_count",     "workspace_names",      "drag_threshold",        "floating_size",
    "focus_follows_mouse", "mouse_mod",            "terminal",              "launcher",
    "browser",             "enable_wmaker_compat", "enable_autostart",      "enable_dockapps",
    "bind_layout",         "theme",                "dock_enabled",          "dock_edge",
    "dock_offset",         "dock_on_top",          "dock_reserve_space",    "clip_enabled",
    "clip_corner",         "clip_on_top",          "clip_collapsed",
};

fn keyIndex(key: []const u8) ?usize {
    const k = canonicalKey(key);
    for (keys, 0..) |name, i| if (std.mem.eql(u8, name, k)) return i;
    return null;
}

/// Do `a` and `b` hold the same value for `key`? (Compared as written.)
pub fn sameValue(a: *const Settings, b: *const Settings, key: []const u8) bool {
    var x: [64]u8 = undefined;
    var y: [64]u8 = undefined;
    const fa = format(a, key, &x);
    const fb = format(b, key, &y);
    if (fa == null or fb == null) return (fa == null) == (fb == null);
    return std.mem.eql(u8, fa.?, fb.?);
}

/// How many keys differ.
pub fn changedCount(a: *const Settings, b: *const Settings) usize {
    var n: usize = 0;
    for (keys) |k| {
        if (!sameValue(a, b, k)) n += 1;
    }
    return n;
}

/// The new file content: `original` with the keys that differ between `s`
/// and `base` changed in place. See the top of this file for the rules.
/// The result belongs to the caller (`gpa`).
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

    var lines = std.mem.splitScalar(u8, original, '\n');
    var first = true;
    while (lines.next()) |raw| {
        if (!first) try out.append(gpa, '\n');
        first = false;

        const l = splitLine(raw) orelse {
            try out.appendSlice(gpa, raw);
            continue;
        };
        const idx = keyIndex(l.key) orelse {
            try out.appendSlice(gpa, raw);
            continue;
        };
        seen[idx] = true;

        const name = keys[idx];
        // Untouched by the user, or a value we must not write: byte-identical.
        const new_v = format(s, name, &vbuf) orelse {
            try out.appendSlice(gpa, raw);
            continue;
        };
        if (sameValue(s, base, name)) {
            try out.appendSlice(gpa, raw);
            continue;
        }

        // `theme =` with nothing after it is an error for the compositor;
        // clearing the theme comments the line out instead.
        if (new_v.len == 0 and isRemovable(name)) {
            const ind = raw.len - std.mem.trimStart(u8, raw, " \t").len;
            try out.appendSlice(gpa, raw[0..ind]);
            try out.appendSlice(gpa, "# ");
            try out.appendSlice(gpa, std.mem.trimStart(u8, raw, " \t"));
            continue;
        }

        // Rewrite the line: indentation, key, value, then the old comment.
        const indent_len = raw.len - std.mem.trimStart(u8, raw, " \t").len;
        try out.appendSlice(gpa, raw[0..indent_len]);
        try out.appendSlice(gpa, name);
        try out.appendSlice(gpa, " = ");
        // A colour that was written as `#rrggbb` stays that way.
        if (isColourKey(name) and std.mem.startsWith(u8, l.value, "#")) try out.append(gpa, '#');
        try out.appendSlice(gpa, new_v);

        if (l.comment < raw.len) {
            try out.appendSlice(gpa, "  ");
            try out.appendSlice(gpa, raw[l.comment..]); // includes a trailing \r
        } else if (raw.len > 0 and raw[raw.len - 1] == '\r') {
            try out.append(gpa, '\r'); // keep CRLF files CRLF
        }
    }

    // Keys that are not in the file: append the ones that differ from the
    // default, so saving never bloats a minimal config.
    const def = Settings.init();
    var header_done = false;
    for (keys, 0..) |name, i| {
        if (seen[i]) continue;
        const new_v = format(s, name, &vbuf) orelse continue;
        if (sameValue(s, &def, name)) continue;
        if (!header_done) {
            if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.append(gpa, '\n');
            try out.appendSlice(gpa, "\n# ---- set by wlprefs ----\n");
            header_done = true;
        }
        try out.appendSlice(gpa, name);
        try out.appendSlice(gpa, " = ");
        try out.appendSlice(gpa, new_v);
        try out.append(gpa, '\n');
    }

    return out.toOwnedSlice(gpa);
}

/// Keys whose empty value means "not set": they cannot be written as `key =`.
fn isRemovable(name: []const u8) bool {
    return std.mem.eql(u8, name, "theme");
}

fn isColourKey(name: []const u8) bool {
    return std.mem.eql(u8, name, "border_focused") or
        std.mem.eql(u8, name, "border_unfocused") or
        std.mem.eql(u8, name, "border_floating");
}

/// After a save: `base` is now what the file says (`new_base`). Everything
/// the user did not change keeps following the file, so a value edited by
/// hand in the meantime shows up instead of being shown stale.
pub fn rebase(cur: *Settings, old_base: *const Settings, new_base: *const Settings) void {
    var buf: [64]u8 = undefined;
    for (keys) |k| {
        if (!sameValue(cur, old_base, k)) continue; // the user's change: keep
        if (sameValue(cur, new_base, k)) continue;
        if (format(new_base, k, &buf)) |v| apply(cur, k, v);
    }
    // `raw` mouse_mod has no text form; follow the file for that too.
    if (sameValue(cur, old_base, "mouse_mod") and new_base.mouse_mod.raw) cur.mouse_mod = new_base.mouse_mod;
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

const testing = std.testing;

test "defaults are the compositor's shipped default_config.conf" {
    const d = Settings.init();
    try testing.expectEqualStrings("alacritty", d.terminal.get());
    try testing.expectEqualStrings("fuzzel", d.launcher.get());
    try testing.expectEqualStrings("firefox", d.browser.get());
    try testing.expect(validPresets(d.width_presets.get()));
    try testing.expectEqual(@as(i32, 8), d.gap);
    try testing.expectEqual(DockEdge.right, d.dock_edge);
    try testing.expectEqual(ClipCorner.top_left, d.clip_corner);
    try testing.expect(d.dock_enabled and d.clip_enabled and d.dock_on_top and d.dock_reserve_space);
    try testing.expect(!d.clip_collapsed);
    try testing.expectEqual(@as(usize, 0), d.workspace_names.len);
}

test "the struct's own defaults agree with the shipped file (except the text fields)" {
    // The struct defaults only matter for a key the shipped file does not
    // set; this catches the two drifting apart.
    const from_file = Settings.init();
    const plain: Settings = .{};
    for (keys) |k| {
        if (std.mem.eql(u8, k, "terminal") or std.mem.eql(u8, k, "launcher") or
            std.mem.eql(u8, k, "browser") or std.mem.eql(u8, k, "width_presets")) continue;
        if (!sameValue(&from_file, &plain, k)) {
            std.debug.print("default differs for `{s}`\n", .{k});
            return error.DefaultsDiverged;
        }
    }
}

test "every key has a text form, and the key list has no duplicates" {
    var s = Settings.init();
    var buf: [64]u8 = undefined;
    for (keys, 0..) |k, i| {
        try testing.expect(format(&s, k, &buf) != null);
        for (keys[i + 1 ..]) |other| try testing.expect(!std.mem.eql(u8, k, other));
    }
}

test "parse follows config.zig, including what it ignores" {
    var s = Settings.init();
    parse(&s,
        \\gap = 12   # comment
        \\border_focused = #ff0000
        \\focus_follows_mouse = yes
        \\center_focused_column = always
        \\terminal = foot -e htop
        \\mouse_mod = Alt
        \\workspace_count = 99
        \\dock_edge = left
        \\clip_corner = bottom_right
        \\dock_offset = -4
        \\clip_corner = middle
        \\
    );
    try testing.expectEqual(@as(i32, 12), s.gap);
    try testing.expectEqual(@as(u32, 0xff0000), s.border_focused);
    try testing.expect(s.focus_follows_mouse);
    try testing.expectEqual(CenterMode.always, s.center_focused_column);
    try testing.expectEqualStrings("foot -e htop", s.terminal.get());
    try testing.expect(s.mouse_mod.alt and !s.mouse_mod.super);
    try testing.expectEqual(@as(u32, 4), s.workspace_count); // 99: ignored
    try testing.expectEqual(DockEdge.left, s.dock_edge);
    try testing.expectEqual(@as(i32, 0), s.dock_offset); // -4: ignored
    try testing.expectEqual(ClipCorner.bottom_right, s.clip_corner); // "middle": ignored
}

test "a trailing quote is trimmed from the value, exactly like the compositor does" {
    var s = Settings.init();
    parse(&s, "terminal = foot -e \"htop -d 5\"\n");
    // config.zig trims quotes at both ends of the value; parseCommand then
    // tolerates the unterminated one, so the argv is the same either way.
    try testing.expectEqualStrings("foot -e \"htop -d 5", s.terminal.get());
}

test "renamed options of the old format are understood" {
    var s = Settings.init();
    parse(&s, "default_column_width_fraction = 0.4\nmin_column_width = 200\n");
    try testing.expectApproxEqAbs(@as(f64, 0.4), s.default_column_width, 0.0001);
    try testing.expectEqual(@as(i32, 200), s.min_window_size);
}

test "mouse_mod: combinations, order, and values the GUI cannot show" {
    var m = MouseMods.parse("Super+Shift").?;
    try testing.expect(m.super and m.shift and !m.alt and !m.ctrl and !m.raw);
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("Super+Shift", m.format(&buf).?);
    m.alt = true;
    m.ctrl = true;
    try testing.expectEqualStrings("Super+Ctrl+Alt+Shift", m.format(&buf).?);
    try testing.expect(MouseMods.parse("mod4").?.super);
    try testing.expect(MouseMods.parse("Super+Mod5").?.raw);
    try testing.expect(MouseMods.parse("nonsense") == null);
    try testing.expect(MouseMods.parse("") == null);
    // Nothing selected, or raw: no text form, so nothing gets written.
    try testing.expect((MouseMods{ .super = false }).format(&buf) == null);
    try testing.expect((MouseMods{ .raw = true }).format(&buf) == null);
}

test "render replaces only modified lines and preserves comments" {
    const gpa = testing.allocator;
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
    try testing.expectEqualStrings(
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
    const gpa = testing.allocator;
    const original = "gap = 8 # x\r\nfoo\n\n  border_width = 3\n";
    var base = Settings.init();
    parse(&base, original);
    const out = try render(gpa, original, &base, &base);
    defer gpa.free(out);
    try testing.expectEqualStrings(original, out);
}

test "render keeps CRLF line endings on rewritten lines" {
    const gpa = testing.allocator;
    const original = "gap = 8\r\nouter_gap = 8\r\n";
    var base = Settings.init();
    parse(&base, original);
    var s = base;
    s.gap = 9;
    const out = try render(gpa, original, &s, &base);
    defer gpa.free(out);
    try testing.expectEqualStrings("gap = 9\r\nouter_gap = 8\r\n", out);
}

test "render keeps '#' colours as they were written, and writes plain hex otherwise" {
    const gpa = testing.allocator;
    const original = "border_focused = #112233\nborder_unfocused = 445566\n";
    var base = Settings.init();
    parse(&base, original);
    var s = base;
    s.border_focused = 0xaabbcc;
    s.border_unfocused = 0x010203;
    const out = try render(gpa, original, &s, &base);
    defer gpa.free(out);
    try testing.expectEqualStrings("border_focused = #aabbcc\nborder_unfocused = 010203\n", out);
    var back = Settings.init();
    parse(&back, out);
    try testing.expectEqual(@as(u32, 0xaabbcc), back.border_focused);
    try testing.expectEqual(@as(u32, 0x010203), back.border_unfocused);
}

test "render appends missing keys that differ from the default, only those" {
    const gpa = testing.allocator;
    const original = "gap = 8\n";
    var base = Settings.init();
    parse(&base, original);
    var s = base;
    s.border_focused = 0x112233;
    s.workspace_count = 6;
    s.dock_edge = .left;
    s.gap = 8; // same -> nothing
    const out = try render(gpa, original, &s, &base);
    defer gpa.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "border_focused = 112233\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "workspace_count = 6\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "dock_edge = left\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "outer_gap") == null);
    try testing.expect(std.mem.startsWith(u8, out, "gap = 8\n"));
}

test "render: a commented-out example line does not count as the key being set" {
    const gpa = testing.allocator;
    const original = "# workspace_names = Main, Web\ngap = 8\n";
    var base = Settings.init();
    parse(&base, original);
    var s = base;
    s.workspace_names.set("Main, Web");
    const out = try render(gpa, original, &s, &base);
    defer gpa.free(out);
    // The comment is untouched and a real line is appended.
    try testing.expect(std.mem.startsWith(u8, out, "# workspace_names = Main, Web\ngap = 8\n"));
    try testing.expect(std.mem.indexOf(u8, out, "\nworkspace_names = Main, Web\n") != null);
}

test "render: a renamed old key is rewritten in place, not duplicated" {
    const gpa = testing.allocator;
    const original = "min_column_width = 200\n";
    var base = Settings.init();
    parse(&base, original);
    var s = base;
    s.min_window_size = 300;
    const out = try render(gpa, original, &s, &base);
    defer gpa.free(out);
    try testing.expectEqualStrings("min_window_size = 300\n", out);
}

test "render round-trip: the written file parses back to the GUI values" {
    const gpa = testing.allocator;
    const base = Settings.init();
    var s = base;
    s.gap = 3;
    s.border_focused = 0xabcdef;
    s.new_window = .stack;
    s.mouse_mod = .{ .super = true, .shift = true };
    s.default_column_width = 0.667;
    s.terminal.set("foot");
    s.workspace_names.set("Main, , Web");
    s.width_presets.set("0.25, 0.5, 1");
    s.dock_offset = 120;
    s.dock_on_top = false;
    s.clip_corner = .bottom_left;
    s.clip_collapsed = true;
    const out = try render(gpa, "", &s, &base);
    defer gpa.free(out);
    var back = Settings.init();
    parse(&back, out);
    try testing.expectEqual(@as(usize, 0), changedCount(&s, &back));
}

test "an unrecognised mouse_mod is never overwritten" {
    const gpa = testing.allocator;
    const original = "mouse_mod = Super+Mod5\nmouse_mod_x = 1\n";
    var base = Settings.init();
    parse(&base, original);
    try testing.expect(base.mouse_mod.raw);
    const out = try render(gpa, original, &base, &base);
    defer gpa.free(out);
    try testing.expectEqualStrings(original, out);
    // Even with other changes made, that line stays.
    var s = base;
    s.gap = 9;
    const out2 = try render(gpa, original, &s, &base);
    defer gpa.free(out2);
    try testing.expect(std.mem.startsWith(u8, out2, "mouse_mod = Super+Mod5\n"));
}

test "an invalid value in the file is left alone unless the user changes that key" {
    const gpa = testing.allocator;
    const original = "gap = banana\nouter_gap = 8\n";
    var base = Settings.init();
    parse(&base, original);
    try testing.expectEqual(@as(i32, 8), base.gap); // default kept, like the compositor
    var s = base;
    s.outer_gap = 10;
    const out = try render(gpa, original, &s, &base);
    defer gpa.free(out);
    try testing.expectEqualStrings("gap = banana\nouter_gap = 10\n", out);
}

test "a key that appears twice: both lines follow the change (the last one wins anyway)" {
    const gpa = testing.allocator;
    const original = "gap = 4\ngap = 6\n";
    var base = Settings.init();
    parse(&base, original);
    try testing.expectEqual(@as(i32, 6), base.gap);
    var s = base;
    s.gap = 7;
    const out = try render(gpa, original, &s, &base);
    defer gpa.free(out);
    try testing.expectEqualStrings("gap = 7\ngap = 7\n", out);
}

test "an edit made to the file in the meantime survives a save of other keys" {
    const gpa = testing.allocator;
    // The GUI was opened on this ...
    const opened = "gap = 8\nouter_gap = 8\n";
    var base = Settings.init();
    parse(&base, opened);
    var s = base;
    s.gap = 12; // ... and the user changed `gap` only ...

    // ... while someone edited `outer_gap` and added a bind by hand.
    const on_disk_now = "gap = 8\nouter_gap = 30\nbind = Super+x, close\n";
    const out = try render(gpa, on_disk_now, &s, &base);
    defer gpa.free(out);
    try testing.expectEqualStrings("gap = 12\nouter_gap = 30\nbind = Super+x, close\n", out);

    // And afterwards the GUI shows the file's value for the key it didn't touch.
    var new_base = Settings.init();
    parse(&new_base, out);
    var shown = s;
    rebase(&shown, &base, &new_base);
    try testing.expectEqual(@as(i32, 12), shown.gap);
    try testing.expectEqual(@as(i32, 30), shown.outer_gap);
}

test "text fields refuse what a config line cannot hold" {
    var t: Text = .{};
    for ("foot #x") |ch| t.append(ch);
    // The '#' after a space would start a comment: not typed.
    try testing.expectEqualStrings("foot x", t.get());
    t.clear();
    t.append('#');
    try testing.expectEqual(@as(usize, 0), t.len);
    t.append('a');
    t.append('#'); // inside a word: fine (like a colour, or a URL fragment)
    t.append('\n');
    t.append(0x7f);
    try testing.expectEqualStrings("a#", t.get());
    // Full: further typing is ignored, never overflows.
    for (0..400) |_| t.append('x');
    try testing.expectEqual(t.buf.len, t.len);
}

test "problem(): what blocks a save" {
    var st: [96]u8 = undefined;
    var s = Settings.init();
    try testing.expect(problem(&s, &st) == null);

    s.terminal.set("   ");
    try testing.expectEqualStrings("terminal", problem(&s, &st).?.key);
    s.terminal.set("\"my term\" --x");
    try testing.expectEqualStrings("terminal", problem(&s, &st).?.key);
    s.terminal.set("foot -e \"htop -d 5\""); // a closing quote is fine
    try testing.expect(problem(&s, &st) == null);

    s.width_presets.set("0.5, 2");
    try testing.expectEqualStrings("width_presets", problem(&s, &st).?.key);
    s.width_presets.set("");
    try testing.expect(problem(&s, &st) != null);
    s.width_presets.set("0.5 1.0");
    try testing.expect(problem(&s, &st) == null);

    s.mouse_mod = .{ .super = false };
    try testing.expectEqualStrings("mouse_mod", problem(&s, &st).?.key);
    s.mouse_mod = .{ .raw = true, .super = false }; // not ours to judge
    try testing.expect(problem(&s, &st) == null);
}

test "validPresets" {
    try testing.expect(validPresets("0.333, 0.5, 0.667, 1.0"));
    try testing.expect(validPresets("1"));
    try testing.expect(!validPresets(""));
    try testing.expect(!validPresets(" , "));
    try testing.expect(!validPresets("0"));
    try testing.expect(!validPresets("1.5"));
    try testing.expect(!validPresets("half"));
}

test "changedCount counts keys, not bytes" {
    const a = Settings.init();
    var b = a;
    try testing.expectEqual(@as(usize, 0), changedCount(&a, &b));
    b.gap += 1;
    b.dock_edge = .left;
    b.terminal.set("foot");
    try testing.expectEqual(@as(usize, 3), changedCount(&a, &b));
}

test "bind_layout: current, pinned, invalid" {
    var s = Settings.init();
    try testing.expectEqual(@as(i32, -1), s.bind_layout);
    parse(&s, "bind_layout = 1\n");
    try testing.expectEqual(@as(i32, 1), s.bind_layout);
    parse(&s, "bind_layout = current\n");
    try testing.expectEqual(@as(i32, -1), s.bind_layout);
    parse(&s, "bind_layout = 2\nbind_layout = 9\nbind_layout = de\n");
    try testing.expectEqual(@as(i32, 2), s.bind_layout);

    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("2", format(&s, "bind_layout", &buf).?);
    s.bind_layout = -1;
    try testing.expectEqualStrings("current", format(&s, "bind_layout", &buf).?);
}

test "theme: written, validated, and clearing it comments the line out" {
    const gpa = testing.allocator;
    var base = Settings.init();
    var s = base;
    s.theme.set("nord");
    var out = try render(gpa, "gap = 8\n", &s, &base);
    try testing.expect(std.mem.indexOf(u8, out, "theme = nord\n") != null);
    gpa.free(out);

    // The file has a theme, the user clears the field.
    const original = "theme = nord   # my look\ngap = 8\n";
    base = Settings.init();
    parse(&base, original);
    try testing.expectEqualStrings("nord", base.theme.get());
    s = base;
    s.theme.clear();
    out = try render(gpa, original, &s, &base);
    defer gpa.free(out);
    try testing.expectEqualStrings("# theme = nord   # my look\ngap = 8\n", out);
    var back = Settings.init();
    parse(&back, out);
    try testing.expectEqual(@as(usize, 0), back.theme.len);

    // A name that is not a file name is refused before it is written.
    var st: [96]u8 = undefined;
    s.theme.set("../etc");
    try testing.expectEqualStrings("theme", problem(&s, &st).?.key);
    s.theme.set("my theme");
    try testing.expect(problem(&s, &st) != null);
    s.theme.set("good-theme_2");
    try testing.expect(problem(&s, &st) == null);
}

test "Text caret: insert in the middle, backspace, delete, movement" {
    var t: Text = .{};
    for ("hello") |ch| t.append(ch);
    try testing.expectEqualStrings("hello", t.get());
    try testing.expectEqual(@as(usize, 5), t.pos);

    t.left();
    t.left();
    t.append('X'); // hel|lo -> helXlo
    try testing.expectEqualStrings("helXlo", t.get());
    try testing.expectEqual(@as(usize, 4), t.pos);

    t.backspace(); // removes X
    try testing.expectEqualStrings("hello", t.get());
    t.delete(); // removes the l after the caret
    try testing.expectEqualStrings("helo", t.get());

    t.home();
    t.backspace(); // nothing before the caret
    t.left(); // and nowhere to go
    try testing.expectEqualStrings("helo", t.get());
    t.end();
    t.delete(); // nothing after
    t.right();
    try testing.expectEqualStrings("helo", t.get());
    try testing.expectEqual(@as(usize, 4), t.pos);

    // The comment rule uses the character before the CARET.
    t.set("a b");
    t.home();
    t.append('#'); // at the start: refused
    try testing.expectEqualStrings("a b", t.get());
    t.right();
    t.right(); // a |b ... after the space
    t.append('#');
    try testing.expectEqualStrings("a b", t.get());
    t.end();
    t.append('#'); // after a non-space
    try testing.expectEqualStrings("a b#", t.get());
}

test "Text: set puts the caret at the end; a full field takes no more in the middle either" {
    var t: Text = .{};
    t.set("abc");
    try testing.expectEqual(@as(usize, 3), t.pos);
    for (0..400) |_| t.append('x');
    try testing.expectEqual(Text.capacity, t.len);
    t.home();
    t.append('y'); // full: refused, nothing shifted off the end
    try testing.expectEqual(Text.capacity, t.len);
    try testing.expectEqual(@as(u8, 'a'), t.get()[0]);
}
