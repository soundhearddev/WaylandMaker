// SPDX-License-Identifier: 0BSD
//
// WindowMaker Compatibility Layer
// Provides FFI bindings and abstraction for WindowMaker C code.
// Bridges Wayland/River world with classic WindowMaker functionality:
// - Docks (AppIcon/Clip)
// - Configuration/Preferences
// - Theme support
// - Window decoration hooks
// - Per-application window attribute rules (this file's `AttributeRule`),
//   reimplementing the *philosophy* of WindowMaker's WMWindowAttributes /
//   WMState files (GNUstep property lists keyed by WM_CLASS, e.g.
//   `{ Titlebar = NO; Sticky = YES; }`) in plain Zig, using this project's
//   own simple `key = value` config syntax rather than a full GNUstep
//   plist parser.
//
// Classic WindowMaker has no tiling at all -- every window free-floats,
// placed by the user or by a placement policy. That's the one piece of
// "philosophy" wired all the way through right now: when
// `enable_wmaker_compat` is on, a matching attribute rule can make a
// window start in the floating layer (see window.zig's `manage()`) and/or
// mark it "sticky" (WindowMaker's Omnipresent windows -- visible on every
// workspace, see main.zig's render loop), instead of joining the
// scrollable-tiling strip.

const std = @import("std");
const config = @import("config.zig");

pub const WMakerContext = struct {
    allocator: std.mem.Allocator,
    enabled: bool = false,
    docksapp_dir: ?[]const u8 = null,

    // Per-application attribute rules, parsed from the WMaker attributes
    // file (see loadAttributes below). Owns its own `app_id`/`attrs`
    // storage independently of `config.Config`.
    rules: []AttributeRule = &.{},

    // C FFI handles (optional)
    wmaker_handle: ?*anyopaque = null,
    theme_handle: ?*anyopaque = null,
    prefs_handle: ?*anyopaque = null,

    pub fn deinit(self: *WMakerContext, allocator: std.mem.Allocator) void {
        if (self.docksapp_dir) |path| {
            allocator.free(path);
        }
        for (self.rules) |rule| allocator.free(rule.app_id);
        allocator.free(self.rules);
        // Call C cleanup if loaded
        if (self.wmaker_handle) |_| {
            // wmakerCleanup();
        }
    }
};

pub fn init(io: std.Io, allocator: std.mem.Allocator, cfg: *const config.Config) !WMakerContext {
    var ctx = WMakerContext{
        .allocator = allocator,
        .enabled = cfg.enable_wmaker_compat,
    };

    if (!cfg.enable_wmaker_compat) {
        std.log.info("WindowMaker compatibility disabled", .{});
        return ctx;
    }

    std.log.info("Initializing WindowMaker compatibility layer", .{});

    if (cfg.wmaker_docksapp_dir) |dir| {
        ctx.docksapp_dir = try allocator.dupe(u8, dir);
    }

    ctx.rules = loadAttributes(io, allocator) catch |err| blk: {
        std.log.info("no WMaker attributes file loaded ({}), using defaults", .{err});
        break :blk &.{};
    };

    // Load WMaker library (if available)
    // This is where real C integration happens
    try loadWMakerLibrary(allocator, &ctx);

    return ctx;
}

pub fn loadWMakerLibrary(allocator: std.mem.Allocator, ctx: *WMakerContext) !void {
    _ = allocator;
    _ = ctx;

    // TODO: dlopen("libwmaker.so") or similar
    // For now, just scaffold the function
    std.log.debug("WMaker library loading: placeholder", .{});

    // If available, initialize:
    // - Dock/Clip support
    // - Configuration parser
    // - Theme system
    // - Window hints/attributes mapping
}

pub fn loadTheme(ctx: *WMakerContext, theme_path: []const u8) !void {
    if (!ctx.enabled) return;

    std.log.info("Loading WMaker theme: {s}", .{theme_path});

    // TODO: Call WMaker C API to load theme
    // Maps WMaker themes to Wayland surface attributes

}

pub fn loadConfiguration(ctx: *WMakerContext, config_path: []const u8) !void {
    if (!ctx.enabled) return;

    std.log.info("Loading WMaker configuration: {s}", .{config_path});

    // TODO: Parse WMakerrc or WindowMaker config format
    // Integrate settings with our config system

}

pub const DockAppInfo = struct {
    name: []const u8,
    icon_path: []const u8,
    x: i32,
    y: i32,
    width: i32 = 64,
    height: i32 = 64,
    running: bool = false,
};

pub fn createDockApp(ctx: *WMakerContext, app_info: DockAppInfo) !void {
    if (!ctx.enabled) return;

    std.log.info("Creating DockApp: {s} at ({}, {})", .{ app_info.name, app_info.x, app_info.y });

    // TODO: Create an unmanaged layer-shell surface for the dock app.
    // `main.zig` already binds river_layer_shell_v1 (wm.layer_shell) for
    // exactly this, it just isn't used yet -- the actual surface/request
    // shapes for river_layer_shell_v1 aren't in scope of the files
    // reviewed for this change, so wiring this up safely needs that
    // protocol definition (protocol/river-layer-shell-*.xml) at hand.
}

// ----------------------------------------------------------------------------
// Per-application window attributes
// ----------------------------------------------------------------------------
//
// WindowMaker keys its window attributes by WM_CLASS (X11) / app-id
// (Wayland). This WM doesn't parse app-id yet (see TODO.md: "Integrate
// window titles" is still open), so `attributesFor` accepts an optional
// app_id and always falls through to the wildcard "*" rule when it's
// null or unmatched -- the lookup and merge logic is real and ready, only
// the app-id itself is missing for now.

pub const WindowAttributes = struct {
    skip_taskbar: bool = false,
    skip_window_list: bool = false,
    skip_switcher: bool = false,
    keep_on_top: bool = false,
    keep_below: bool = false,
    /// WindowMaker's "Omnipresent": visible on every workspace.
    sticky: bool = false,
    /// Classic WindowMaker has no tiling -- place the window in the
    /// floating layer instead of the scrollable-tiling strip.
    floating: bool = false,
};

pub const AttributeRule = struct {
    /// App-id this rule matches, or "*" for the fallback rule applied to
    /// every window that has no more specific match.
    app_id: []const u8,
    attrs: WindowAttributes,
};

/// Look up the attribute rule for `app_id` (an exact match, falling back
/// to the wildcard "*" rule), merged over WindowAttributes{} defaults.
/// Returns the all-defaults struct if wmaker compat is disabled, nothing
/// matched, or no attributes file was loaded.
pub fn attributesFor(ctx: *const WMakerContext, app_id: ?[]const u8) WindowAttributes {
    if (!ctx.enabled) return .{};

    if (app_id) |id| {
        for (ctx.rules) |rule| {
            if (std.mem.eql(u8, rule.app_id, id)) return rule.attrs;
        }
    }
    for (ctx.rules) |rule| {
        if (std.mem.eql(u8, rule.app_id, "*")) return rule.attrs;
    }
    return .{};
}

/// Parse `~/.config/wmaker-wl/attributes.conf`, a WindowMaker-attributes
/// file reimagined in this project's plain `key = value` style instead of
/// GNUstep property-list syntax:
///
///   # applies to every window with no more specific section
///   [*]
///   sticky = no
///
///   [firefox]
///   sticky = yes
///   floating = no
///
/// Section headers select the app-id (or "*"); unknown keys are ignored
/// so the format can grow without breaking older config files.
fn loadAttributes(io: std.Io, allocator: std.mem.Allocator) ![]AttributeRule {
    const home_ptr = std.c.getenv("HOME");
    const home: []const u8 = if (home_ptr) |ptr| std.mem.span(ptr) else "/root";

    const path = try std.fmt.allocPrint(allocator, "{s}/.config/wmaker-wl/attributes.conf", .{home});
    defer allocator.free(path);

    const content = try std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, path, allocator, .unlimited);
    defer allocator.free(content);

    var rules = std.ArrayList(AttributeRule).empty;
    errdefer {
        for (rules.items) |rule| allocator.free(rule.app_id);
        rules.deinit(allocator);
    }

    var current_id: ?[]const u8 = null;
    var current_attrs: WindowAttributes = .{};

    var lines = std.mem.splitSequence(u8, content, "\n");
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        if (trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') {
            if (current_id) |id| {
                try rules.append(allocator, .{ .app_id = id, .attrs = current_attrs });
            }
            current_id = try allocator.dupe(u8, trimmed[1 .. trimmed.len - 1]);
            current_attrs = .{};
            continue;
        }

        const eq_idx = std.mem.indexOf(u8, trimmed, "=") orelse continue;
        const key = std.mem.trim(u8, trimmed[0..eq_idx], " \t");
        const value = std.mem.trim(u8, trimmed[eq_idx + 1 ..], " \t\"");
        const on = std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "yes") or std.mem.eql(u8, value, "1");

        if (std.mem.eql(u8, key, "sticky")) {
            current_attrs.sticky = on;
        } else if (std.mem.eql(u8, key, "floating")) {
            current_attrs.floating = on;
        } else if (std.mem.eql(u8, key, "keep_on_top")) {
            current_attrs.keep_on_top = on;
        } else if (std.mem.eql(u8, key, "keep_below")) {
            current_attrs.keep_below = on;
        } else if (std.mem.eql(u8, key, "skip_taskbar")) {
            current_attrs.skip_taskbar = on;
        } else if (std.mem.eql(u8, key, "skip_window_list")) {
            current_attrs.skip_window_list = on;
        } else if (std.mem.eql(u8, key, "skip_switcher")) {
            current_attrs.skip_switcher = on;
        }
    }

    if (current_id) |id| {
        try rules.append(allocator, .{ .app_id = id, .attrs = current_attrs });
    }

    std.log.info("loaded {d} WMaker attribute rule(s) from: {s}", .{ rules.items.len, path });
    return try rules.toOwnedSlice(allocator);
}

pub const ClipboardData = struct {
    data: []const u8,
    mime_type: []const u8,
};

pub fn copyToClipboard(ctx: *WMakerContext, data: ClipboardData) !void {
    if (!ctx.enabled) return;

    std.log.debug("WMaker clipboard operation", .{});

    // TODO: Integrate with Wayland clipboard/primary selection
    _ = data;
}

// Hook points for WindowMaker feature integration

pub const Hooks = struct {
    // Called when a window is mapped (allow WMaker to set attributes)
    onWindowMapped: ?*const fn (*anyopaque, u32) void = null,

    // Called on window close
    onWindowUnmapped: ?*const fn (*anyopaque, u32) void = null,

    // Called for theme changes
    onThemeChanged: ?*const fn (*anyopaque, []const u8) void = null,

    // Called for configuration reload
    onConfigReloaded: ?*const fn (*anyopaque) void = null,
};

pub var hooks: Hooks = .{};

pub fn registerHook(hook_fn: anytype, comptime hook_field: []const u8) !void {
    // TODO: Register C function as hook
    std.log.debug("Registering hook: {s}", .{hook_field});
    _ = hook_fn;
}
