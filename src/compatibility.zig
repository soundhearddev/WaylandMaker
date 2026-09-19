// SPDX-License-Identifier: 0BSD
//
// WindowMaker Compatibility Layer
// Provides FFI bindings and abstraction for WindowMaker C code.
// Bridges Wayland/River world with classic WindowMaker functionality:
// - Docks (AppIcon/Clip)
// - Configuration/Preferences
// - Theme support
// - Window decoration hooks

const std = @import("std");
const config = @import("config.zig");

pub const WMakerContext = struct {
    allocator: std.mem.Allocator,
    enabled: bool = false,
    docksapp_dir: ?[]const u8 = null,

    // C FFI handles (optional)
    wmaker_handle: ?*anyopaque = null,
    theme_handle: ?*anyopaque = null,
    prefs_handle: ?*anyopaque = null,

    pub fn deinit(self: *WMakerContext, allocator: std.mem.Allocator) void {
        if (self.docksapp_dir) |path| {
            allocator.free(path);
        }
        // Call C cleanup if loaded
        if (self.wmaker_handle) |_| {
            // wmakerCleanup();
        }
    }
};

pub fn init(allocator: std.mem.Allocator, cfg: *const config.Config) !WMakerContext {
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

    // TODO: Create unmanaged surface for dock app
    // Link to WMaker dock/clip functionality
}

pub const WindowAttributes = struct {
    skip_taskbar: bool = false,
    skip_window_list: bool = false,
    skip_switcher: bool = false,
    keep_on_top: bool = false,
    keep_below: bool = false,
    sticky: bool = false,
};

pub fn applyWindowAttributes(ctx: *WMakerContext, window_id: u32, attrs: WindowAttributes) !void {
    if (!ctx.enabled) return;

    std.log.debug("Applying WMaker window attributes to {}", .{window_id});

    // TODO: Map WMaker window hints to Wayland layer-shell / properties

    _ = attrs;
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
