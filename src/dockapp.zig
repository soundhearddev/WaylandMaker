// SPDX-License-Identifier: 0BSD
//
// DockApps: the DATA side of the Dock and the Clip (drawing and clicks live
// in dock.zig and ui.zig): what is docked, in which order, and how a running
// window is matched to a tile.
//
// There is exactly ONE file format, Window Maker's own: the GNUstep property
// list WMState. wmaker-wl reads and writes it (its own copy lives in
// $XDG_STATE_HOME/wmaker-wl/WMState, see wm_files.zig); an existing
// ~/GNUstep/Defaults/WMState is read when enable_wmaker_compat is on.
// wmaker-wl-only values use keys prefixed `WMakerWL`, which real Window
// Maker ignores.
//
// How a DockApp gets into the Dock (see dockhost.zig for all of it):
//
//   * A DockApp is an ordinary program. Start it from `autostart`, from a
//     menu, from a terminal -- or let an entry with `AutoLaunch = Yes` start
//     it. It declares itself with ONE tag: its app_id is `dockapp:<name>`.
//   * That tag makes it an icon, not a window: it is out of the window list,
//     the layout and the focus, sits in a Dock tile at a size the compositor
//     chooses (what it asked for, at most one tile) and cannot be closed
//     with the close key. Only "Kill" in the tile's menu ends it.
//   * A DockApp without a matching entry gets a temporary tile for as long as
//     it runs ("attached"); "Keep Icon" in the tile's menu makes the tile
//     permanent (it is then saved in WMState, with the command `<name>`, so
//     name the app_id after the program).
//   * Normal applications are docked with "Keep Application" and are
//     started and focused from their tile.
//
// Dock or Clip? The Dock is one column of tiles on a screen edge; the Clip
// is a tile that follows the workspace, each workspace having its own set of
// clipped applications.

// (the default) or `place = clip`; a Clip entry may also name a
// `workspace` (1-based) and then only shows up there.

const std = @import("std");
const plist = @import("plist.zig");
const config = @import("config.zig");

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
// No config file, nothing to register. A user who
// wants to override the look for one specific DockApp can still add a
// normal attributes.conf rule keyed on its app_id -- explicit file rules
// win over these defaults, see window.zig's app_id handling.
//
// Naming the app_id is the standalone author's job (see
// examples/wl-clock/README.md for a worked example); parsing it is
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

/// May `id` become the name and app_id of a new Dock entry? Only plain
/// program identifiers: no blanks, quotes, slashes or control characters,
/// so nothing odd ends up in the saved state file or on a command line.
pub fn validAppId(id: []const u8) bool {
    if (id.len == 0 or id.len > 100) return false;
    for (id) |c| {
        const ok = std.ascii.isAlphanumeric(c) or c == '.' or c == '-' or c == '_' or c == '+';
        if (!ok) return false;
    }
    return id[0] != '.' and id[0] != '-';
}

/// Where an entry lives: the Dock or the Clip.
pub const Place = enum { dock, clip, drawer };

/// A Drawer of the Dock (Window Maker's WM_DRAWER): a row of tiles that
/// hangs off the Dock at tile row `row` (relative to the Dock's first tile).
/// Its applications are the DockApps with `place == .drawer` and
/// `drawer == index in List.drawers`.
pub const DrawerInfo = struct {
    name: []const u8 = "Drawer",
    row: i32 = 1,
    collapsed: bool = true,
    auto_collapse: bool = true,
};

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
    /// on top. Stored; the Dock/Clip level is a config.lua option
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
    /// Window Maker's "Lock": the tile cannot be dragged away or removed.
    locked: bool = false,
    /// Index into `List.drawers` when `place == .drawer`.
    drawer: u32 = 0,
    /// A DockApp that is running without an entry of its own: its tile exists
    /// only while it runs and is never saved (see dock.zig `Model.attach`).
    attached: bool = false,
    /// Not 0: the temporary tile of ONE minimized window, the value of its
    /// `Window.min_order` (unique per minimize). Such a tile is `attached`
    /// too (never saved), is not an application (`matches` is not used for
    /// it) and goes when the window is restored (dock.zig `Model.attachWindow`).
    mini_window: u64 = 0,

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
    ///   5. the program's file name (`/usr/bin/firefox` -> `firefox`);
    ///   6. the last part of a reverse-DNS app_id (`org.mozilla.firefox`) is
    ///      that file name or a part of the name.
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
        if (forced) return false;
        if (app.command.len > 0 and eql(std.fs.path.basename(app.command[0]), window_app_id)) return true;

        // A reverse-DNS app_id ("org.mozilla.firefox", "org.gnome.Nautilus"),
        // which is what most Wayland programs use: its last part is the
        // program's name. Without this a docked Firefox looks "not running"
        // (three dots in the tile's corner) while it is.
        if (std.mem.lastIndexOfScalar(u8, window_app_id, '.')) |dot| {
            const tail = window_app_id[dot + 1 ..];
            if (tail.len > 0) {
                if (app.command.len > 0 and eql(std.fs.path.basename(app.command[0]), tail)) return true;
                var np = std.mem.splitScalar(u8, app.name, '.');
                while (np.next()) |part| {
                    if (part.len > 0 and eql(part, tail)) return true;
                }
            }
        }
        return false;
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
    /// config.lua's `workspace_names` wins over these.
    workspace_names: []const []const u8 = &.{},
    /// The Dock's Drawers, in order.
    drawers: []const DrawerInfo = &.{},
    /// Grid y of the Dock's logo tile (WMState's "Logo.WMDock" entry).
    /// Entries above it have a smaller y; ties go below the logo.
    logo_y: i32 = 0,
    /// Set whenever the file had a Dock or Clip section (see `State`). The
    /// first file that has one wins, even if it is empty (the user removed
    /// every tile).
    state: ?State = null,

    pub fn isEmpty(self: List) bool {
        return self.apps.len == 0;
    }
};

/// The part of the Dock's and Clip's look that the user changes with the
/// mouse or the menus and that Window Maker saves in WMState: where the Dock
/// sits and its stacking level, and the Clip's switches. null = "not in the
/// file, config.lua decides".
pub const State = struct {
    edge: ?config.DockEdge = null,
    offset: ?i32 = null,
    dock_on_top: ?bool = null,
    dock_auto_raise: ?bool = null,
    clip_corner: ?config.ClipCorner = null,
    clip_on_top: ?bool = null,
    clip_collapsed: ?bool = null,
    clip_auto_collapse: ?bool = null,
    clip_auto_raise: ?bool = null,
};

pub const Error = error{ Syntax, OutOfMemory };

// ----------------------------------------------------------------------------
// Reading WMState: { Dock = { Applications = ( {...}, ... ); }; Clip = ...; }
// ----------------------------------------------------------------------------

/// Parse a WMState property list and return its Dock's (or, if there is no
/// Dock, its Clip's) Applications list. Missing sections are not an error.
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

/// Everything WMState says about the Dock and the Clip: `Dock.Applications`,
/// the Clip's applications (top-level `Clip` = all workspaces, and every
/// `Workspaces[i].Clip`), the workspace names and the switches (`State`).
/// The logo tile (`Command = "-"`) is not an application: it only anchors
/// the Dock's column (List.logo_y).
pub fn parseWMStateAll(arena: std.mem.Allocator, text: []const u8) Error!List {
    return parseWMStateAllDiag(arena, text, null);
}

pub fn parseWMStateAllDiag(arena: std.mem.Allocator, text: []const u8, diag: ?*plist.Diag) Error!List {
    const root = try plist.parse(arena, text, diag);

    var apps: std.ArrayList(DockApp) = .empty;
    var names: std.ArrayList([]const u8) = .empty;
    var result: List = .{};
    var st: State = .{};
    var has_state = false;

    if (root.get("Dock")) |dock| {
        has_state = true;
        readDockState(dock, &st);
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

    if (root.get("Clip")) |clip| {
        has_state = true;
        readClipState(clip, &st);
        try appendClip(arena, &apps, clip, null);
    }

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

    var drawers: std.ArrayList(DrawerInfo) = .empty;
    if (root.get("Drawers")) |ds| {
        has_state = true;
        for (ds.items() orelse &.{}, 0..) |d, i| {
            var info: DrawerInfo = .{};
            if (readStr(d, "Name")) |n| info.name = n;
            if (readStr(d, "WMakerWLRow")) |r| {
                if (std.fmt.parseInt(i32, r, 10) catch null) |row| {
                    if (@abs(row) <= max_grid) info.row = row;
                }
            }
            if (d.get("Dock")) |dd| {
                if (readBool(dd, "Collapsed")) |b| info.collapsed = b;
                if (readBool(dd, "AutoCollapse")) |b| info.auto_collapse = b;
                if (dd.get("Applications")) |items| {
                    for (items.items() orelse &.{}) |entry| {
                        if (isLogoEntry(entry)) continue;
                        var app = parseWMStateEntry(arena, entry) orelse continue;
                        app.place = .drawer;
                        app.drawer = @intCast(i);
                        try apps.append(arena, app);
                    }
                }
            }
            try drawers.append(arena, info);
        }
    }

    result.apps = try apps.toOwnedSlice(arena);
    result.workspace_names = try names.toOwnedSlice(arena);
    result.drawers = try drawers.toOwnedSlice(arena);
    if (has_state) result.state = st;
    return result;
}

fn readBool(v: plist.Value, key: []const u8) ?bool {
    const x = v.get(key) orelse return null;
    return x.boolean();
}

fn readStr(v: plist.Value, key: []const u8) ?[]const u8 {
    const x = v.get(key) orelse return null;
    return x.str();
}

fn readDockState(dock: plist.Value, st: *State) void {
    if (readBool(dock, "Lowered")) |l| st.dock_on_top = !l;
    if (readBool(dock, "AutoRaiseLower")) |a| st.dock_auto_raise = a;
    if (readStr(dock, "WMakerWLEdge")) |s| st.edge = std.meta.stringToEnum(config.DockEdge, s);
    if (readStr(dock, "WMakerWLOffset")) |s| {
        if (std.fmt.parseInt(i32, s, 10) catch null) |n| {
            if (n >= 0 and n <= 100000) st.offset = n;
        }
    }
}

fn readClipState(clip: plist.Value, st: *State) void {
    if (readBool(clip, "Lowered")) |l| st.clip_on_top = !l;
    if (readBool(clip, "Collapsed")) |c| st.clip_collapsed = c;
    if (readBool(clip, "AutoCollapse")) |c| st.clip_auto_collapse = c;
    if (readBool(clip, "AutoRaiseLower")) |a| st.clip_auto_raise = a;
    if (readStr(clip, "WMakerWLCorner")) |s| st.clip_corner = std.meta.stringToEnum(config.ClipCorner, s);
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
    // "Command" is a full command line in Window Maker's files (it is handed
    // to /bin/sh there); wmaker-wl's spawn wants argv, so it is split the
    // same way config.zig splits `terminal =` / `launcher =` lines.
    const command_line = entry.get("Command") orelse return null;
    const command_str = command_line.str() orelse return null;
    const command = config.parseCommand(arena, command_str) catch return null;

    var app: DockApp = .{ .name = command_str, .command = command };
    if (entry.get("Name")) |n| {
        if (n.str()) |s| app.name = s;
    }
    if (readBool(entry, "AutoLaunch")) |b| app.autolaunch = b;
    if (readBool(entry, "Lowered")) |b| app.lowered = b;
    if (readBool(entry, "Lock")) |b| app.locked = b;
    if (readStr(entry, "WMakerWLIcon")) |s| {
        if (s.len > 0) app.icon = s;
    }
    if (readStr(entry, "WMakerWLAppId")) |s| {
        if (s.len > 0) app.app_id = s;
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
    // A grid cell is a tile: nothing real is thousands of tiles away, and a
    // damaged file must not push `index * 64` past what an i32 can hold.
    if (@abs(x) > max_grid or @abs(y) > max_grid) return null;
    return .{ x, y };
}

/// Largest grid coordinate (in tiles) read from a state file.
pub const max_grid: u32 = 4096;

// ----------------------------------------------------------------------------
// Writing WMState
// ----------------------------------------------------------------------------

fn yn(b: bool) []const u8 {
    return if (b) "Yes" else "No";
}

/// Can `app` be written back faithfully? What the command splitter cannot
/// read back (empty arguments, a `"` inside one) is left out, not mangled.
fn writable(app: DockApp) bool {
    if (app.attached or app.command.len == 0) return false;
    for (app.command) |arg| {
        if (arg.len == 0) return false;
        for (arg) |c| if (c == '"' or c == 0 or c == '\n' or c == '\r') return false;
    }
    return true;
}

/// A string body for a double-quoted plist string.
fn writeEscaped(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n', '\r', 0 => try w.writeByte(' '),
        else => try w.writeByte(c),
    };
}

fn writeQuoted(w: *std.Io.Writer, key: []const u8, value: []const u8) std.Io.Writer.Error!void {
    try w.print("        {s} = \"", .{key});
    try writeEscaped(w, value);
    try w.writeAll("\";\n");
}

fn sep(w: *std.Io.Writer, first: *bool) std.Io.Writer.Error!void {
    if (!first.*) try w.writeAll(",\n");
    first.* = false;
}

fn writeLogo(w: *std.Io.Writer, first: *bool) std.Io.Writer.Error!void {
    try sep(w, first);
    try w.writeAll(
        \\      {
        \\        Name = "Logo.WMDock";
        \\        Command = "-";
        \\        Lock = Yes;
        \\        Position = "0,0";
        \\      }
    );
}

fn writeEntry(w: *std.Io.Writer, app: DockApp, first: *bool) std.Io.Writer.Error!void {
    try sep(w, first);
    try w.writeAll("      {\n");
    try writeQuoted(w, "Name", app.name);
    try w.writeAll("        Command = \"");
    for (app.command, 0..) |arg, i| {
        if (i > 0) try w.writeByte(' ');
        const quote = std.mem.indexOfAny(u8, arg, " \t") != null;
        if (quote) try w.writeAll("\\\"");
        try writeEscaped(w, arg);
        if (quote) try w.writeAll("\\\"");
    }
    try w.writeAll("\";\n");
    try w.print("        Position = \"{d},{d}\";\n", .{ app.x, app.y });
    try w.print("        AutoLaunch = {s};\n        Lock = {s};\n", .{ yn(app.autolaunch), yn(app.locked) });
    if (app.lowered) try w.writeAll("        Lowered = Yes;\n");
    if (app.icon) |v| try writeQuoted(w, "WMakerWLIcon", v);
    if (app.app_id) |v| try writeQuoted(w, "WMakerWLAppId", v);
    try w.writeAll("      }");
}

/// The Clip applications of workspace `ws` (null = all workspaces).
fn writeClipApps(w: *std.Io.Writer, apps: []const DockApp, ws: ?u32, skipped: *usize) std.Io.Writer.Error!void {
    var first = true;
    try w.writeAll("    Applications = (\n");
    for (apps) |app| {
        if (app.place != .clip or app.attached) continue;
        if (!std.meta.eql(app.workspace, ws)) continue;
        if (!writable(app)) {
            skipped.* += 1;
            continue;
        }
        try writeEntry(w, app, &first);
    }
    try w.writeAll("\n    );\n");
}

/// `list` and `state` as a WMState property list. Entries that cannot be
/// written back faithfully (see `writable`) are skipped; their number is
/// returned. Temporary (`attached`) tiles are never written.
pub fn render(w: *std.Io.Writer, list: List, state: State) std.Io.Writer.Error!usize {
    var skipped: usize = 0;
    try w.writeAll("{\n  Dock = {\n");
    if (state.dock_on_top) |v| try w.print("    Lowered = {s};\n", .{yn(!v)});
    if (state.dock_auto_raise) |v| try w.print("    AutoRaiseLower = {s};\n", .{yn(v)});
    if (state.edge) |e| try w.print("    WMakerWLEdge = \"{s}\";\n", .{@tagName(e)});
    if (state.offset) |o| try w.print("    WMakerWLOffset = \"{d}\";\n", .{o});
    try w.writeAll("    Applications = (\n");
    var first = true;
    var logo_done = false;
    for (list.apps) |app| {
        if (app.place != .dock or app.attached) continue;
        if (!logo_done and app.y >= list.logo_y) {
            try writeLogo(w, &first);
            logo_done = true;
        }
        if (!writable(app)) {
            skipped += 1;
            continue;
        }
        try writeEntry(w, app, &first);
    }
    if (!logo_done) try writeLogo(w, &first);
    try w.writeAll("\n    );\n  };\n");

    try w.writeAll("  Clip = {\n");
    if (state.clip_on_top) |v| try w.print("    Lowered = {s};\n", .{yn(!v)});
    if (state.clip_collapsed) |v| try w.print("    Collapsed = {s};\n", .{yn(v)});
    if (state.clip_auto_collapse) |v| try w.print("    AutoCollapse = {s};\n", .{yn(v)});
    if (state.clip_auto_raise) |v| try w.print("    AutoRaiseLower = {s};\n", .{yn(v)});
    if (state.clip_corner) |c| try w.print("    WMakerWLCorner = \"{s}\";\n", .{@tagName(c)});
    try writeClipApps(w, list.apps, null, &skipped);
    try w.writeAll("  };\n");

    var n: usize = list.workspace_names.len;
    for (list.apps) |app| {
        if (app.place == .clip and !app.attached) {
            if (app.workspace) |ws| n = @max(n, @as(usize, ws) + 1);
        }
    }
    if (n > 0) {
        try w.writeAll("  Workspaces = (\n");
        for (0..n) |i| {
            if (i > 0) try w.writeAll(",\n");
            try w.writeAll("    {\n      Name = \"");
            if (i < list.workspace_names.len) try writeEscaped(w, list.workspace_names[i]);
            try w.writeAll("\";\n      Clip = {\n");
            try writeClipApps(w, list.apps, @intCast(i), &skipped);
            try w.writeAll("      };\n    }");
        }
        try w.writeAll("\n  );\n");
    }
    if (list.drawers.len > 0) {
        try w.writeAll("  Drawers = (\n");
        for (list.drawers, 0..) |d, di| {
            if (di > 0) try w.writeAll(",\n");
            try w.writeAll("    {\n      Name = \"");
            try writeEscaped(w, d.name);
            try w.print("\";\n      WMakerWLRow = \"{d}\";\n      Dock = {{\n", .{d.row});
            try w.print("        Collapsed = {s};\n        AutoCollapse = {s};\n", .{ yn(d.collapsed), yn(d.auto_collapse) });
            var dfirst = true;
            try w.writeAll("        Applications = (\n");
            for (list.apps) |app| {
                if (app.place != .drawer or app.drawer != di or app.attached) continue;
                if (!writable(app)) {
                    skipped += 1;
                    continue;
                }
                try writeEntry(w, app, &dfirst);
            }
            try w.writeAll("\n        );\n      };\n    }");
        }
        try w.writeAll("\n  );\n");
    }
    try w.writeAll("}\n");
    return skipped;
}

// ----------------------------------------------------------------------------
// Launching
// ----------------------------------------------------------------------------

/// Spawn every entry with `AutoLaunch = Yes`, in list order. Call once at
/// session start. Never fails the session: the rest of the list still runs.
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

test "isSelfDeclared recognises both prefixes, case-sensitively" {
    try std.testing.expect(isSelfDeclared("dockapp:clock"));
    try std.testing.expect(isSelfDeclared("dockapp-clock"));
    try std.testing.expect(isSelfDeclared("dockapp:"));
    try std.testing.expect(!isSelfDeclared("dockapp"));
    try std.testing.expect(!isSelfDeclared("DockApp:clock"));
    try std.testing.expect(!isSelfDeclared("firefox"));
    try std.testing.expect(!isSelfDeclared(null));
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

    // Wayland programs mostly use a reverse-DNS app_id: its last part counts.
    try std.testing.expect(path.matches("org.mozilla.firefox"));
    try std.testing.expect(!path.matches("org.mozilla.thunderbird"));
    try std.testing.expect(!path.matches("firefox.")); // no empty last part
    const nautilus: DockApp = .{ .name = "Nautilus", .command = &.{"nautilus"} };
    try std.testing.expect(nautilus.matches("org.gnome.Nautilus"));
    try std.testing.expect(!nautilus.matches("org.gnome.gedit"));
    const named: DockApp = .{ .name = "gedit.Gedit", .command = &.{} };
    try std.testing.expect(named.matches("org.gnome.gedit"));

    // A terminal started with --class dockapp:htop must not make every
    // window of that terminal look like "running htop".
    const htop: DockApp = .{
        .name = "htop",
        .command = try config.parseCommand(a, "alacritty --class dockapp:htop -e htop"),
    };
    try std.testing.expect(htop.matches("dockapp:htop"));
    try std.testing.expect(!htop.matches("Alacritty"));
    try std.testing.expect(!htop.matches("alacritty"));
    try std.testing.expect(!htop.matches("org.alacritty.Alacritty")); // still only the forced one

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

test "WMState round trip: Dock, Clip, workspaces, state; attached tiles are not saved" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const apps = [_]DockApp{
        .{ .name = "clock", .command = &.{ "wl-clock", "--name", "clock" }, .y = 0, .autolaunch = true },
        .{ .name = "term", .command = &.{ "foot", "-e", "htop x" }, .y = 1, .locked = true },
        .{ .name = "temp", .command = &.{}, .y = 2, .attached = true },
        .{ .name = "notes", .command = &.{"notes"}, .place = .clip, .workspace = 1 },
        .{ .name = "all", .command = &.{"files"}, .place = .clip },
    };
    const names = [_][]const u8{ "Main", "Mail" };
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const skipped = try render(&aw.writer, .{ .apps = &apps, .workspace_names = &names }, .{ .edge = .left, .clip_collapsed = true, .dock_on_top = true });
    try std.testing.expectEqual(@as(usize, 0), skipped);

    const list = try parseWMStateAll(a, aw.written());
    try std.testing.expectEqual(@as(usize, 4), list.apps.len);
    try std.testing.expectEqualStrings("clock", list.apps[0].name);
    try std.testing.expect(list.apps[0].autolaunch);
    try std.testing.expectEqual(@as(usize, 3), list.apps[1].command.len);
    try std.testing.expectEqualStrings("htop x", list.apps[1].command[2]);
    try std.testing.expect(list.apps[1].locked);
    // Top-level Clip (all workspaces) comes before the per-workspace ones.
    try std.testing.expectEqual(@as(?u32, null), list.apps[2].workspace);
    try std.testing.expectEqual(@as(?u32, 1), list.apps[3].workspace);
    try std.testing.expectEqual(@as(usize, 2), list.workspace_names.len);
    try std.testing.expectEqual(config.DockEdge.left, list.state.?.edge.?);
    try std.testing.expectEqual(@as(?bool, true), list.state.?.clip_collapsed);
    try std.testing.expectEqual(@as(?bool, true), list.state.?.dock_on_top);
}

test "WMState: an empty saved Dock is still a saved state" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    _ = try render(&aw.writer, .{}, .{});
    const list = try parseWMStateAll(arena.allocator(), aw.written());
    try std.testing.expectEqual(@as(usize, 0), list.apps.len);
    try std.testing.expect(list.state != null);
}

test "render skips what it cannot write faithfully, and says so" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const apps = [_]DockApp{
        .{ .name = "bad", .command = &.{ "x", "a\"b" } },
        .{ .name = "empty", .command = &.{} },
        .{ .name = "ok", .command = &.{"ok"}, .y = 1 },
    };
    try std.testing.expectEqual(@as(usize, 2), try render(&aw.writer, .{ .apps = &apps }, .{}));
}

test "parse WMState: absurd grid positions are ignored, not trusted" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const list = try parseWMStateAll(arena.allocator(),
        \\{ Dock = { Applications = (
        \\  { Command = a; Name = a; Position = "0,2000000000"; },
        \\  { Command = b; Name = b; Position = "0,3"; }
        \\); }; Drawers = ( { Name = d; WMakerWLRow = "-2000000000"; } ); }
    );
    try std.testing.expectEqual(@as(usize, 2), list.apps.len);
    try std.testing.expectEqual(@as(i32, 0), list.apps[0].y); // unplaced: the model picks a row
    try std.testing.expectEqual(@as(i32, 3), list.apps[1].y);
    try std.testing.expectEqual(@as(usize, 1), list.drawers.len);
    try std.testing.expectEqual(@as(i32, 1), list.drawers[0].row); // the default
}
