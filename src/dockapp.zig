// SPDX-License-Identifier: 0BSD
//
// DockApps: a standard entry format for "one command, one icon, one dock
// slot" applications, so every future dock (or Clip, or a status area) can
// share a single parser and a single launch path instead of each growing
// its own.
//
// wmaker-wl does not draw a dock yet (see docs/TODO.md, Phase 5). That
// needs a real 64px-tile UI over `wl_shm`/cairo (see gfx.zig, ui.zig) and
// is out of scope here. What this module gives Phase 5 -- and anything
// else that wants a "list of dock apps" in the meantime, such as
// AutoLaunch at session start -- is the data:
//
//   - a DockApp's shape (name, command, icon, position, autolaunch),
//   - two ways to author a list of them, both optional and additive:
//
//       1. Window Maker's own format, read verbatim from
//          ~/GNUstep/Defaults/WMState (a GNUstep property list keyed
//          Dock.Applications / Clip.Applications), so an existing Window
//          Maker dock setup keeps working when enable_wmaker_compat is on.
//          See plist.zig's "window maker dock state" test for the exact
//          shape parsed here.
//
//       2. wmaker-wl's own plain `key = value` block format (matching the
//          style of attributes.conf / config.conf), for people who don't
//          have and don't want a GNUstep directory:
//
//              [xterm]
//              command = xterm -e htop
//              icon = /usr/share/icons/hicolor/48x48/apps/xterm.png
//              position = 0,1
//              autolaunch = yes
//
//          at ~/.config/wmaker-wl/dockapps.conf.
//
// Nothing here draws anything or reserves screen space; `runAutoLaunch`
// just spawns the marked entries once, the same way main.zig runs the
// autostart script.

const std = @import("std");
const plist = @import("plist.zig");
const config = @import("config.zig");
const wm_attr = @import("wm_attr.zig");

// ----------------------------------------------------------------------------
// Self-declaring DockApps: no config file at all
// ----------------------------------------------------------------------------
//
// A DockApp does not have to be listed anywhere. If its own app_id starts
// with one of the prefixes below, wmaker-wl treats it as a DockApp
// automatically -- the same idea as X11 Window Maker recognising a
// DockApp through its WM_CLASS/WM_HINTS, just expressed the Wayland way,
// through app_id. This is the ONLY thing a DockApp author has to do:
//
//   * set the app_id to "dockapp:<name>" or "dockapp-<name>"
//     (e.g. via GTK's Gio.Application id, or Wayland's xdg_toplevel
//     set_app_id request directly), and
//   * ask for a fixed size (equal min/max size hints) -- wmaker-wl already
//     floats any window that does that (see window.zig's wantsFloating),
//     which is exactly the "one fixed-size tile" shape a DockApp needs.
//
// No dockapps.conf, no attributes.conf, nothing to register. A user who
// wants to override the look for one specific DockApp can still add a
// normal attributes.conf rule keyed on its app_id -- explicit file rules
// win over these defaults, see window.zig's app_id handling.
//
// Naming the app_id is the standalone author's job (see
// wmaker-dockapp-clock's README for a worked example); parsing it is
// wmaker-wl's.

const self_declaring_prefixes = [_][]const u8{ "dockapp:", "dockapp-" };

/// True if this app_id follows wmaker-wl's self-declaring DockApp
/// convention (see the section header above). Case-sensitive on purpose:
/// app_ids are conventionally lowercase, and an accidental "DockApp:" from
/// a differently-cased toolkit should not silently match.
pub fn isSelfDeclared(app_id: ?[]const u8) bool {
    const id = app_id orelse return false;
    for (self_declaring_prefixes) |prefix| {
        if (std.mem.startsWith(u8, id, prefix)) return true;
    }
    return false;
}

/// Sensible defaults for a self-declared DockApp: no title bar or border
/// (it's a small tile, not a normal window) and floating (a fixed-size
/// tile should never join the tiling layout). Returned as `Attributes`
/// with everything else left `null`, so `withDefaults` lets an explicit
/// attributes.conf rule for this app_id override any part of this.
pub fn defaultAttrs() wm_attr.Attributes {
    return .{
        .no_titlebar = true,
        .no_border = true,
        .floating = true,
        .skip_window_list = true,
    };
}

/// One dock slot. `x`/`y` are Window Maker's grid coordinates (in tiles,
/// relative to the dock's corner), not pixels -- a future dock UI decides
/// the tile size (Window Maker's own default is 64px).
pub const DockApp = struct {
    /// Display name / Window Maker's "Name" (often "instance.class").
    name: []const u8,
    /// Command line to launch this app, already split into argv.
    command: []const []const u8,
    /// Optional icon path or name; unset means "look it up from the
    /// command/app_id later", exactly like Window Maker falls back to a
    /// generic icon.
    icon: ?[]const u8 = null,
    x: i32 = 0,
    y: i32 = 0,
    /// Start this app once when the session comes up.
    autolaunch: bool = false,
    /// Window Maker's "Lowered": docked below normal windows instead of
    /// on top. Stored for a future dock UI; has no effect yet.
    lowered: bool = false,
};

pub const List = struct {
    apps: []const DockApp = &.{},

    pub fn isEmpty(self: List) bool {
        return self.apps.len == 0;
    }
};

pub const Error = error{ Syntax, OutOfMemory };

// ----------------------------------------------------------------------------
// Window Maker's WMState format: { Dock = { Applications = ( {...}, ... ); }; }
// ----------------------------------------------------------------------------

/// Parse a WMState property list and return its Dock's (or, if there is no
/// Dock, its Clip's) Applications list. Missing sections are not an error:
/// an empty list is returned so a caller can just skip auto-launching.
pub fn parseWMState(arena: std.mem.Allocator, text: []const u8) Error!List {
    return parseWMStateDiag(arena, text, null);
}

pub fn parseWMStateDiag(arena: std.mem.Allocator, text: []const u8, diag: ?*plist.Diag) Error!List {
    const root = try plist.parse(arena, text, diag);

    const section = root.get("Dock") orelse root.get("Clip") orelse return .{};
    const items = section.get("Applications") orelse return .{};
    const entries = items.items() orelse return .{};

    var apps: std.ArrayList(DockApp) = .empty;
    for (entries) |entry| {
        const app = parseWMStateEntry(arena, entry) orelse continue;
        try apps.append(arena, app);
    }
    return .{ .apps = try apps.toOwnedSlice(arena) };
}

fn parseWMStateEntry(arena: std.mem.Allocator, entry: plist.Value) ?DockApp {
    // "Command" is a full shell-ish command line in Window Maker's files
    // (it is handed to /bin/sh there); wmaker-wl's own process.spawn wants
    // argv, so it is split the same way config.zig splits `terminal =` /
    // `launcher =` lines. A quoted command with spaces in a path still
    // needs those quotes; unquoted whitespace just separates arguments,
    // same as the rest of this project's command parsing.
    const command_line = entry.get("Command") orelse return null;
    const command_str = command_line.str() orelse return null;
    const command = config.parseCommand(arena, command_str) catch return null;

    var app: DockApp = .{ .name = command_str, .command = command };
    if (entry.get("Name")) |n| {
        if (n.str()) |s| app.name = s;
    }
    if (entry.get("AutoLaunch")) |v| {
        if (v.boolean()) |b| app.autolaunch = b;
    }
    if (entry.get("Lowered")) |v| {
        if (v.boolean()) |b| app.lowered = b;
    }
    if (entry.get("Position")) |v| {
        if (v.str()) |s| if (parsePosition(s)) |xy| {
            app.x = xy[0];
            app.y = xy[1];
        };
    }
    return app;
}

/// Window Maker writes dock positions as "x,y" (also seen as "x, y"),
/// signed integers.
fn parsePosition(s: []const u8) ?[2]i32 {
    const comma = std.mem.indexOfScalar(u8, s, ',') orelse return null;
    const xs = std.mem.trim(u8, s[0..comma], " \t");
    const ys = std.mem.trim(u8, s[comma + 1 ..], " \t");
    const x = std.fmt.parseInt(i32, xs, 10) catch return null;
    const y = std.fmt.parseInt(i32, ys, 10) catch return null;
    return .{ x, y };
}

// ----------------------------------------------------------------------------
// wmaker-wl's own format: [name] blocks, key = value, like attributes.conf
// ----------------------------------------------------------------------------

/// Parse `~/.config/wmaker-wl/dockapps.conf`-style text (see the module
/// doc comment for the format). Unknown keys are ignored, same policy as
/// the rest of wmaker-wl's own config formats, so the file can grow
/// without breaking older versions.
pub fn parseOwn(arena: std.mem.Allocator, text: []const u8) Error!List {
    var apps: std.ArrayList(DockApp) = .empty;

    // Accumulates one [name] block until the next header (or EOF) closes
    // it; `name == null` before the first header means "nothing to flush
    // yet", matching wm_attr.zig / compatibility.zig's own attribute-file
    // parsers.
    var name: ?[]const u8 = null;
    var command: []const u8 = "";
    var icon: ?[]const u8 = null;
    var x: i32 = 0;
    var y: i32 = 0;
    var autolaunch: bool = false;
    var lowered: bool = false;

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, stripComment(raw), " \t\r");
        if (line.len == 0) continue;

        if (line[0] == '[' and line[line.len - 1] == ']') {
            try flushDockApp(arena, &apps, name, command, icon, x, y, autolaunch, lowered);
            name = try arena.dupe(u8, line[1 .. line.len - 1]);
            command = "";
            icon = null;
            x = 0;
            y = 0;
            autolaunch = false;
            lowered = false;
            continue;
        }

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t\"");

        if (std.mem.eql(u8, key, "command")) {
            command = try arena.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "icon")) {
            icon = try arena.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "position")) {
            if (parsePosition(value)) |xy| {
                x = xy[0];
                y = xy[1];
            }
        } else if (std.mem.eql(u8, key, "autolaunch")) {
            autolaunch = config.parseBool(value) catch false;
        } else if (std.mem.eql(u8, key, "lowered")) {
            lowered = config.parseBool(value) catch false;
        }
        // Unknown keys: ignored on purpose, see doc comment above.
    }
    try flushDockApp(arena, &apps, name, command, icon, x, y, autolaunch, lowered);

    return .{ .apps = try apps.toOwnedSlice(arena) };
}

/// Append the block being accumulated by parseOwn as a DockApp, if it has
/// both a name (saw a `[...]` header) and a non-empty command. Silently
/// dropped otherwise -- same "incomplete entry is skipped, not fatal"
/// policy as parseWMStateEntry.
fn flushDockApp(
    arena: std.mem.Allocator,
    apps: *std.ArrayList(DockApp),
    name: ?[]const u8,
    command: []const u8,
    icon: ?[]const u8,
    x: i32,
    y: i32,
    autolaunch: bool,
    lowered: bool,
) Error!void {
    const n = name orelse return;
    if (command.len == 0) return;
    const argv = config.parseCommand(arena, command) catch return;
    try apps.append(arena, .{
        .name = n,
        .command = argv,
        .icon = icon,
        .x = x,
        .y = y,
        .autolaunch = autolaunch,
        .lowered = lowered,
    });
}

/// Same comment-stripping rule as config.zig's stripComment, minus the
/// hex-colour exception (dock app entries have no colour values).
fn stripComment(raw: []const u8) []const u8 {
    for (raw, 0..) |c, i| {
        if (c != '#') continue;
        if (i == 0 or raw[i - 1] == ' ' or raw[i - 1] == '\t') return raw[0..i];
    }
    return raw;
}

// ----------------------------------------------------------------------------
// Launching
// ----------------------------------------------------------------------------

/// Spawn every entry with `autolaunch = true`, in list order. Call once at
/// session start (see main.zig's autostart handling for the equivalent
/// non-dock case). Never fails the session: a spawn error is logged and
/// the rest of the list still runs.
pub fn runAutoLaunch(
    list: List,
    spawn: *const fn (argv: []const []const u8) void,
) void {
    for (list.apps) |app| {
        if (!app.autolaunch) continue;
        if (app.command.len == 0) continue;
        std.log.info("dockapp autolaunch: {s}", .{app.name});
        spawn(app.command);
    }
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

test "parse WMState Dock.Applications" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const list = try parseWMState(arena.allocator(),
        \\{
        \\  Dock = {
        \\    Applications = (
        \\      { Command = xterm; Name = "xterm.XTerm"; AutoLaunch = No; Position = "0,1"; },
        \\      { Command = "foot -e htop"; Name = foot; AutoLaunch = Yes; Position = "-1,0"; Lowered = Yes; }
        \\    );
        \\    Position = "-64,0";
        \\    Lowered = No;
        \\  };
        \\}
    );
    try std.testing.expectEqual(@as(usize, 2), list.apps.len);

    try std.testing.expectEqualStrings("xterm.XTerm", list.apps[0].name);
    try std.testing.expectEqual(@as(usize, 1), list.apps[0].command.len);
    try std.testing.expectEqualStrings("xterm", list.apps[0].command[0]);
    try std.testing.expectEqual(false, list.apps[0].autolaunch);
    try std.testing.expectEqual(@as(i32, 0), list.apps[0].x);
    try std.testing.expectEqual(@as(i32, 1), list.apps[0].y);

    try std.testing.expectEqualStrings("foot", list.apps[1].name);
    try std.testing.expectEqual(@as(usize, 3), list.apps[1].command.len);
    try std.testing.expectEqualStrings("foot", list.apps[1].command[0]);
    try std.testing.expectEqualStrings("-e", list.apps[1].command[1]);
    try std.testing.expectEqualStrings("htop", list.apps[1].command[2]);
    try std.testing.expectEqual(true, list.apps[1].autolaunch);
    try std.testing.expectEqual(true, list.apps[1].lowered);
    try std.testing.expectEqual(@as(i32, -1), list.apps[1].x);
}

test "parse WMState falls back to Clip.Applications when there is no Dock" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const list = try parseWMState(arena.allocator(),
        \\{ Clip = { Applications = ( { Command = xcalc; Name = xcalc; } ); }; }
    );
    try std.testing.expectEqual(@as(usize, 1), list.apps.len);
    try std.testing.expectEqualStrings("xcalc", list.apps[0].name);
}

test "parse WMState: missing Dock/Clip is an empty list, not an error" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const list = try parseWMState(arena.allocator(), "{ Workspaces = (); }");
    try std.testing.expect(list.isEmpty());
}

test "parse WMState: entry without Command is skipped, not fatal" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const list = try parseWMState(arena.allocator(),
        \\{ Dock = { Applications = ( { Name = "broken"; }, { Command = xterm; Name = xterm; } ); }; }
    );
    try std.testing.expectEqual(@as(usize, 1), list.apps.len);
    try std.testing.expectEqualStrings("xterm", list.apps[0].name);
}

test "parse own dockapps.conf format" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const list = try parseOwn(arena.allocator(),
        \\# comment
        \\[xterm]
        \\command = xterm -e htop
        \\icon = /usr/share/icons/xterm.png
        \\position = 0,1
        \\autolaunch = yes
        \\
        \\[calculator]
        \\command = "galculator"
        \\autolaunch = no
        \\lowered = true
    );
    try std.testing.expectEqual(@as(usize, 2), list.apps.len);

    try std.testing.expectEqualStrings("xterm", list.apps[0].name);
    try std.testing.expectEqual(@as(usize, 3), list.apps[0].command.len);
    try std.testing.expectEqualStrings("xterm", list.apps[0].command[0]);
    try std.testing.expectEqualStrings("-e", list.apps[0].command[1]);
    try std.testing.expectEqualStrings("htop", list.apps[0].command[2]);
    try std.testing.expectEqualStrings("/usr/share/icons/xterm.png", list.apps[0].icon.?);
    try std.testing.expectEqual(@as(i32, 0), list.apps[0].x);
    try std.testing.expectEqual(@as(i32, 1), list.apps[0].y);
    try std.testing.expectEqual(true, list.apps[0].autolaunch);

    try std.testing.expectEqualStrings("galculator", list.apps[1].name);
    try std.testing.expectEqual(false, list.apps[1].autolaunch);
    try std.testing.expectEqual(true, list.apps[1].lowered);
}

test "parse own format: entry without a command is dropped" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const list = try parseOwn(arena.allocator(),
        \\[nocmd]
        \\icon = foo.png
        \\
        \\[real]
        \\command = foot
    );
    try std.testing.expectEqual(@as(usize, 1), list.apps.len);
    try std.testing.expectEqualStrings("real", list.apps[0].name);
}

test "parse own format: last block flushes without a trailing blank line" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const list = try parseOwn(arena.allocator(), "[foot]\ncommand = foot\nautolaunch = yes");
    try std.testing.expectEqual(@as(usize, 1), list.apps.len);
    try std.testing.expectEqual(true, list.apps[0].autolaunch);
}

test "parse own format: unknown keys are ignored" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const list = try parseOwn(arena.allocator(),
        \\[foot]
        \\command = foot
        \\frobnicate = yes
    );
    try std.testing.expectEqual(@as(usize, 1), list.apps.len);
    try std.testing.expectEqualStrings("foot", list.apps[0].name);
}

test "runAutoLaunch spawns only autolaunch entries, in order" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const list = try parseOwn(arena.allocator(),
        \\[a]
        \\command = cmd-a
        \\autolaunch = yes
        \\
        \\[b]
        \\command = cmd-b
        \\autolaunch = no
        \\
        \\[c]
        \\command = cmd-c
        \\autolaunch = yes
    );

    const Recorder = struct {
        var seen: [4][]const u8 = undefined;
        var count: usize = 0;

        fn record(argv: []const []const u8) void {
            seen[count] = argv[0];
            count += 1;
        }
    };
    Recorder.count = 0;

    runAutoLaunch(list, &Recorder.record);

    try std.testing.expectEqual(@as(usize, 2), Recorder.count);
    try std.testing.expectEqualStrings("cmd-a", Recorder.seen[0]);
    try std.testing.expectEqualStrings("cmd-c", Recorder.seen[1]);
}

test "isSelfDeclared recognises both prefixes, case-sensitively" {
    try std.testing.expect(isSelfDeclared("dockapp:clock"));
    try std.testing.expect(isSelfDeclared("dockapp-clock"));
    try std.testing.expect(isSelfDeclared("dockapp:"));
    try std.testing.expect(!isSelfDeclared("dockapp"));
    try std.testing.expect(!isSelfDeclared("DockApp:clock"));
    try std.testing.expect(!isSelfDeclared("firefox"));
    try std.testing.expect(!isSelfDeclared(null));
}

test "defaultAttrs: no title bar, no border, floating, hidden from the window list" {
    const a = defaultAttrs();
    try std.testing.expect(a.is("no_titlebar"));
    try std.testing.expect(a.is("no_border"));
    try std.testing.expect(a.is("floating"));
    try std.testing.expect(a.is("skip_window_list"));
    // Everything else is left null, so an attributes.conf rule can still
    // set e.g. StartWorkspace for this app_id without a conflict.
    try std.testing.expect(a.start_workspace == null);
}

test "self-declared defaults lose to an explicit attributes.conf rule, per option" {
    // Mirrors window.zig's app_id handling: wm.attrs.lookup() first, then
    // withDefaults(dockapp.defaultAttrs()) fills in only what the file
    // left unset.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const r = try wm_attr.parse(arena.allocator(),
        \\{ "dockapp:clock" = { NoBorder = No; }; }
    );
    const looked_up = r.table.lookup("dockapp:clock");
    const final = looked_up.withDefaults(defaultAttrs());

    // The file said NoBorder = No: that wins over defaultAttrs()'s true.
    try std.testing.expectEqual(false, final.no_border.?);
    // NoTitlebar wasn't mentioned in the file, so the self-declared
    // default (true) still applies.
    try std.testing.expect(final.is("no_titlebar"));
}
