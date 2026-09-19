// SPDX-License-Identifier: 0BSD
//
// Configuration system for wmaker-wl.
// Loads from ~/.config/wmaker-wl/config.conf (simple key=value format).
// Supports keyboard layouts (QWERTY, QWERTZ, AZERTY).

const std = @import("std");
const wayland = @import("wayland");
const river = wayland.client.river;

pub const KeyboardLayout = enum {
    qwerty,
    qwertz,
    azerty,
};

pub const Keybind = struct {
    modifiers: river.SeatV1.Modifiers,
    keysym: u32,
    action: []const u8,
};

pub const Config = struct {
    allocator: std.mem.Allocator,
    config_file: []const u8,

    // Display & Layout
    default_column_width_fraction: f64 = 0.5,
    width_presets: []const f64,
    width_step: f64 = 0.1,
    min_column_width: i32 = 200,
    gap: i32 = 8,

    // Window styling
    border_width: i32 = 2,
    border_focused: u32 = 0xd8a657,
    border_unfocused: u32 = 0x3c3836,

    // Keyboard
    keyboard_layout: KeyboardLayout = .qwerty,
    keybinds: []Keybind,

    // Workspace
    workspace_count: u32 = 4,

    // Programs
    terminal_cmd: [][]const u8,
    launcher_cmd: [][]const u8,
    browser_cmd: [][]const u8,

    // Mouse
    enable_mouse_support: bool = true,
    mouse_sensitivity: f32 = 1.0,
    enable_floating_windows: bool = false,

    // WMaker compatibility
    enable_wmaker_compat: bool = false,
    wmaker_docksapp_dir: ?[]const u8 = null,

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        allocator.free(self.config_file);
        allocator.free(self.width_presets);
        allocator.free(self.keybinds);
        for (self.terminal_cmd) |arg| allocator.free(arg);
        allocator.free(self.terminal_cmd);
        for (self.launcher_cmd) |arg| allocator.free(arg);
        allocator.free(self.launcher_cmd);
        for (self.browser_cmd) |arg| allocator.free(arg);
        allocator.free(self.browser_cmd);
        if (self.wmaker_docksapp_dir) |dir| allocator.free(dir);
    }
};

pub fn load(io: std.Io, allocator: std.mem.Allocator) !Config {
    var cfg = Config{
        .allocator = allocator,
        .config_file = try allocator.dupe(u8, "(built-in defaults)"),
        .width_presets = try allocator.dupe(f64, &[_]f64{ 1.0 / 3.0, 0.5, 2.0 / 3.0, 1.0 }),
        .keybinds = try defaultKeybinds(allocator, .qwerty),
        .terminal_cmd = try allocator.dupe([]const u8, &[_][]const u8{"alacritty"}),
        .launcher_cmd = try allocator.dupe([]const u8, &[_][]const u8{"fuzzel"}),
        .browser_cmd = try allocator.dupe([]const u8, &[_][]const u8{"firefox"}),
    };

    // Try to load from ~/.config/wmaker-wl/config.conf
    const home_ptr = std.c.getenv("HOME");
    const home: []const u8 = if (home_ptr) |ptr| std.mem.span(ptr) else "/root";

    const config_path = try std.fmt.allocPrint(allocator, "{s}/.config/wmaker-wl/config.conf", .{home});
    defer allocator.free(config_path);

    if (loadFromFile(io, allocator, config_path, &cfg)) {
        std.log.info("loaded config from: {s}", .{config_path});
        return cfg;
    } else |_| {
        std.log.info("no config file found ({s}), using defaults", .{config_path});
        return cfg;
    }
}

fn loadFromFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8, cfg: *Config) !void {
    const content = try std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, path, allocator, .unlimited);
    defer allocator.free(content);

    allocator.free(cfg.config_file);
    cfg.config_file = try allocator.dupe(u8, path);

    // Parse key=value format
    var lines = std.mem.splitSequence(u8, content, "\n");
    while (lines.next()) |line| {
        // Skip comments and empty lines
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        // Find '='
        const eq_idx = std.mem.indexOf(u8, trimmed, "=") orelse continue;
        const key = std.mem.trim(u8, trimmed[0..eq_idx], " \t");
        const value = std.mem.trim(u8, trimmed[eq_idx + 1 ..], " \t\"");

        // Parse each setting
        if (std.mem.eql(u8, key, "keyboard_layout")) {
            cfg.keyboard_layout = parseKeyboardLayout(value);
        } else if (std.mem.eql(u8, key, "gap")) {
            cfg.gap = std.fmt.parseInt(i32, value, 10) catch cfg.gap;
        } else if (std.mem.eql(u8, key, "border_width")) {
            cfg.border_width = std.fmt.parseInt(i32, value, 10) catch cfg.border_width;
        } else if (std.mem.eql(u8, key, "border_focused")) {
            cfg.border_focused = std.fmt.parseInt(u32, value, 16) catch cfg.border_focused;
        } else if (std.mem.eql(u8, key, "border_unfocused")) {
            cfg.border_unfocused = std.fmt.parseInt(u32, value, 16) catch cfg.border_unfocused;
        } else if (std.mem.eql(u8, key, "min_column_width")) {
            cfg.min_column_width = std.fmt.parseInt(i32, value, 10) catch cfg.min_column_width;
        } else if (std.mem.eql(u8, key, "default_column_width_fraction")) {
            cfg.default_column_width_fraction = std.fmt.parseFloat(f64, value) catch cfg.default_column_width_fraction;
        } else if (std.mem.eql(u8, key, "width_step")) {
            cfg.width_step = std.fmt.parseFloat(f64, value) catch cfg.width_step;
        } else if (std.mem.eql(u8, key, "workspace_count")) {
            cfg.workspace_count = std.fmt.parseInt(u32, value, 10) catch cfg.workspace_count;
        } else if (std.mem.eql(u8, key, "enable_mouse_support")) {
            cfg.enable_mouse_support = parseBool(value);
        } else if (std.mem.eql(u8, key, "mouse_sensitivity")) {
            // On a bad value, keep the existing sensitivity untouched
            // (the previous fallback round-tripped it through an i32 and
            // silently truncated e.g. 1.5 down to 1.0).
            cfg.mouse_sensitivity = std.fmt.parseFloat(f32, value) catch cfg.mouse_sensitivity;
        } else if (std.mem.eql(u8, key, "enable_floating_windows")) {
            cfg.enable_floating_windows = parseBool(value);
        } else if (std.mem.eql(u8, key, "enable_wmaker_compat")) {
            cfg.enable_wmaker_compat = parseBool(value);
        } else if (std.mem.eql(u8, key, "terminal")) {
            allocator.free(cfg.terminal_cmd);
            cfg.terminal_cmd = try parseCommand(allocator, value);
        } else if (std.mem.eql(u8, key, "launcher")) {
            allocator.free(cfg.launcher_cmd);
            cfg.launcher_cmd = try parseCommand(allocator, value);
        } else if (std.mem.eql(u8, key, "browser")) {
            allocator.free(cfg.browser_cmd);
            cfg.browser_cmd = try parseCommand(allocator, value);
        } else if (std.mem.eql(u8, key, "wmaker_docksapp_dir")) {
            if (cfg.wmaker_docksapp_dir) |dir| allocator.free(dir);
            cfg.wmaker_docksapp_dir = try allocator.dupe(u8, value);
        }
    }
}

fn parseKeyboardLayout(s: []const u8) KeyboardLayout {
    if (std.mem.eql(u8, s, "qwertz")) return .qwertz;
    if (std.mem.eql(u8, s, "azerty")) return .azerty;
    return .qwerty;
}

fn parseBool(s: []const u8) bool {
    return std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "yes") or std.mem.eql(u8, s, "1");
}

fn parseCommand(allocator: std.mem.Allocator, cmd_str: []const u8) ![][]const u8 {
    var args = std.ArrayList([]const u8).empty;
    defer args.deinit(allocator);

    var iter = std.mem.splitSequence(u8, cmd_str, " ");
    while (iter.next()) |arg| {
        const trimmed = std.mem.trim(u8, arg, " \t");
        if (trimmed.len > 0) {
            try args.append(allocator, try allocator.dupe(u8, trimmed));
        }
    }

    if (args.items.len == 0) {
        try args.append(allocator, try allocator.dupe(u8, "echo"));
    }

    return try args.toOwnedSlice(allocator);
}

fn defaultKeybinds(allocator: std.mem.Allocator, layout: KeyboardLayout) ![]Keybind {
    var binds = std.ArrayList(Keybind).empty;
    defer binds.deinit(allocator);

    // Allocator wird nun direkt an append/toOwnedSlice übergeben:
    try binds.append(allocator, .{
        .modifiers = .{ .mod4 = true },
        .keysym = 0xff0d,
        .action = "spawn_terminal",
    });

    try binds.append(allocator, .{
        .modifiers = .{ .mod4 = true },
        .keysym = layoutMapKeysym(layout, 'd'),
        .action = "spawn_launcher",
    });

    try binds.append(allocator, .{
        .modifiers = .{ .mod4 = true },
        .keysym = layoutMapKeysym(layout, 'h'),
        .action = "focus_left",
    });
    try binds.append(allocator, .{
        .modifiers = .{ .mod4 = true },
        .keysym = layoutMapKeysym(layout, 'j'),
        .action = "focus_down",
    });
    try binds.append(allocator, .{
        .modifiers = .{ .mod4 = true },
        .keysym = layoutMapKeysym(layout, 'k'),
        .action = "focus_up",
    });
    try binds.append(allocator, .{
        .modifiers = .{ .mod4 = true },
        .keysym = layoutMapKeysym(layout, 'l'),
        .action = "focus_right",
    });

    return try binds.toOwnedSlice(allocator);
}

pub fn layoutMapKeysym(layout: KeyboardLayout, qwerty_key: u8) u32 {
    return switch (layout) {
        .qwerty => qwerty_key,
        .qwertz => mapQwertzKey(qwerty_key),
        .azerty => mapAzertyKey(qwerty_key),
    };
}

fn mapQwertzKey(qwerty_key: u8) u32 {
    return switch (qwerty_key) {
        'y' => 'z',
        'z' => 'y',
        else => qwerty_key,
    };
}

fn mapAzertyKey(qwerty_key: u8) u32 {
    return switch (qwerty_key) {
        'a' => 'q',
        'q' => 'a',
        'z' => 'w',
        'w' => 'z',
        else => qwerty_key,
    };
}
