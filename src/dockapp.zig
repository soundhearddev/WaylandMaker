// SPDX-License-Identifier: 0BSD
//
// DockApps: a standard entry format for "one command, one icon, one dock
// slot" applications, so every future dock (or Clip, or a status area) can
// share a single parser and a single launch path instead of each growing
// its own.
//
// This module is the DATA side of the Dock and the Clip (the drawing and
// the clicks live in dock.zig and ui.zig): what is in them, in which
// order, and how a running window is matched to a tile. It also serves
// anything else that wants a "list of dock apps", such as AutoLaunch at
// session start. The data is:
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
//
// Dock or Clip? Window Maker has two places an application can be docked:
// the Dock (one column of tiles on a screen edge, always the same) and the
// Clip (a tile that follows the workspace; every workspace has its own set
// of clipped applications). An entry says which one with `place = dock`
// (the default) or `place = clip`; a Clip entry may also name a
// `workspace` (1-based) and then only shows up there.

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
/// (it's a small tile, not a normal window), floating (a fixed-size tile
/// should never join the tiling layout), omnipresent (the Dock does not
/// change with the workspace, so what sits in it must not either), hidden
/// from the Windows menu
/// (see ui.zig's buildWindowLevel), and unfocusable -- a dock tile is
/// meant to be looked at and clicked, not to steal keyboard focus the
/// moment it starts or to show up in Alt-equivalent focus cycling
/// (focus_previous, click-to-focus; see main.zig's focusable()). Returned
/// as `Attributes` with everything else left `null`, so `withDefaults`
/// lets an explicit attributes.conf rule for this app_id override any
/// part of this -- an interactive DockApp that *does* want keyboard focus
/// (a small mixer with a text field, say) sets `Unfocusable = No` for its
/// own app_id and keeps every other default.
pub fn defaultAttrs() wm_attr.Attributes {
    return .{
        .no_titlebar = true,
        .no_border = true,
        .floating = true,
        .omnipresent = true,
        .skip_window_list = true,
        .unfocusable = true,
    };
}

/// Where an entry lives: the Dock or the Clip.
pub const Place = enum { dock, clip };

/// One dock slot. `x`/`y` are Window Maker's grid coordinates (in tiles),
/// not pixels (dock.zig's tile is 64px, Window Maker's own default). In the
/// Dock only `y` matters: the slots are sorted by it and then stacked
/// without gaps below the logo tile, which has y = 0 (List.logo_y). In the
/// Clip the entries are sorted by `x`, then `y`, into one row.
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
    /// on top. Stored; the Dock/Clip level is a config.conf option
    /// (`dock_on_top`, `clip_on_top`), not a per-entry one.
    lowered: bool = false,
    /// The Dock (default) or the Clip.
    place: Place = .dock,
    /// Clip only: the 0-based workspace this entry belongs to; null = it is
    /// shown on every workspace.
    workspace: ?u32 = null,
    /// Explicit app_id of the windows this entry starts. Optional: without
    /// it `matches` derives candidates from the name and the command.
    app_id: ?[]const u8 = null,

    /// Does a window with this app_id belong to this entry (is the entry
    /// "running", and which window does a click on it focus)? Compared
    /// case-insensitively, like wm_attr.zig does for Window Maker's X11
    /// class names. In order:
    ///   1. an explicit `app_id` is authoritative and nothing else counts;
    ///   2. `dockapp:<n>` / `dockapp-<n>` where <n> is the entry's name;
    ///   3. a part of a Window Maker name "instance.Class";
    ///   4. an argument that is itself a self-declared app_id (a terminal
    ///      started with `--class dockapp:htop`) -- then ONLY that counts,
    ///      or every window of that terminal would look like this entry;
    ///   5. the program's file name (`/usr/bin/firefox` -> `firefox`).
    pub fn matches(app: DockApp, window_app_id: []const u8) bool {
        const eql = std.ascii.eqlIgnoreCase;
        if (window_app_id.len == 0) return false;
        if (app.app_id) |id| return eql(id, window_app_id);

        if (declaredName(window_app_id)) |n| {
            if (eql(n, app.name)) return true;
        }

        var parts = std.mem.splitScalar(u8, app.name, '.');
        while (parts.next()) |part| {
            if (part.len > 0 and eql(part, window_app_id)) return true;
        }

        var forced = false;
        for (app.command) |arg| {
            const v = stripClassFlag(arg);
            if (!isSelfDeclared(v)) continue;
            forced = true;
            if (eql(v, window_app_id)) return true;
        }
        if (forced or app.command.len == 0) return false;
        return eql(std.fs.path.basename(app.command[0]), window_app_id);
    }
};

/// `--class=dockapp:x` / `--app-id=dockapp:x` / `--name=dockapp:x` -> the
/// value; anything else is returned unchanged.
fn stripClassFlag(arg: []const u8) []const u8 {
    inline for (.{ "--class=", "--app-id=", "--name=" }) |flag| {
        if (std.mem.startsWith(u8, arg, flag)) return arg[flag.len..];
    }
    return arg;
}

/// "dockapp:clock" -> "clock"; null if `app_id` is not self-declared.
pub fn declaredName(app_id: []const u8) ?[]const u8 {
    for (self_declaring_prefixes) |prefix| {
        if (std.mem.startsWith(u8, app_id, prefix)) return app_id[prefix.len..];
    }
    return null;
}

pub const List = struct {
    /// Dock and Clip entries together; `DockApp.place` tells them apart.
    apps: []const DockApp = &.{},
    /// Workspace names from Window Maker's WMState (index = workspace).
    /// config.conf's `workspace_names` wins over these.
    workspace_names: []const []const u8 = &.{},
    /// Grid y of the Dock's logo tile (WMState's "Logo.WMDock" entry).
    /// Entries above it have a smaller y; ties go below the logo.
    logo_y: i32 = 0,

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

/// Like `parseWMState`, but for BOTH places at once: Window Maker's
/// `Dock.Applications`, plus the Clip's applications -- the top-level `Clip`
/// (all workspaces) and every workspace's own `Workspaces[i].Clip` -- and
/// the workspace names. The logo tile (`Command = "-"`, Name
/// "Logo.WMDock") is not an application: it only tells where the Dock's
/// column is anchored (List.logo_y). Missing sections are fine.
pub fn parseWMStateAll(arena: std.mem.Allocator, text: []const u8) Error!List {
    return parseWMStateAllDiag(arena, text, null);
}

pub fn parseWMStateAllDiag(arena: std.mem.Allocator, text: []const u8, diag: ?*plist.Diag) Error!List {
    const root = try plist.parse(arena, text, diag);

    var apps: std.ArrayList(DockApp) = .empty;
    var names: std.ArrayList([]const u8) = .empty;
    var result: List = .{};

    if (root.get("Dock")) |dock| {
        if (dock.get("Applications")) |items| {
            for (items.items() orelse &.{}) |entry| {
                if (isLogoEntry(entry)) {
                    if (entry.get("Position")) |v| {
                        if (v.str()) |s| if (parsePosition(s)) |xy| {
                            result.logo_y = xy[1];
                        };
                    }
                    continue;
                }
                var app = parseWMStateEntry(arena, entry) orelse continue;
                app.place = .dock;
                try apps.append(arena, app);
            }
        }
    }

    if (root.get("Clip")) |clip| try appendClip(arena, &apps, clip, null);

    if (root.get("Workspaces")) |wss| {
        for (wss.items() orelse &.{}, 0..) |w, i| {
            // Old files list plain names, newer ones a dictionary per
            // workspace with a Name and that workspace's Clip.
            const name: []const u8 = if (w.str()) |s|
                s
            else if (w.get("Name")) |n|
                (n.str() orelse "")
            else
                "";
            try names.append(arena, name);
            if (w.get("Clip")) |clip| try appendClip(arena, &apps, clip, @intCast(i));
        }
    }

    result.apps = try apps.toOwnedSlice(arena);
    result.workspace_names = try names.toOwnedSlice(arena);
    return result;
}

fn appendClip(arena: std.mem.Allocator, apps: *std.ArrayList(DockApp), clip: plist.Value, workspace: ?u32) Error!void {
    const items = clip.get("Applications") orelse return;
    for (items.items() orelse &.{}) |entry| {
        if (isLogoEntry(entry)) continue;
        var app = parseWMStateEntry(arena, entry) orelse continue;
        app.place = .clip;
        app.workspace = workspace;
        try apps.append(arena, app);
    }
}

/// Window Maker stores the Dock's and Clip's own tiles as pseudo entries
/// with the command "-" and a Name of "Logo.WMDock" / "Logo.WMClip".
fn isLogoEntry(entry: plist.Value) bool {
    if (entry.get("Command")) |c| {
        if (c.str()) |s| if (std.mem.eql(u8, std.mem.trim(u8, s, " \t"), "-")) return true;
    }
    if (entry.get("Name")) |n| {
        if (n.str()) |s| if (std.mem.startsWith(u8, s, "Logo.")) return true;
    }
    return false;
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
    var block: Block = .{};

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, stripComment(raw), " \t\r");
        if (line.len == 0) continue;

        if (line[0] == '[' and line[line.len - 1] == ']') {
            try flushDockApp(arena, &apps, block);
            block = .{ .name = try arena.dupe(u8, line[1 .. line.len - 1]) };
            continue;
        }

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t\"");

        if (std.mem.eql(u8, key, "command")) {
            block.command = try arena.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "icon")) {
            block.icon = try arena.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "app_id")) {
            block.app_id = if (value.len > 0) try arena.dupe(u8, value) else null;
        } else if (std.mem.eql(u8, key, "position")) {
            if (parsePosition(value)) |xy| {
                block.x = xy[0];
                block.y = xy[1];
            }
        } else if (std.mem.eql(u8, key, "autolaunch")) {
            block.autolaunch = config.parseBool(value) catch false;
        } else if (std.mem.eql(u8, key, "lowered")) {
            block.lowered = config.parseBool(value) catch false;
        } else if (std.mem.eql(u8, key, "place")) {
            // An unknown place keeps the default (the Dock).
            if (std.meta.stringToEnum(Place, value)) |pl| block.place = pl;
        } else if (std.mem.eql(u8, key, "workspace")) {
            if (std.ascii.eqlIgnoreCase(value, "all")) {
                block.workspace = null;
            } else if (std.fmt.parseInt(u32, value, 10) catch null) |n| {
                // 1-based in the file, 0-based inside. "0" is not a workspace.
                if (n >= 1) block.workspace = n - 1;
            }
        }
        // Unknown keys: ignored on purpose, see doc comment above.
    }
    try flushDockApp(arena, &apps, block);

    return .{ .apps = try apps.toOwnedSlice(arena) };
}

/// The `[name]` block parseOwn is currently reading.
const Block = struct {
    name: ?[]const u8 = null,
    command: []const u8 = "",
    icon: ?[]const u8 = null,
    app_id: ?[]const u8 = null,
    x: i32 = 0,
    y: i32 = 0,
    autolaunch: bool = false,
    lowered: bool = false,
    place: Place = .dock,
    workspace: ?u32 = null,
};

/// Append the block being accumulated by parseOwn as a DockApp, if it has
/// both a name (saw a `[...]` header) and a non-empty command. Silently
/// dropped otherwise -- same "incomplete entry is skipped, not fatal"
/// policy as parseWMStateEntry.
fn flushDockApp(arena: std.mem.Allocator, apps: *std.ArrayList(DockApp), block: Block) Error!void {
    const n = block.name orelse return;
    if (block.command.len == 0) return;
    const argv = config.parseCommand(arena, block.command) catch return;
    try apps.append(arena, .{
        .name = n,
        .command = argv,
        .icon = block.icon,
        .x = block.x,
        .y = block.y,
        .autolaunch = block.autolaunch,
        .lowered = block.lowered,
        .place = block.place,
        .workspace = block.workspace,
        .app_id = block.app_id,
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

    try std.testing.expectEqualStrings("calculator", list.apps[1].name);
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

test "defaultAttrs: omnipresent, so the Dock follows the user" {
    try std.testing.expect(defaultAttrs().is("omnipresent"));
}

test "own format: place, workspace and app_id" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const list = try parseOwn(arena.allocator(),
        \\[term]
        \\command = foot
        \\[notes]
        \\command = gedit
        \\place = clip
        \\workspace = 2
        \\app_id = org.gnome.gedit
        \\[all]
        \\command = foot
        \\place = clip
        \\workspace = all
        \\[bogus]
        \\command = foot
        \\place = shelf
        \\workspace = 0
    );
    try std.testing.expectEqual(@as(usize, 4), list.apps.len);
    try std.testing.expectEqual(Place.dock, list.apps[0].place);
    try std.testing.expectEqual(Place.clip, list.apps[1].place);
    try std.testing.expectEqual(@as(?u32, 1), list.apps[1].workspace); // "2" -> 0-based 1
    try std.testing.expectEqualStrings("org.gnome.gedit", list.apps[1].app_id.?);
    try std.testing.expectEqual(@as(?u32, null), list.apps[2].workspace);
    // Unknown place: the Dock. "workspace = 0" is not a workspace: unset.
    try std.testing.expectEqual(Place.dock, list.apps[3].place);
    try std.testing.expectEqual(@as(?u32, null), list.apps[3].workspace);
}

test "matches: explicit app_id, dockapp name, instance.Class, program name" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const explicit: DockApp = .{ .name = "x", .command = &.{"gedit"}, .app_id = "org.gnome.gedit" };
    try std.testing.expect(explicit.matches("ORG.gnome.gedit"));
    // An explicit app_id is authoritative: the program name no longer counts.
    try std.testing.expect(!explicit.matches("gedit"));

    const clock: DockApp = .{ .name = "clock", .command = &.{"wl-clock"} };
    try std.testing.expect(clock.matches("dockapp:clock"));
    try std.testing.expect(clock.matches("dockapp-Clock"));
    try std.testing.expect(!clock.matches("dockapp:other"));

    const xterm: DockApp = .{ .name = "xterm.XTerm", .command = &.{"xterm"} };
    try std.testing.expect(xterm.matches("XTerm"));
    try std.testing.expect(xterm.matches("xterm"));
    try std.testing.expect(!xterm.matches("foot"));

    const path: DockApp = .{ .name = "web", .command = &.{"/usr/bin/firefox"} };
    try std.testing.expect(path.matches("Firefox"));
    try std.testing.expect(!path.matches(""));

    // A terminal started with --class dockapp:htop must not make every
    // window of that terminal look like "running htop".
    const htop: DockApp = .{
        .name = "htop",
        .command = try config.parseCommand(a, "alacritty --class dockapp:htop -e htop"),
    };
    try std.testing.expect(htop.matches("dockapp:htop"));
    try std.testing.expect(!htop.matches("Alacritty"));
    try std.testing.expect(!htop.matches("alacritty"));

    const flag: DockApp = .{
        .name = "t",
        .command = try config.parseCommand(a, "foot --app-id=dockapp:top -e top"),
    };
    try std.testing.expect(flag.matches("dockapp:top"));
    try std.testing.expect(!flag.matches("foot"));
}

test "WMState (all): Dock, per-workspace Clip, names and the logo tile" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const list = try parseWMStateAll(arena.allocator(),
        \\{
        \\  Dock = {
        \\    Applications = (
        \\      { Command = "-"; Name = Logo.WMDock; Position = "0,1"; },
        \\      { Command = xterm; Name = "xterm.XTerm"; Position = "0,2"; AutoLaunch = Yes; },
        \\      { Command = xcalc; Name = xcalc; Position = "0,0"; }
        \\    );
        \\  };
        \\  Clip = { Applications = ( { Command = gimp; Name = gimp; } ); };
        \\  Workspaces = (
        \\    { Name = Main; Clip = { Applications = ( { Command = foot; Name = foot; } ); }; },
        \\    { Name = Web; },
        \\    "Plain"
        \\  );
        \\}
    );
    // The logo is not an app; its position is the anchor.
    try std.testing.expectEqual(@as(i32, 1), list.logo_y);
    try std.testing.expectEqual(@as(usize, 4), list.apps.len);
    try std.testing.expectEqualStrings("xterm.XTerm", list.apps[0].name);
    try std.testing.expectEqual(Place.dock, list.apps[0].place);
    try std.testing.expect(list.apps[0].autolaunch);
    try std.testing.expectEqual(Place.dock, list.apps[1].place);
    // Top-level Clip: every workspace. Workspace 0's Clip: only workspace 0.
    try std.testing.expectEqual(Place.clip, list.apps[2].place);
    try std.testing.expectEqual(@as(?u32, null), list.apps[2].workspace);
    try std.testing.expectEqual(Place.clip, list.apps[3].place);
    try std.testing.expectEqual(@as(?u32, 0), list.apps[3].workspace);
    // Names, both spellings, kept aligned with the workspace numbers.
    try std.testing.expectEqual(@as(usize, 3), list.workspace_names.len);
    try std.testing.expectEqualStrings("Main", list.workspace_names[0]);
    try std.testing.expectEqualStrings("Web", list.workspace_names[1]);
    try std.testing.expectEqualStrings("Plain", list.workspace_names[2]);
}

test "WMState (all): nothing in it is an empty list" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const list = try parseWMStateAll(arena.allocator(), "{ Foo = Bar; }");
    try std.testing.expect(list.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), list.workspace_names.len);
}

test "the shipped dockapps.conf parses: Dock and Clip entries" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const list = try parseOwn(arena.allocator(), @embedFile("share/dockapps.conf"));
    var docks: usize = 0;
    var clips: usize = 0;
    for (list.apps) |app| switch (app.place) {
        .dock => docks += 1,
        .clip => clips += 1,
    };
    try std.testing.expectEqual(@as(usize, 3), docks);
    try std.testing.expectEqual(@as(usize, 2), clips);
    try std.testing.expectEqualStrings("terminal", list.apps[3].name);
    try std.testing.expectEqual(@as(?u32, null), list.apps[3].workspace);
    try std.testing.expectEqual(@as(?u32, 1), list.apps[4].workspace);
    // The clock is a Dock tile and matches the example client's app_id.
    try std.testing.expect(list.apps[0].matches("dockapp:clock"));
}
