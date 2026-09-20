// SPDX-License-Identifier: 0BSD
//
// Configuration for wmaker-wl.
//
// This is the single source of truth for every tunable. Nothing else in
// the code base may hard-code a gap, border, colour or command.
//
// File: $XDG_CONFIG_HOME/wmaker-wl/config.conf
//       (falls back to ~/.config/wmaker-wl/config.conf)
//
// Format: `key = value`. `#` starts a comment when it is at the start of a
// line or preceded by whitespace (so `border_focused = #d8a657` works).
//
//     bind = Super+Shift+h, move_column_left
//     bind = Super+Return, spawn alacritty --class foo
//     unbind = Super+q
//
// Key names are resolved through xkbcommon, so they are layout-correct.
// River matches bindings against the *active* layout; no manual QWERTZ /
// AZERTY remapping is needed (the old layoutMapKeysym() was wrong).

const std = @import("std");
const wayland = @import("wayland");
const xkb = @import("xkbcommon");
const river = wayland.client.river;

pub const Modifiers = river.SeatV1.Modifiers;

pub const Bind = struct {
    mods: Modifiers,
    keysym: u32,
    /// Raw command text, e.g. "focus_left" or "workspace 2". Parsed by
    /// action.parse() so config.zig stays independent of action.zig.
    command: []const u8,
};

pub const CenterMode = enum {
    /// Scroll the minimum amount that brings the focused column into view.
    on_overflow,
    /// Always keep the focused column centred.
    always,
    /// Never scroll on focus change.
    never,
};

pub const NewWindowMode = enum {
    /// Open new windows in a fresh column right of the focused one.
    new_column,
    /// Stack new windows into the focused column.
    stack,
};

/// Hard upper bound; Output holds workspaces in a fixed array.
pub const max_workspaces = 16;

pub const Config = struct {
    arena: std.heap.ArenaAllocator,
    config_file: []const u8 = "(built-in defaults)",

    // ---- layout ---------------------------------------------------------
    gap: i32 = 8,
    outer_gap: i32 = 8,
    default_column_width: f64 = 0.5,
    width_presets: []const f64 = &.{ 1.0 / 3.0, 0.5, 2.0 / 3.0, 1.0 },
    width_step: f64 = 0.1,
    min_window_size: i32 = 120,
    center_focused_column: CenterMode = .on_overflow,
    new_window: NewWindowMode = .new_column,

    // ---- look -----------------------------------------------------------
    border_width: i32 = 2,
    border_focused: u32 = 0xd8a657,
    border_unfocused: u32 = 0x3c3836,
    border_floating: u32 = 0x7daea3,

    // ---- workspaces -----------------------------------------------------
    workspace_count: u32 = 4,

    // ---- floating / mouse -----------------------------------------------
    /// Pixels a tiled window must be dragged before it detaches into the
    /// floating layer. Prevents an accidental click-drag from wrecking
    /// the layout.
    drag_threshold: i32 = 24,
    /// Size of a fresh floating window as a fraction of the output.
    floating_size: f64 = 0.6,
    focus_follows_mouse: bool = false,
    /// Modifier for mouse move/resize (Mod+LMB / Mod+RMB).
    mouse_mod: Modifiers = .{ .mod4 = true },

    // ---- programs -------------------------------------------------------
    terminal: []const []const u8 = &.{"alacritty"},
    launcher: []const []const u8 = &.{"fuzzel"},
    browser: []const []const u8 = &.{"firefox"},

    // ---- key bindings ---------------------------------------------------
    binds: []const Bind = &.{},

    // ---- WindowMaker compatibility --------------------------------------
    /// Also read Window Maker's own files (~/GNUstep/Defaults/WMRootMenu,
    /// WMWindowAttributes, ...). Files in ~/.config/wmaker-wl always win.
    enable_wmaker_compat: bool = true,

    // ---- session ----------------------------------------------------------
    /// Run the autostart script once when the session comes up, exactly
    /// like Window Maker: ~/.config/wmaker-wl/autostart, falling back to
    /// ~/GNUstep/Library/WindowMaker/autostart when enable_wmaker_compat
    /// allows it. Neither needs to exist; a missing script is a no-op.
    enable_autostart: bool = true,

    pub fn deinit(cfg: *Config) void {
        cfg.arena.deinit();
    }
};

const default_config_text = @embedFile("share/default_config.conf");

/// Load configuration. Only fails on out-of-memory: a broken or missing
/// user file falls back to the built-in defaults (with warnings), so the
/// session always starts.
pub fn load(io: std.Io, gpa: std.mem.Allocator) !Config {
    var cfg: Config = .{ .arena = .init(gpa) };
    errdefer cfg.deinit();
    const a = cfg.arena.allocator();

    var binds: std.ArrayList(Bind) = .empty;
    try parse(a, default_config_text, &cfg, &binds, "<built-in>");

    if (try userConfigPath(a)) |path| {
        if (std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, path, a, .limited(1 << 20))) |text| {
            cfg.config_file = path;
            try parse(a, text, &cfg, &binds, path);
        } else |err| {
            std.log.info("no user config at {s} ({t}); using defaults", .{ path, err });
        }
    }

    cfg.binds = try binds.toOwnedSlice(a);
    return cfg;
}

fn userConfigPath(a: std.mem.Allocator) !?[]const u8 {
    if (std.c.getenv("XDG_CONFIG_HOME")) |x| {
        const dir = std.mem.span(x);
        if (dir.len > 0) return try std.fmt.allocPrint(a, "{s}/wmaker-wl/config.conf", .{dir});
    }
    if (std.c.getenv("HOME")) |h| {
        return try std.fmt.allocPrint(a, "{s}/.config/wmaker-wl/config.conf", .{std.mem.span(h)});
    }
    return null;
}

// ----------------------------------------------------------------------------
// Parsing
// ----------------------------------------------------------------------------

fn parse(
    a: std.mem.Allocator,
    text: []const u8,
    cfg: *Config,
    binds: *std.ArrayList(Bind),
    origin: []const u8,
) !void {
    var line_no: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        line_no += 1;
        const line = stripComment(raw);
        if (line.len == 0) continue;

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse {
            std.log.warn("{s}:{d}: expected `key = value`", .{ origin, line_no });
            continue;
        };
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t\"");

        applyOption(a, cfg, binds, key, value) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.UnknownKey => std.log.warn("{s}:{d}: unknown option `{s}`", .{ origin, line_no, key }),
            error.Invalid => std.log.warn("{s}:{d}: bad value for `{s}`: {s}", .{ origin, line_no, key, value }),
        };
    }
}

/// Remove a trailing comment.
///
/// A `#` starts a comment when it is at the start of the line or follows
/// whitespace, EXCEPT when it introduces a colour: `#` followed by exactly
/// six hex digits and then whitespace/end (`border_focused = #d8a657`).
fn stripComment(raw: []const u8) []const u8 {
    var end = raw.len;
    for (raw, 0..) |c, i| {
        if (c != '#') continue;
        if (!(i == 0 or raw[i - 1] == ' ' or raw[i - 1] == '\t')) continue;
        if (isColour(raw[i..])) continue;
        end = i;
        break;
    }
    return std.mem.trim(u8, raw[0..end], " \t\r");
}

/// "#d8a657" (optionally followed by whitespace and more text).
fn isColour(s: []const u8) bool {
    if (s.len < 7 or s[0] != '#') return false;
    for (s[1..7]) |ch| if (!std.ascii.isHex(ch)) return false;
    return s.len == 7 or s[7] == ' ' or s[7] == '\t' or s[7] == '\r';
}

const ParseError = error{ Invalid, UnknownKey, OutOfMemory };

fn applyOption(
    a: std.mem.Allocator,
    cfg: *Config,
    binds: *std.ArrayList(Bind),
    key: []const u8,
    value: []const u8,
) ParseError!void {
    const eql = std.mem.eql;

    // Options of the previous config format. Renamed ones keep working;
    // dropped ones are explained once instead of failing as "unknown".
    inline for (.{
        .{ "default_column_width_fraction", "default_column_width" },
        .{ "min_column_width", "min_window_size" },
    }) |alias| {
        if (eql(u8, key, alias[0])) return applyOption(a, cfg, binds, alias[1], value);
    }
    inline for (.{
        .{ "keyboard_layout", "keys follow the active layout automatically" },
        .{ "enable_mouse_support", "mouse bindings are always on; change `mouse_mod`" },
        .{ "mouse_sensitivity", "pointer speed is a river/libinput setting" },
        .{ "enable_floating_windows", "floating is always available (Super+t)" },
    }) |old| {
        if (eql(u8, key, old[0])) {
            std.log.info("config: `{s}` is obsolete and ignored ({s})", .{ old[0], old[1] });
            return;
        }
    }

    if (eql(u8, key, "bind")) return addBind(a, binds, value);
    if (eql(u8, key, "unbind")) return removeBind(binds, value);

    inline for (.{ "gap", "outer_gap", "border_width", "min_window_size", "drag_threshold" }) |name| {
        if (eql(u8, key, name)) {
            const v = std.fmt.parseInt(i32, value, 10) catch return error.Invalid;
            if (v < 0) return error.Invalid;
            @field(cfg, name) = v;
            return;
        }
    }

    inline for (.{ "default_column_width", "width_step", "floating_size" }) |name| {
        if (eql(u8, key, name)) {
            const v = std.fmt.parseFloat(f64, value) catch return error.Invalid;
            if (!(v > 0 and v <= 1)) return error.Invalid;
            @field(cfg, name) = v;
            return;
        }
    }

    inline for (.{ "border_focused", "border_unfocused", "border_floating" }) |name| {
        if (eql(u8, key, name)) {
            var v = std.mem.trimStart(u8, value, "#");
            if (std.mem.startsWith(u8, v, "0x")) v = v[2..];
            @field(cfg, name) = std.fmt.parseInt(u32, v, 16) catch return error.Invalid;
            return;
        }
    }

    if (eql(u8, key, "workspace_count")) {
        const v = std.fmt.parseInt(u32, value, 10) catch return error.Invalid;
        if (v < 1 or v > max_workspaces) return error.Invalid;
        cfg.workspace_count = v;
    } else if (eql(u8, key, "width_presets")) {
        var list: std.ArrayList(f64) = .empty;
        var it = std.mem.tokenizeAny(u8, value, ", \t");
        while (it.next()) |tok| {
            const f = std.fmt.parseFloat(f64, tok) catch return error.Invalid;
            if (!(f > 0 and f <= 1)) return error.Invalid;
            try list.append(a, f);
        }
        if (list.items.len == 0) return error.Invalid;
        cfg.width_presets = try list.toOwnedSlice(a);
    } else if (eql(u8, key, "center_focused_column")) {
        cfg.center_focused_column = std.meta.stringToEnum(CenterMode, value) orelse return error.Invalid;
    } else if (eql(u8, key, "new_window")) {
        cfg.new_window = std.meta.stringToEnum(NewWindowMode, value) orelse return error.Invalid;
    } else if (eql(u8, key, "focus_follows_mouse")) {
        cfg.focus_follows_mouse = try parseBool(value);
    } else if (eql(u8, key, "enable_wmaker_compat")) {
        cfg.enable_wmaker_compat = try parseBool(value);
    } else if (eql(u8, key, "enable_autostart")) {
        cfg.enable_autostart = try parseBool(value);
    } else if (eql(u8, key, "mouse_mod")) {
        cfg.mouse_mod = parseMods(value) orelse return error.Invalid;
    } else if (eql(u8, key, "terminal")) {
        cfg.terminal = parseCommand(a, value) catch |e| return mapCmdErr(e);
    } else if (eql(u8, key, "launcher")) {
        cfg.launcher = parseCommand(a, value) catch |e| return mapCmdErr(e);
    } else if (eql(u8, key, "browser")) {
        cfg.browser = parseCommand(a, value) catch |e| return mapCmdErr(e);
    } else {
        return error.UnknownKey;
    }
}

fn mapCmdErr(e: anyerror) ParseError {
    return if (e == error.OutOfMemory) error.OutOfMemory else error.Invalid;
}

pub fn parseBool(s: []const u8) error{Invalid}!bool {
    inline for (.{ "true", "yes", "on", "1" }) |t| if (std.mem.eql(u8, s, t)) return true;
    inline for (.{ "false", "no", "off", "0" }) |t| if (std.mem.eql(u8, s, t)) return false;
    return error.Invalid;
}

/// Split a command line into argv. Supports "double quoted" arguments.
/// The returned slice and its strings live in `a`.
pub fn parseCommand(a: std.mem.Allocator, s: []const u8) ![]const []const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        while (i < s.len and (s[i] == ' ' or s[i] == '\t')) i += 1;
        if (i >= s.len) break;

        if (s[i] == '"') {
            i += 1;
            const start = i;
            while (i < s.len and s[i] != '"') i += 1;
            try args.append(a, try a.dupe(u8, s[start..i]));
            if (i < s.len) i += 1;
        } else {
            const start = i;
            while (i < s.len and s[i] != ' ' and s[i] != '\t') i += 1;
            try args.append(a, try a.dupe(u8, s[start..i]));
        }
    }
    if (args.items.len == 0) return error.Invalid;
    return args.toOwnedSlice(a);
}

// ----------------------------------------------------------------------------
// Key bindings
// ----------------------------------------------------------------------------

pub fn parseMods(s: []const u8) ?Modifiers {
    var mods: Modifiers = .{};
    var it = std.mem.tokenizeScalar(u8, s, '+');
    var any = false;
    while (it.next()) |tok| {
        const t = std.mem.trim(u8, tok, " \t");
        if (t.len == 0) continue;
        any = true;
        if (eqlNoCase(t, "super") or eqlNoCase(t, "mod4") or eqlNoCase(t, "logo")) {
            mods.mod4 = true;
        } else if (eqlNoCase(t, "shift")) {
            mods.shift = true;
        } else if (eqlNoCase(t, "ctrl") or eqlNoCase(t, "control")) {
            mods.ctrl = true;
        } else if (eqlNoCase(t, "alt") or eqlNoCase(t, "mod1")) {
            mods.mod1 = true;
        } else if (eqlNoCase(t, "mod3")) {
            mods.mod3 = true;
        } else if (eqlNoCase(t, "mod5") or eqlNoCase(t, "altgr")) {
            mods.mod5 = true;
        } else return null;
    }
    return if (any) mods else null;
}

fn eqlNoCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

pub fn modsBits(m: Modifiers) u32 {
    return @intCast(@as(std.meta.Int(.unsigned, @bitSizeOf(Modifiers)), @bitCast(m)));
}

/// "Super+Shift+h, close"  ->  Bind
fn addBind(a: std.mem.Allocator, binds: *std.ArrayList(Bind), value: []const u8) ParseError!void {
    const comma = std.mem.indexOfScalar(u8, value, ',') orelse return error.Invalid;
    const combo = std.mem.trim(u8, value[0..comma], " \t");
    const command = std.mem.trim(u8, value[comma + 1 ..], " \t");
    if (command.len == 0) return error.Invalid;

    const parsed = parseCombo(a, combo) orelse return error.Invalid;

    // A later bind for the same combo replaces the earlier one.
    removeBindExact(binds, parsed.mods, parsed.keysym);
    try binds.append(a, .{
        .mods = parsed.mods,
        .keysym = parsed.keysym,
        .command = try a.dupe(u8, command),
    });
}

fn removeBind(binds: *std.ArrayList(Bind), combo_text: []const u8) ParseError!void {
    var buf: [256]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const parsed = parseCombo(fba.allocator(), combo_text) orelse return error.Invalid;
    removeBindExact(binds, parsed.mods, parsed.keysym);
}

fn removeBindExact(binds: *std.ArrayList(Bind), mods: Modifiers, keysym: u32) void {
    var i: usize = 0;
    while (i < binds.items.len) {
        const b = binds.items[i];
        if (b.keysym == keysym and modsBits(b.mods) == modsBits(mods)) {
            _ = binds.orderedRemove(i);
        } else i += 1;
    }
}

const Combo = struct { mods: Modifiers, keysym: u32 };

/// "Super+Shift+Return" -> modifiers + keysym. The last `+`-separated
/// token is the key; everything before it is a modifier.
fn parseCombo(a: std.mem.Allocator, s: []const u8) ?Combo {
    var mods: Modifiers = .{};
    var key_name: []const u8 = std.mem.trim(u8, s, " \t");

    if (std.mem.lastIndexOfScalar(u8, key_name, '+')) |i| {
        if (i == key_name.len - 1 and i > 0 and key_name[i - 1] == '+') {
            // "Super++": the key is a literal plus sign.
            mods = parseMods(key_name[0 .. i - 1]) orelse return null;
            key_name = "plus";
        } else {
            mods = parseMods(key_name[0..i]) orelse return null;
            key_name = std.mem.trim(u8, key_name[i + 1 ..], " \t");
        }
    }
    if (key_name.len == 0) return null;

    const z = a.dupeZ(u8, key_name) catch return null;
    var sym = xkb.Keysym.fromName(z, .no_flags);
    if (sym == .NoSymbol) sym = xkb.Keysym.fromName(z, .case_insensitive);
    if (sym == .NoSymbol) return null;
    return .{ .mods = mods, .keysym = @intFromEnum(sym) };
}

test "colour detection" {
    try std.testing.expect(isColour("#d8a657"));
    try std.testing.expect(isColour("#d8a657 # gold"));
    try std.testing.expect(!isColour("#d8a65")); // too short
    try std.testing.expect(!isColour("#d8a6577")); // too long
    try std.testing.expect(!isColour("# comment"));
}

test "comment stripping keeps colours" {
    try std.testing.expectEqualStrings("border_focused = #d8a657", stripComment("border_focused = #d8a657  # gold"));
    try std.testing.expectEqualStrings("", stripComment("# whole line"));
    try std.testing.expectEqualStrings("gap = 8", stripComment("gap = 8   # between windows"));
    // A comment that merely starts with something hex-like is still a comment.
    try std.testing.expectEqualStrings("gap = 8", stripComment("gap = 8 # add bad"));
}

test "enable_autostart parses and defaults on" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var cfg: Config = .{ .arena = .init(std.testing.allocator) };
    defer cfg.deinit();
    try std.testing.expect(cfg.enable_autostart);

    var binds: std.ArrayList(Bind) = .empty;
    try parse(arena.allocator(), "enable_autostart = no\n", &cfg, &binds, "<test>");
    try std.testing.expect(!cfg.enable_autostart);
}

test "command splitting" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const argv = try parseCommand(arena.allocator(), "foot -e \"htop -d 5\"");
    try std.testing.expectEqual(@as(usize, 3), argv.len);
    try std.testing.expectEqualStrings("htop -d 5", argv[2]);
}
