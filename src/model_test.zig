// SPDX-License-Identifier: 0BSD
//
// Tests for the data model. They run without a compositor: workspace.zig
// never sends Wayland requests, so the river object pointers inside Window
// can be dummies that are never dereferenced.
//
// After every operation `check()` verifies the invariants documented at
// the top of types.zig. The old code base failed exactly here: an empty
// column left behind by "float", a dangling saved pointer, a link removed
// twice.

const std = @import("std");
const wayland = @import("wayland");
const river = wayland.client.river;

const types = @import("types.zig");
const workspace = @import("workspace.zig");
const layout = @import("layout.zig");
const config = @import("config.zig");
const action_mod = @import("action.zig");
const dockhost = @import("dockhost.zig");
const dock_mod = @import("dock.zig");

const Window = types.Window;
const Workspace = types.Workspace;
const Output = types.Output;
const WindowManager = types.WindowManager;

var dummy_byte: u8 = 0;

const Fixture = struct {
    wm: WindowManager,
    out: *Output,
    wins: [8]*Window = undefined,
    used: usize = 0,

    fn init() !*Fixture {
        const a = std.testing.allocator;
        const f = try a.create(Fixture);
        f.* = .{
            .wm = .{
                .gpa = a,
                .io = undefined,
                .cfg = .{ .arena = .init(a) },
                .obj = @ptrCast(&dummy_byte),
                .obj_version = 6,
                .outputs = undefined,
                .windows = undefined,
                .dock_windows = undefined,
                .seats = undefined,
            },
            .out = undefined,
        };
        f.wm.outputs.init();
        f.wm.windows.init();
        f.wm.dock_windows.init();
        f.wm.seats.init();

        const out = try a.create(Output);
        out.* = .{ .obj = @ptrCast(&dummy_byte) };
        out.rect = .{ .x = 0, .y = 0, .w = 1920, .h = 1080 };
        out.workspace_count = 2;
        for (0..2) |i| out.workspaces[i].init(out, @intCast(i));
        f.wm.outputs.append(out);
        f.out = out;
        return f;
    }

    fn deinit(f: *Fixture) void {
        const a = std.testing.allocator;
        // Free columns still alive.
        for (0..f.out.workspace_count) |i| {
            const ws = &f.out.workspaces[i];
            while (ws.strip.columns.first()) |c| {
                while (c.windows.first()) |w| types.unlink(&w.column_link);
                types.unlink(&c.link);
                a.destroy(c);
            }
        }
        for (f.wins[0..f.used]) |w| {
            types.unlink(&w.link);
            a.destroy(w);
        }
        a.destroy(f.out);
        f.wm.cfg.deinit();
        a.destroy(f);
    }

    fn newWindow(f: *Fixture) !*Window {
        const w = try std.testing.allocator.create(Window);
        w.* = .{ .obj = @ptrCast(&dummy_byte), .node = @ptrCast(&dummy_byte) };
        w.ready = true;
        w.target = .{ .x = 100, .y = 100, .w = 800, .h = 600 };
        f.wm.windows.append(w); // like window.create(): placeNew() walks this list
        f.wins[f.used] = w;
        f.used += 1;
        return w;
    }

    fn cur(f: *Fixture) *Workspace {
        return f.out.ws();
    }
};

/// Every window is in exactly one container; no column is empty; every
/// link is consistent.
fn check(f: *Fixture) !void {
    for (0..f.out.workspace_count) |i| {
        const ws = &f.out.workspaces[i];
        var tiled_seen: usize = 0;

        var cit = ws.strip.columns.first();
        while (cit) |col| : (cit = types.nextCol(col)) {
            // I4
            try std.testing.expect(!col.windows.empty());
            try std.testing.expect(col.strip == &ws.strip);
            var wit = col.windows.first();
            while (wit) |w| : (wit = types.nextWin(w)) {
                tiled_seen += 1;
                try std.testing.expect(w.column == col);
                try std.testing.expect(w.workspace == ws);
                try std.testing.expect(w.mode == .tiled or (w.mode == .fullscreen and w.restore == .tiled));
                try std.testing.expect(!types.isLinked(&w.floating_link));
            }
        }
        // strip.active is null or a member.
        if (ws.strip.active) |a| {
            var found = false;
            var c2 = ws.strip.columns.first();
            while (c2) |c| : (c2 = types.nextCol(c)) if (c == a) {
                found = true;
            };
            try std.testing.expect(found);
        }

        var fit = ws.floating.first();
        while (fit) |w| : (fit = types.nextFloating(w)) {
            try std.testing.expect(w.workspace == ws);
            try std.testing.expect(w.column == null);
            try std.testing.expect(!types.isLinked(&w.column_link));
            try std.testing.expect(w.mode == .floating or (w.mode == .fullscreen and w.restore == .floating));
        }
    }

    // I1: every window is in exactly the list its role says. A DockApp is
    // in no workspace and no strip: nothing that loops over the windows can
    // reach it.
    var nit = f.wm.windows.first();
    while (nit) |w| : (nit = types.nextWindow(w, &f.wm)) {
        try std.testing.expect(w.role == .normal);
    }
    var dit = f.wm.dock_windows.first();
    while (dit) |w| : (dit = types.nextDockWindow(w, &f.wm)) {
        try std.testing.expect(w.role == .dockapp);
        try std.testing.expect(w.workspace == null and w.column == null);
        try std.testing.expect(!types.isLinked(&w.column_link) and !types.isLinked(&w.floating_link));
    }
}

test "placing windows creates one column each, active is the newest" {
    const f = try Fixture.init();
    defer f.deinit();

    const a = try f.newWindow();
    const b = try f.newWindow();
    const c = try f.newWindow();
    try workspace.placeTiled(&f.wm, f.cur(), a);
    try workspace.placeTiled(&f.wm, f.cur(), b);
    try workspace.placeTiled(&f.wm, f.cur(), c);
    try check(f);

    try std.testing.expectEqual(@as(usize, 3), f.cur().strip.columnCount());
    try std.testing.expect(f.cur().strip.activeWindow() == c);
}

test "floating the only window of a column removes the column" {
    const f = try Fixture.init();
    defer f.deinit();

    const a = try f.newWindow();
    const b = try f.newWindow();
    const c = try f.newWindow();
    try workspace.placeTiled(&f.wm, f.cur(), a);
    try workspace.placeTiled(&f.wm, f.cur(), b);
    try workspace.placeTiled(&f.wm, f.cur(), c);

    workspace.floatWindow(&f.wm, b);
    try check(f);

    // The report's bug: an empty column 1 stayed in the strip.
    try std.testing.expectEqual(@as(usize, 2), f.cur().strip.columnCount());
    try std.testing.expect(b.mode == .floating);
    try std.testing.expect(b.column == null);
}

test "float then tile returns to the same position and width" {
    const f = try Fixture.init();
    defer f.deinit();

    const a = try f.newWindow();
    const b = try f.newWindow();
    const c = try f.newWindow();
    try workspace.placeTiled(&f.wm, f.cur(), a);
    try workspace.placeTiled(&f.wm, f.cur(), b);
    try workspace.placeTiled(&f.wm, f.cur(), c);
    f.cur().strip.active.?.width = 700; // c's column
    const col_b = b.column.?;
    col_b.width = 555;

    workspace.floatWindow(&f.wm, b);
    workspace.tileWindow(&f.wm, b);
    try check(f);

    try std.testing.expect(b.mode == .tiled);
    try std.testing.expectEqual(@as(usize, 3), f.cur().strip.columnCount());
    // Back in the middle (index 1) with its old width.
    try std.testing.expectEqual(@as(usize, 1), workspace.columnIndex(&f.cur().strip, b.column.?));
    try std.testing.expectEqual(@as(i32, 555), b.column.?.width);
}

test "closing every window leaves an empty workspace" {
    const f = try Fixture.init();
    defer f.deinit();

    const a = try f.newWindow();
    const b = try f.newWindow();
    try workspace.placeTiled(&f.wm, f.cur(), a);
    try workspace.placeTiled(&f.wm, f.cur(), b);
    workspace.floatWindow(&f.wm, b);

    workspace.unplace(&f.wm, a);
    workspace.unplace(&f.wm, b);
    try check(f);
    try std.testing.expect(f.cur().isEmpty());
    try std.testing.expect(f.cur().strip.active == null);
}

test "unplace on an unplaced window is a no-op" {
    const f = try Fixture.init();
    defer f.deinit();
    const a = try f.newWindow();
    workspace.unplace(&f.wm, a);
    workspace.unplace(&f.wm, a);
    try check(f);
}

test "fullscreen keeps membership and restores" {
    const f = try Fixture.init();
    defer f.deinit();

    const a = try f.newWindow();
    const b = try f.newWindow();
    try workspace.placeTiled(&f.wm, f.cur(), a);
    try workspace.placeTiled(&f.wm, f.cur(), b);

    workspace.setFullscreen(&f.wm, b);
    try check(f);
    try std.testing.expect(f.cur().fullscreen == b);
    try std.testing.expectEqual(@as(usize, 2), f.cur().strip.columnCount());

    // A second fullscreen window takes over; the first returns.
    workspace.setFullscreen(&f.wm, a);
    try check(f);
    try std.testing.expect(f.cur().fullscreen == a);
    try std.testing.expect(b.mode == .tiled);

    workspace.leaveFullscreen(a);
    try check(f);
    try std.testing.expect(f.cur().fullscreen == null);
    try std.testing.expect(a.mode == .tiled);
}

test "closing a fullscreen window clears the workspace pointer" {
    const f = try Fixture.init();
    defer f.deinit();
    const a = try f.newWindow();
    try workspace.placeTiled(&f.wm, f.cur(), a);
    workspace.setFullscreen(&f.wm, a);
    workspace.unplace(&f.wm, a);
    try check(f);
    try std.testing.expect(f.cur().fullscreen == null);
}

test "move to another workspace keeps floating windows floating" {
    const f = try Fixture.init();
    defer f.deinit();

    const a = try f.newWindow();
    const b = try f.newWindow();
    try workspace.placeTiled(&f.wm, f.cur(), a);
    try workspace.placeTiled(&f.wm, f.cur(), b);
    workspace.floatWindow(&f.wm, b);
    b.float_rect = .{ .x = 10, .y = 20, .w = 300, .h = 200 };

    const dest = &f.out.workspaces[1];
    try workspace.moveToWorkspace(&f.wm, a, dest);
    try workspace.moveToWorkspace(&f.wm, b, dest);
    try check(f);

    try std.testing.expect(a.workspace == dest and a.mode == .tiled);
    try std.testing.expect(b.workspace == dest and b.mode == .floating);
    try std.testing.expectEqual(@as(i32, 300), b.float_rect.w);
    try std.testing.expect(f.cur().isEmpty());
}

test "moving columns keeps the strip consistent" {
    const f = try Fixture.init();
    defer f.deinit();

    const a = try f.newWindow();
    const b = try f.newWindow();
    const c = try f.newWindow();
    try workspace.placeTiled(&f.wm, f.cur(), a);
    try workspace.placeTiled(&f.wm, f.cur(), b);
    try workspace.placeTiled(&f.wm, f.cur(), c);
    const strip = &f.cur().strip;

    try std.testing.expect(workspace.moveColumn(strip, .first)); // c to the front
    try check(f);
    try std.testing.expect(strip.columns.first().? == c.column.?);

    try std.testing.expect(workspace.moveColumn(strip, .last));
    try check(f);
    try std.testing.expect(strip.columns.last().? == c.column.?);

    // Already last: nothing to do.
    try std.testing.expect(!workspace.moveColumn(strip, .last));
    try check(f);
}

test "consume and expel round trip" {
    const f = try Fixture.init();
    defer f.deinit();

    const a = try f.newWindow();
    const b = try f.newWindow();
    try workspace.placeTiled(&f.wm, f.cur(), a);
    try workspace.placeTiled(&f.wm, f.cur(), b);
    const strip = &f.cur().strip;

    try std.testing.expect(workspace.consumeLeft(&f.wm, strip));
    try check(f);
    try std.testing.expectEqual(@as(usize, 1), strip.columnCount());
    try std.testing.expectEqual(@as(usize, 2), strip.active.?.count());

    try std.testing.expect(workspace.expelRight(&f.wm, strip));
    try check(f);
    try std.testing.expectEqual(@as(usize, 2), strip.columnCount());
}

test "layout fills the work area and never scrolls beyond the strip" {
    const f = try Fixture.init();
    defer f.deinit();

    var i: usize = 0;
    while (i < 5) : (i += 1) {
        const w = try f.newWindow();
        try workspace.placeTiled(&f.wm, f.cur(), w);
    }

    // Force a large scroll and let layout clamp it.
    f.cur().strip.scroll_x = 99999;
    layout.compute(f.cur(), &f.wm.cfg, false);
    const cw = layout.assignColumnX(&f.cur().strip, &f.wm.cfg);
    try std.testing.expect(f.cur().strip.scroll_x <= cw - 1920);
    try std.testing.expect(f.cur().strip.scroll_x >= 0);

    // Following the first column scrolls back to 0.
    f.cur().strip.active = f.cur().strip.columns.first();
    layout.compute(f.cur(), &f.wm.cfg, true);
    try std.testing.expectEqual(@as(i32, 0), f.cur().strip.scroll_x);
}

test "stacked windows fill the column height exactly" {
    const f = try Fixture.init();
    defer f.deinit();

    const a = try f.newWindow();
    const b = try f.newWindow();
    const c = try f.newWindow();
    try workspace.placeTiled(&f.wm, f.cur(), a);
    try workspace.placeTiled(&f.wm, f.cur(), b);
    try workspace.placeTiled(&f.wm, f.cur(), c);
    const strip = &f.cur().strip;
    _ = workspace.consumeLeft(&f.wm, strip);
    _ = workspace.consumeLeft(&f.wm, strip);
    try check(f);

    layout.compute(f.cur(), &f.wm.cfg, true);
    const bw = f.wm.cfg.border_width;
    const col = strip.active.?;
    const first = col.windows.first().?;
    const last = col.windows.last().?;
    const top = first.target.y - bw;
    const bottom = last.target.y + last.target.h + bw;
    // Column spans from outer_gap to (height - outer_gap).
    try std.testing.expectEqual(f.wm.cfg.outer_gap, top);
    try std.testing.expectEqual(@as(i32, 1080) - f.wm.cfg.outer_gap, bottom);
}

test "every default key binding parses to a real command" {
    var cfg = try config.load(std.testing.io, std.testing.allocator);
    defer cfg.deinit();

    // Reaching here means default_config.lua parsed; now every bind's
    // command text must map to a Command and every key to a keysym.
    try std.testing.expect(cfg.binds.len > 40);

    const action = @import("action.zig");
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var bad: usize = 0;
    for (cfg.binds) |b| {
        const cmd = action.parse(arena.allocator(), &cfg, b.command) catch {
            std.debug.print("bad default command: `{s}`\n", .{b.command});
            bad += 1;
            continue;
        };
        if (cmd == .none) bad += 1;
        try std.testing.expect(b.keysym != 0);
    }
    try std.testing.expectEqual(@as(usize, 0), bad);
}

test "toggle_mini_dock is a command, and the shipped config binds it" {
    var cfg = try config.load(std.testing.io, std.testing.allocator);
    defer cfg.deinit();

    const action = @import("action.zig");
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expect((try action.parse(arena.allocator(), &cfg, "toggle_mini_dock")) == .toggle_mini_dock);
    try std.testing.expect(cfg.mini_dock);
    var bound = false;
    for (cfg.binds) |b| {
        if (std.mem.eql(u8, b.command, "toggle_mini_dock")) bound = true;
    }
    try std.testing.expect(bound);
}

test "shell command keeps shell syntax verbatim, unlike spawn" {
    var cfg = try config.load(std.testing.io, std.testing.allocator);
    defer cfg.deinit();

    const action = @import("action.zig");
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `shell`/`exec`/`shexec` are aliases and pass the rest of the line
    // through untouched -- pipes, &&, ~, $VAR, quotes and all -- because
    // /bin/sh does the parsing, not wmaker-wl.
    const raw = "notify-send \"$(date)\" && pkill -RTMIN+8 waybar";
    for ([_][]const u8{ "shell", "exec", "shexec" }) |kw| {
        const line = try std.fmt.allocPrint(a, "{s} {s}", .{ kw, raw });
        const cmd = try action.parse(a, &cfg, line);
        try std.testing.expect(cmd == .shell);
        try std.testing.expectEqualStrings(raw, cmd.shell);
    }

    // A bare `shell` with no command text is a config error, not a no-op
    // that silently does nothing when the key is pressed.
    try std.testing.expectError(error.BadArguments, action.parse(a, &cfg, "shell"));
    try std.testing.expectError(error.BadArguments, action.parse(a, &cfg, "shell   "));

    // `spawn` stays word-split (no shell): "&&" would just be an argv
    // token here, not a shell operator.
    const spawned = try action.parse(a, &cfg, "spawn notify-send hello && world");
    try std.testing.expect(spawned == .spawn);
    try std.testing.expectEqual(@as(usize, 4), spawned.spawn.len);
    try std.testing.expectEqualStrings("&&", spawned.spawn[2]);
}

test "no two default bindings share a key combination" {
    var cfg = try config.load(std.testing.io, std.testing.allocator);
    defer cfg.deinit();
    for (cfg.binds, 0..) |a, i| {
        for (cfg.binds[i + 1 ..]) |b| {
            const same = a.keysym == b.keysym and config.modsBits(a.mods) == config.modsBits(b.mods);
            if (same) std.debug.print("duplicate: {s} / {s}\n", .{ a.command, b.command });
            try std.testing.expect(!same);
        }
    }
}

test "focus only lands on windows of the shown workspace" {
    const f = try Fixture.init();
    defer f.deinit();

    const a = try f.newWindow();
    const b = try f.newWindow();
    try workspace.placeTiled(&f.wm, f.cur(), a);
    const dest = &f.out.workspaces[1];
    try workspace.placeTiled(&f.wm, dest, b);

    // Workspace 0 is shown: b (on workspace 1) must not be focusable.
    try std.testing.expect(f.out.active == 0);
    try std.testing.expect(@import("main.zig").focusable(a));
    try std.testing.expect(!@import("main.zig").focusable(b));

    f.out.active = 1;
    try std.testing.expect(@import("main.zig").focusable(b));
    try std.testing.expect(!@import("main.zig").focusable(a));
}

// Regression: river shows a new window only after we sent propose_dimensions,
// and only then sends the first `dimensions` event. A window that has NOT had
// that event yet (ready == false) must therefore be placed, laid out and get
// a proposal, otherwise nothing ever opens.
test "a window without a dimensions event yet is still placed and laid out" {
    const f = try Fixture.init();
    defer f.deinit();

    const w = try f.newWindow();
    w.ready = false; // exactly the state of a freshly announced window
    w.target = .{};

    const window_mod = @import("window.zig");
    window_mod.placeNew(&f.wm);
    try check(f);

    try std.testing.expect(w.workspace != null);
    try std.testing.expect(w.mode == .tiled);
    try std.testing.expect(!w.new);

    layout.compute(f.cur(), &f.wm.cfg, true);
    try std.testing.expect(w.target.w > 100);
    try std.testing.expect(w.target.h > 100);
    // and it may take focus
    try std.testing.expect(@import("main.zig").focusable(w));
}

test "maximize_column fills the work area and pushes the others aside" {
    const f = try Fixture.init();
    defer f.deinit();

    const a = try f.newWindow();
    const b = try f.newWindow();
    const c = try f.newWindow();
    try workspace.placeTiled(&f.wm, f.cur(), a);
    try workspace.placeTiled(&f.wm, f.cur(), b);
    try workspace.placeTiled(&f.wm, f.cur(), c);

    // Focus the middle window, then run the real action.
    workspace.activate(b);
    var seat: types.Seat = .{ .obj = undefined, .xkb_bindings = undefined, .pointer_bindings = undefined };
    seat.focused = b;
    f.wm.seats.init();
    f.wm.seats.append(&seat);
    defer types.unlink(&seat.link);

    const action = @import("action.zig");
    action.run(&f.wm, .maximize_column);
    layout.compute(f.cur(), &f.wm.cfg, f.wm.follow_request);
    try check(f);

    const cfg = &f.wm.cfg;
    const bw = cfg.border_width;
    // b fills the width and height inside the outer gap, borders included.
    try std.testing.expectEqual(cfg.outer_gap + bw, b.target.x);
    try std.testing.expectEqual(@as(i32, 1920) - 2 * cfg.outer_gap - 2 * bw, b.target.w);
    try std.testing.expectEqual(cfg.outer_gap + bw, b.target.y);
    try std.testing.expectEqual(@as(i32, 1080) - 2 * cfg.outer_gap - 2 * bw, b.target.h);
    // a is pushed off to the left, c off to the right: nothing overlaps b.
    try std.testing.expect(a.target.x + a.target.w <= 0);
    try std.testing.expect(c.target.x >= 1920);

    // Pressing it again restores the previous width.
    const before = b.column.?.unmaximized_width;
    try std.testing.expect(before > 0);
    action.run(&f.wm, .maximize_column);
    try std.testing.expectEqual(before, b.column.?.width);
    try std.testing.expectEqual(@as(i32, 0), b.column.?.unmaximized_width);
}

test "maximize_column ignores a floating window" {
    const f = try Fixture.init();
    defer f.deinit();

    const a = try f.newWindow();
    const b = try f.newWindow();
    try workspace.placeTiled(&f.wm, f.cur(), a);
    try workspace.placeTiled(&f.wm, f.cur(), b);
    workspace.floatWindow(&f.wm, b);
    const width_a = a.column.?.width;

    var seat: types.Seat = .{ .obj = undefined, .xkb_bindings = undefined, .pointer_bindings = undefined };
    seat.focused = b;
    f.wm.seats.init();
    f.wm.seats.append(&seat);
    defer types.unlink(&seat.link);

    @import("action.zig").run(&f.wm, .maximize_column);
    // The tiled column of `a` must be untouched.
    try std.testing.expectEqual(width_a, a.column.?.width);
    try std.testing.expectEqual(@as(i32, 0), a.column.?.unmaximized_width);
}

// ----------------------------------------------------------------------------
// Window Maker attributes: they must change what placeNew() and layout do.
// ----------------------------------------------------------------------------

const wm_attr = @import("wm_attr.zig");
const dockapp_mod = @import("dockapp.zig");

/// Fixture window with an app_id and rules parsed from `rules`.
fn attrWindow(f: *Fixture, arena: std.mem.Allocator, app_id: []const u8, rules: []const u8) !*Window {
    f.wm.attrs = (try wm_attr.parse(arena, rules)).table;
    const w = try f.newWindow();
    w.app_id = try std.testing.allocator.dupe(u8, app_id);
    w.new = true;
    return w;
}

test "StartWorkspace puts the window on that workspace" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const f = try Fixture.init();
    defer f.deinit();

    const w = try attrWindow(f, arena.allocator(), "foot", "{ foot = { StartWorkspace = 2; }; }");
    defer std.testing.allocator.free(w.app_id.?);
    @import("window.zig").placeNew(&f.wm);
    try check(f);

    try std.testing.expect(w.workspace == &f.out.workspaces[1]);
    try std.testing.expect(w.mode == .tiled);
    // It was opened elsewhere: the visible workspace keeps its focus.
    try std.testing.expect(f.wm.focus_request == null);
}

test "StartWorkspace beyond the last workspace falls back to the current one" {
    // The code warns about this on purpose; keep the test output clean.
    const saved = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = saved;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const f = try Fixture.init();
    defer f.deinit();

    const w = try attrWindow(f, arena.allocator(), "foot", "{ foot = { StartWorkspace = 9; }; }");
    defer std.testing.allocator.free(w.app_id.?);
    @import("window.zig").placeNew(&f.wm);
    try check(f);
    try std.testing.expect(w.workspace == f.out.ws());
}

test "Omnipresent windows float and follow the user across workspaces" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const f = try Fixture.init();
    defer f.deinit();

    const w = try attrWindow(f, arena.allocator(), "clock", "{ clock = { Omnipresent = Yes; }; }");
    defer std.testing.allocator.free(w.app_id.?);
    @import("window.zig").placeNew(&f.wm);
    try check(f);
    try std.testing.expect(w.mode == .floating);
    try std.testing.expect(w.isOmnipresent());
    try std.testing.expect(w.workspace == &f.out.workspaces[0]);

    const action = @import("action.zig");
    action.run(&f.wm, .{ .workspace = 1 });
    try check(f);
    try std.testing.expect(w.workspace == &f.out.workspaces[1]);
    try std.testing.expect(w.mode == .floating);
    try std.testing.expect(f.out.workspaces[0].isEmpty());

    action.run(&f.wm, .{ .workspace = 0 });
    try check(f);
    try std.testing.expect(w.workspace == &f.out.workspaces[0]);
}

test "an ordinary window does not follow" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const f = try Fixture.init();
    defer f.deinit();

    const w = try attrWindow(f, arena.allocator(), "foot", "{ clock = { Omnipresent = Yes; }; }");
    defer std.testing.allocator.free(w.app_id.?);
    @import("window.zig").placeNew(&f.wm);
    @import("action.zig").run(&f.wm, .{ .workspace = 1 });
    try std.testing.expect(w.workspace == &f.out.workspaces[0]);
}

test "a tiled window is never treated as omnipresent" {
    const f = try Fixture.init();
    defer f.deinit();
    const w = try f.newWindow();
    try workspace.placeTiled(&f.wm, f.cur(), w);
    w.sticky = true;
    try std.testing.expect(!w.isOmnipresent());
}

test "NoBorder removes the border from the slot" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const f = try Fixture.init();
    defer f.deinit();

    const bare = try attrWindow(f, arena.allocator(), "bare", "{ bare = { NoBorder = Yes; }; }");
    defer std.testing.allocator.free(bare.app_id.?);
    const normal = try f.newWindow();
    normal.app_id = try std.testing.allocator.dupe(u8, "normal");
    defer std.testing.allocator.free(normal.app_id.?);
    normal.new = true;
    @import("window.zig").placeNew(&f.wm);
    try check(f);
    layout.compute(f.cur(), &f.wm.cfg, true);

    const cfg = &f.wm.cfg;
    try std.testing.expectEqual(@as(i32, 0), bare.borderWidth(cfg));
    try std.testing.expectEqual(cfg.border_width, normal.borderWidth(cfg));
    // Same column width: the window without border gets 2 * border more content.
    try std.testing.expectEqual(bare.column.?.width, bare.target.w);
    try std.testing.expectEqual(normal.column.?.width - 2 * cfg.border_width, normal.target.w);
    // and sits flush at the slot's edge
    try std.testing.expectEqual(cfg.outer_gap, bare.target.y);
}

test "StartMaximized opens a full-width column" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const f = try Fixture.init();
    defer f.deinit();

    const w = try attrWindow(f, arena.allocator(), "editor", "{ editor = { StartMaximized = Yes; }; }");
    defer std.testing.allocator.free(w.app_id.?);
    @import("window.zig").placeNew(&f.wm);
    try check(f);
    try std.testing.expectEqual(layout.columnWidthFor(1920, 1.0, &f.wm.cfg), w.column.?.width);
    // and it toggles back like Super+d does
    workspace.toggleMaximized(&f.wm, w.column.?);
    try std.testing.expect(w.column.?.width < layout.columnWidthFor(1920, 1.0, &f.wm.cfg));
}

test "KeepOnTop floats; the Floating attribute overrides it" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const f = try Fixture.init();
    defer f.deinit();

    const a = try attrWindow(f, arena.allocator(), "top", "{ top = { KeepOnTop = Yes; }; pinned = { KeepOnTop = Yes; Floating = No; }; }");
    defer std.testing.allocator.free(a.app_id.?);
    const b = try f.newWindow();
    b.app_id = try std.testing.allocator.dupe(u8, "pinned");
    defer std.testing.allocator.free(b.app_id.?);
    b.new = true;
    @import("window.zig").placeNew(&f.wm);
    try check(f);
    try std.testing.expect(a.mode == .floating);
    try std.testing.expect(b.mode == .tiled);
}

test "Unfocusable windows never take keyboard focus" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const f = try Fixture.init();
    defer f.deinit();

    const w = try attrWindow(f, arena.allocator(), "panel", "{ panel = { Unfocusable = Yes; }; }");
    defer std.testing.allocator.free(w.app_id.?);
    @import("window.zig").placeNew(&f.wm);
    try check(f);
    try std.testing.expect(!@import("main.zig").focusable(w));
    try std.testing.expect(f.wm.focus_request == null);
}

test "windows without rules behave exactly as before" {
    const f = try Fixture.init();
    defer f.deinit();
    const w = try f.newWindow();
    w.new = true;
    @import("window.zig").placeNew(&f.wm);
    try check(f);
    try std.testing.expect(w.mode == .tiled);
    try std.testing.expect(w.workspace == f.out.ws());
    try std.testing.expect(!w.sticky);
    try std.testing.expect(@import("main.zig").focusable(w));
    try std.testing.expect(f.wm.focus_request == w);
}

// ----------------------------------------------------------------------------
// Late-arriving app_id/size/parent: docs/TODO.md's "Attribute mit später
// eintreffender app_id". A DockApp (or any window) whose defining state
// shows up only after it was already tiled must not be stuck that way.
// ----------------------------------------------------------------------------

test "adopt: a DockApp tag arriving after tiling takes the window out of the strip and the window list" {
    const f = try Fixture.init();
    defer f.deinit();
    const other = try f.newWindow();
    const w = try f.newWindow();
    try workspace.placeTiled(&f.wm, f.cur(), other);
    try workspace.placeTiled(&f.wm, f.cur(), w);
    w.new = false;
    try check(f);
    try std.testing.expect(w.mode == .tiled);

    dockhost.adopt(&f.wm, w);
    try std.testing.expect(w.role == .dockapp);
    try std.testing.expect(w.workspace == null and w.column == null);
    try check(f);

    // Out of the window list, in the DockApp list: nothing that loops over
    // the windows can reach it any more.
    var seen_normal = false;
    var it = f.wm.windows.first();
    while (it) |x| : (it = types.nextWindow(x, &f.wm)) {
        if (x == w) seen_normal = true;
    }
    try std.testing.expect(!seen_normal);
    try std.testing.expect(f.wm.dock_windows.first().? == w);
    try std.testing.expect(types.nextDockWindow(w, &f.wm) == null);

    // Adopting twice changes nothing.
    dockhost.adopt(&f.wm, w);
    try std.testing.expect(f.wm.dock_windows.first().? == w);
    // The other window is untouched.
    try std.testing.expect(other.mode == .tiled and other.workspace != null);
}
test "recheckFloating: a fixed-size hint arriving after tiling floats it too" {
    const f = try Fixture.init();
    defer f.deinit();
    const w = try f.newWindow();
    try workspace.placeTiled(&f.wm, f.cur(), w);
    w.new = false; // see the comment in the DockApp test above
    try check(f);

    // Same shape a DockApp's set_min_size/set_max_size produces, just
    // reported late (dimensions_hint after the first manage_start).
    w.min_w = 64;
    w.min_h = 64;
    w.max_w = 64;
    w.max_h = 64;
    @import("window.zig").recheckFloating(&f.wm, w);
    try check(f);

    try std.testing.expect(w.mode == .floating);
}

test "recheckFloating: Omnipresent arriving late also sets sticky" {
    const f = try Fixture.init();
    defer f.deinit();
    const w = try f.newWindow();
    try workspace.placeTiled(&f.wm, f.cur(), w);
    w.new = false; // see the comment in the DockApp test above

    w.attrs = .{ .omnipresent = true };
    @import("window.zig").recheckFloating(&f.wm, w);
    try check(f);

    try std.testing.expect(w.mode == .floating);
    try std.testing.expect(w.isOmnipresent());
}

test "recheckFloating: does nothing for an ordinary window" {
    const f = try Fixture.init();
    defer f.deinit();
    const w = try f.newWindow();
    try workspace.placeTiled(&f.wm, f.cur(), w);

    @import("window.zig").recheckFloating(&f.wm, w);
    try check(f);
    try std.testing.expect(w.mode == .tiled);
}

test "recheckFloating: a no-longer-new but already-floating window is untouched" {
    const f = try Fixture.init();
    defer f.deinit();
    const w = try f.newWindow();
    workspace.placeFloating(f.cur(), w);
    w.new = false;

    // Should stay floating and not, say, get pulled into a column.
    w.attrs = .{ .floating = true, .omnipresent = true };
    @import("window.zig").recheckFloating(&f.wm, w);
    try check(f);
    try std.testing.expect(w.mode == .floating);
}

test "recheckFloating: a window still in its initial placement (new) is left for placeNew" {
    const f = try Fixture.init();
    defer f.deinit();
    const w = try f.newWindow();
    w.new = true; // never placed yet -- placeNew(), not recheckFloating, owns this one

    w.attrs = .{ .floating = true, .omnipresent = true };
    @import("window.zig").recheckFloating(&f.wm, w);

    try std.testing.expect(w.workspace == null);
    try std.testing.expect(w.mode == .tiled); // untouched Window{} default, not yet placed
}

// ----------------------------------------------------------------------------
// wlprefs and the compositor must agree. wlprefs writes config.lua lines (a
// Lua dialect, see wlprefs/src/lualine.zig); the compositor runs them. Every key wlprefs knows is written with a value that
// differs from the default, and read back by config.zig.
// ----------------------------------------------------------------------------

const prefs_settings = @import("wlprefs_settings");

fn parseWithCompositor(gpa: std.mem.Allocator, text: []const u8) !config.Config {
    var cfg: config.Config = .{ .arena = .init(gpa) };
    errdefer cfg.deinit();
    var binds: std.ArrayList(config.Bind) = .empty;
    try config.parse(cfg.arena.allocator(), text, &cfg, &binds, "<wlprefs>");
    return cfg;
}

test "adopt drops the focus request and a pending menu focus for the window" {
    const f = try Fixture.init();
    defer f.deinit();
    const w = try f.newWindow();
    try workspace.placeTiled(&f.wm, f.cur(), w);
    w.new = false;
    f.wm.focus_request = w;
    f.wm.pending_ui = .{ .focus = w };
    dockhost.adopt(&f.wm, w);
    try std.testing.expect(f.wm.focus_request == null);
    try std.testing.expect(f.wm.pending_ui == null);
    try check(f);
}

test "syncModel: a DockApp gets a temporary tile while it runs and loses it with the program" {
    const f = try Fixture.init();
    defer f.deinit();
    const a = std.testing.allocator;
    const kept = [_]dockapp_mod.DockApp{.{ .name = "clock", .command = &.{"wl-clock"}, .y = 1 }};
    var m = try dock_mod.Model.init(a, .{ .apps = &kept }, &.{}, 1);
    defer m.deinit();

    const clock = try f.newWindow();
    const tokyo = try f.newWindow();
    const term = try f.newWindow();
    clock.app_id = try a.dupe(u8, "dockapp:clock");
    tokyo.app_id = try a.dupe(u8, "dockapp:tokyo");
    term.app_id = try a.dupe(u8, "foot");
    defer for ([_]*Window{ clock, tokyo, term }) |w| a.free(w.app_id.?);
    dockhost.adopt(&f.wm, clock);
    dockhost.adopt(&f.wm, tokyo);
    try workspace.placeTiled(&f.wm, f.cur(), term);
    term.new = false;
    try check(f);

    // The kept tile of "clock" is its home and is marked running; "tokyo"
    // has no entry and gets a temporary tile; "foot" is a normal window and
    // gets none.
    try std.testing.expect(dockhost.syncModel(&f.wm, &m));
    try std.testing.expect(m.slots.items[0].running);
    const ti = m.dockSlotFor("dockapp:tokyo").?;
    try std.testing.expect(m.slots.items[ti].app.attached and m.slots.items[ti].running);
    try std.testing.expect(!m.hasApp("foot"));
    try std.testing.expect(dockhost.hostFor(&f.wm, &m.slots.items[0].app) == clock);
    try std.testing.expect(dockhost.hostFor(&f.wm, &m.slots.items[ti].app) == tokyo);
    // Nothing changed: nothing reported.
    try std.testing.expect(!dockhost.syncModel(&f.wm, &m));

    // The program ends: its temporary tile goes, the kept tile stays and is
    // not running any more.
    tokyo.closed = true;
    clock.closed = true;
    try std.testing.expect(dockhost.syncModel(&f.wm, &m));
    try std.testing.expect(m.dockSlotFor("dockapp:tokyo") == null);
    try std.testing.expect(m.slot(0) != null and !m.slots.items[0].running);
    try std.testing.expect(dockhost.hostFor(&f.wm, &m.slots.items[0].app) == null);
}

test "syncModel: every minimized window gets a Dock tile of its own, gone when it is restored" {
    const f = try Fixture.init();
    defer f.deinit();
    var m = try dock_mod.Model.init(std.testing.allocator, .{}, &.{}, 1);
    defer m.deinit();
    const a = try f.newWindow();
    const b = try f.newWindow();
    for ([_]*Window{ a, b }) |w| try workspace.placeTiled(&f.wm, f.cur(), w);

    // Nothing minimized: no tile.
    try std.testing.expect(!dockhost.syncModel(&f.wm, &m));
    try std.testing.expect(m.miniSlotFor(a.min_order) == null);

    workspace.minimize(&f.wm, a);
    try std.testing.expect(dockhost.syncModel(&f.wm, &m));
    try std.testing.expect(m.miniSlotFor(a.min_order) != null);
    try std.testing.expect(!dockhost.syncModel(&f.wm, &m)); // nothing new: no change

    workspace.minimize(&f.wm, b);
    try std.testing.expect(dockhost.syncModel(&f.wm, &m));
    try std.testing.expect(m.miniSlotFor(a.min_order) != null and m.miniSlotFor(b.min_order) != null);
    try std.testing.expect(m.miniSlotFor(a.min_order) != m.miniSlotFor(b.min_order));

    // `a` is restored: only its tile goes.
    const order_a = a.min_order;
    try workspace.restore(&f.wm, a, f.cur());
    try std.testing.expect(dockhost.syncModel(&f.wm, &m));
    try std.testing.expect(m.miniSlotFor(order_a) == null);
    try std.testing.expect(m.miniSlotFor(b.min_order) != null);

    // mini_dock = false: no tiles at all, and the existing one goes.
    f.wm.cfg.mini_dock = false;
    try std.testing.expect(dockhost.syncModel(&f.wm, &m));
    try std.testing.expect(m.miniSlotFor(b.min_order) == null);
    workspace.minimize(&f.wm, a);
    try std.testing.expect(!dockhost.syncModel(&f.wm, &m));
    try std.testing.expect(m.miniSlotFor(a.min_order) == null);
    try check(f);
}

test "wlprefs defaults are the compositor's defaults" {
    const gpa = std.testing.allocator;
    const d = prefs_settings.Settings.init();
    var cfg = try parseWithCompositor(gpa, prefs_settings.default_config_text);
    defer cfg.deinit();

    try std.testing.expectEqual(cfg.gap, d.gap);
    try std.testing.expectEqual(cfg.outer_gap, d.outer_gap);
    try std.testing.expectEqual(cfg.min_window_size, d.min_window_size);
    try std.testing.expectEqual(cfg.border_width, d.border_width);
    try std.testing.expectEqual(cfg.border_focused, d.border_focused);
    try std.testing.expectEqual(cfg.workspace_count, d.workspace_count);
    try std.testing.expectEqual(cfg.drag_threshold, d.drag_threshold);
    try std.testing.expectEqual(cfg.dock_enabled, d.dock_enabled);
    try std.testing.expectEqual(cfg.dock_on_top, d.dock_on_top);
    try std.testing.expectEqual(cfg.clip_enabled, d.clip_enabled);
    try std.testing.expectEqual(cfg.clip_collapsed, d.clip_collapsed);
    try std.testing.expectEqualStrings(cfg.terminal[0], d.terminal.get());
    try std.testing.expectEqualStrings(cfg.launcher[0], d.launcher.get());
    try std.testing.expectEqualStrings(cfg.browser[0], d.browser.get());
    try std.testing.expectEqual(@as(usize, cfg.width_presets.len), blk: {
        var n: usize = 0;
        var it = std.mem.tokenizeAny(u8, d.width_presets.get(), ", \t");
        while (it.next()) |_| n += 1;
        break :blk n;
    });
}

test "everything wlprefs writes is read back by the compositor with the same value" {
    const gpa = std.testing.allocator;
    const base = prefs_settings.Settings.init();

    // Every key different from the default.
    var s = base;
    s.gap = 13;
    s.outer_gap = 5;
    s.default_column_width = 0.4;
    s.width_presets.set("0.25, 0.5, 0.75");
    s.width_step = 0.05;
    s.min_window_size = 200;
    s.center_focused_column = .always;
    s.new_window = .stack;
    s.border_width = 4;
    s.border_focused = 0x112233;
    s.border_unfocused = 0x445566;
    s.border_floating = 0x778899;
    s.workspace_count = 7;
    s.workspace_names.set("Main, , Code");
    s.drag_threshold = 40;
    s.floating_size = 0.7;
    s.focus_follows_mouse = true;
    s.mouse_mod = .{ .super = true, .alt = true, .ctrl = false, .shift = true };
    s.terminal.set("foot -e \"htop -d 5\"");
    s.launcher.set("wofi --show drun");
    s.browser.set("/usr/bin/librewolf");
    s.enable_wmaker_compat = true;
    s.enable_autostart = false;
    s.enable_dockapps = false;
    s.dock_enabled = false;
    s.dock_edge = .left;
    s.dock_offset = 120;
    s.dock_size = 96;
    s.dock_on_top = false;
    s.dock_reserve_space = false;
    s.clip_enabled = false;
    s.clip_corner = .bottom_right;
    s.clip_on_top = false;
    s.clip_collapsed = true;
    s.bind_layout = 1;
    s.theme.set("nord");
    s.focus_new_windows = !base.focus_new_windows;
    s.workspace_wrap = !base.workspace_wrap;
    s.clip_scroll_workspaces = !base.clip_scroll_workspaces;
    s.dock_auto_raise = !base.dock_auto_raise;
    s.dock_single_click = !base.dock_single_click;
    s.dock_save_state = !base.dock_save_state;
    s.clip_auto_collapse = !base.clip_auto_collapse;
    s.clip_auto_raise = !base.clip_auto_raise;
    s.font_menu_title.set("Sans Bold 11");
    s.font_menu.set("Sans 11");
    s.font_dock.set("Sans 9");

    // Every key is covered by this test: if a key is added to wlprefs, it
    // must be given a different value above.
    try std.testing.expectEqual(prefs_settings.keys.len, prefs_settings.changedCount(&s, &base));

    const text = try prefs_settings.render(gpa, "", &s, &base);
    defer gpa.free(text);
    var cfg = try parseWithCompositor(gpa, text);
    defer cfg.deinit();

    try std.testing.expectEqual(s.gap, cfg.gap);
    try std.testing.expectEqual(s.outer_gap, cfg.outer_gap);
    try std.testing.expectApproxEqAbs(s.default_column_width, cfg.default_column_width, 0.0006);
    try std.testing.expectEqual(@as(usize, 3), cfg.width_presets.len);
    try std.testing.expectApproxEqAbs(@as(f64, 0.75), cfg.width_presets[2], 0.0001);
    try std.testing.expectApproxEqAbs(s.width_step, cfg.width_step, 0.0006);
    try std.testing.expectEqual(s.min_window_size, cfg.min_window_size);
    try std.testing.expectEqual(config.CenterMode.always, cfg.center_focused_column);
    try std.testing.expectEqual(config.NewWindowMode.stack, cfg.new_window);
    try std.testing.expectEqual(s.border_width, cfg.border_width);
    try std.testing.expectEqual(s.border_focused, cfg.border_focused);
    try std.testing.expectEqual(s.border_unfocused, cfg.border_unfocused);
    try std.testing.expectEqual(s.border_floating, cfg.border_floating);
    try std.testing.expectEqual(s.workspace_count, cfg.workspace_count);
    try std.testing.expectEqual(@as(usize, 3), cfg.workspace_names.len);
    try std.testing.expectEqualStrings("Main", cfg.workspace_names[0]);
    try std.testing.expectEqualStrings("", cfg.workspace_names[1]);
    try std.testing.expectEqualStrings("Code", cfg.workspace_names[2]);
    try std.testing.expectEqual(s.drag_threshold, cfg.drag_threshold);
    try std.testing.expectApproxEqAbs(s.floating_size, cfg.floating_size, 0.0006);
    try std.testing.expect(cfg.focus_follows_mouse);
    try std.testing.expect(cfg.mouse_mod.mod4 and cfg.mouse_mod.mod1 and cfg.mouse_mod.shift and !cfg.mouse_mod.ctrl);
    // argv: foot, -e, "htop -d 5" (one argument, quotes group it).
    try std.testing.expectEqual(@as(usize, 3), cfg.terminal.len);
    try std.testing.expectEqualStrings("foot", cfg.terminal[0]);
    try std.testing.expectEqualStrings("htop -d 5", cfg.terminal[2]);
    try std.testing.expectEqualStrings("wofi", cfg.launcher[0]);
    try std.testing.expectEqualStrings("/usr/bin/librewolf", cfg.browser[0]);
    try std.testing.expect(cfg.enable_wmaker_compat);
    try std.testing.expect(!cfg.enable_autostart);
    try std.testing.expect(!cfg.enable_dockapps);
    try std.testing.expect(!cfg.dock_enabled);
    try std.testing.expectEqual(config.DockEdge.left, cfg.dock_edge);
    try std.testing.expectEqual(@as(i32, 120), cfg.dock_offset);
    try std.testing.expectEqual(@as(i32, 96), cfg.dock_size);
    try std.testing.expect(!cfg.dock_on_top);
    try std.testing.expect(!cfg.dock_reserve_space);
    try std.testing.expect(!cfg.clip_enabled);
    try std.testing.expectEqual(config.ClipCorner.bottom_right, cfg.clip_corner);
    try std.testing.expect(!cfg.clip_on_top);
    try std.testing.expect(cfg.clip_collapsed);
    try std.testing.expectEqual(@as(?u32, 1), cfg.bind_layout);
    // `theme` needs an Includer to do anything; here it is only a line that
    // must not stop the parse.
    try std.testing.expect(std.mem.indexOf(u8, text, "theme(\"nord\")\n") != null);
}

test "wlprefs' action list is exactly what the compositor knows" {
    const actions = @import("wlprefs_actions");
    // Every command of types.Command (but `none`, and `lua`, which config.zig
    // writes for a `bind(combo, function)` and is no choice in a list) is
    // known to wlprefs ...
    inline for (@typeInfo(types.Command).@"union".fields) |f| {
        if (!std.mem.eql(u8, f.name, "none") and !std.mem.eql(u8, f.name, "lua")) {
            if (!actions.known(f.name)) {
                std.debug.print("wlprefs does not know the command `{s}`; add it to wlprefs/src/actions.zig\n", .{f.name});
                return error.ActionMissingInWlprefs;
            }
        }
    }
    // ... and the three spellings the parser adds, and no command exists only there.
    for ([_][]const u8{ "spawn_terminal", "spawn_launcher", "spawn_browser", "exec", "shexec" }) |n| {
        try std.testing.expect(actions.known(n));
    }
    for (actions.simple) |n| {
        const extra = std.mem.startsWith(u8, n, "spawn_");
        if (extra) continue;
        var found = false;
        inline for (@typeInfo(types.Command).@"union".fields) |f| {
            if (std.mem.eql(u8, f.name, n)) found = true;
        }
        if (!found) {
            std.debug.print("wlprefs lists `{s}`, which the compositor does not have\n", .{n});
            return error.ActionOnlyInWlprefs;
        }
    }
}

test "the compositor accepts a config that wlprefs edited in place, binds included" {
    const gpa = std.testing.allocator;
    const original =
        \\gap = 8
        \\bind("Super+x", "shell notify-send hi")
        \\unbind("Super+q")
        \\
    ;
    var base = prefs_settings.Settings.init();
    prefs_settings.parse(&base, original);
    var s = base;
    s.gap = 20;
    const text = try prefs_settings.render(gpa, original, &s, &base);
    defer gpa.free(text);

    var cfg = try parseWithCompositor(gpa, text);
    defer cfg.deinit();
    try std.testing.expectEqual(@as(i32, 20), cfg.gap);
    try std.testing.expect(std.mem.indexOf(u8, text, "bind(\"Super+x\", \"shell notify-send hi\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "unbind(\"Super+q\")") != null);
}

/// A config directory in memory: the files `include` and `theme` can read.
const MemFiles = struct {
    paths: []const []const u8,
    texts: []const []const u8,

    fn read(ctx: *anyopaque, a: std.mem.Allocator, path: []const u8) ?[]const u8 {
        const self: *const MemFiles = @ptrCast(@alignCast(ctx));
        for (self.paths, self.texts) |p, t| {
            if (std.mem.eql(u8, p, path)) return a.dupe(u8, t) catch null;
        }
        return null;
    }
};

fn parseWithIncludes(gpa: std.mem.Allocator, files: *const MemFiles, text: []const u8) !config.Config {
    var cfg: config.Config = .{ .arena = .init(gpa) };
    errdefer cfg.deinit();
    var binds: std.ArrayList(config.Bind) = .empty;
    const inc: config.Includer = .{ .ctx = @constCast(files), .read = MemFiles.read, .dir = "/cfg" };
    try config.parseWith(cfg.arena.allocator(), text, &cfg, &binds, "/cfg/config.lua", &inc, false);
    return cfg;
}

test "a config with theme() and include(): wlprefs edits its own lines, the compositor still reads all of it" {
    const gpa = std.testing.allocator;
    const files: MemFiles = .{
        .paths = &.{ "/cfg/Themes/t.lua", "/cfg/extra.lua" },
        .texts = &.{ "gap = 20\nborder_width = 6\n", "outer_gap = 5\n" },
    };
    const original =
        \\theme("t")
        \\gap = gap + 2
        \\include("extra.lua")
        \\terminal = "foot"
        \\
    ;

    // What the compositor makes of it: the theme sets gap to 20, the
    // script reads it and adds 2; the include comes on top.
    var before = try parseWithIncludes(gpa, &files, original);
    defer before.deinit();
    try std.testing.expectEqual(@as(i32, 22), before.gap);
    try std.testing.expectEqual(@as(i32, 6), before.border_width);
    try std.testing.expectEqual(@as(i32, 5), before.outer_gap);
    try std.testing.expectEqual(@as(u32, 0), before.parse_warnings);

    // wlprefs sees only the file itself: `gap` is computed (shown as the
    // default), the theme and the include are invisible to it.
    var base = prefs_settings.Settings.init();
    prefs_settings.parse(&base, original);
    try std.testing.expectEqual(prefs_settings.Odd.computed, base.odd[prefs_settings.keyIndex("gap").?]);
    try std.testing.expectEqualStrings("foot", base.terminal.get());

    // The user changes the terminal only.
    var s = base;
    s.terminal.set("alacritty");
    const text = try prefs_settings.render(gpa, original, &s, &base);
    defer gpa.free(text);
    try std.testing.expectEqualStrings(
        \\theme("t")
        \\gap = gap + 2
        \\include("extra.lua")
        \\terminal = "alacritty"
        \\
    , text);

    // And the compositor reads the edited file as before, plus the change.
    var after = try parseWithIncludes(gpa, &files, text);
    defer after.deinit();
    try std.testing.expectEqual(@as(i32, 22), after.gap);
    try std.testing.expectEqual(@as(i32, 6), after.border_width);
    try std.testing.expectEqual(@as(i32, 5), after.outer_gap);
    try std.testing.expectEqualStrings("alacritty", after.terminal[0]);
    try std.testing.expectEqual(@as(u32, 0), after.parse_warnings);
}

// ----------------------------------------------------------------------------
// Minimize / restore (Window Maker's miniaturize, HIDE, HIDE_OTHERS, SHOW_ALL)
// ----------------------------------------------------------------------------

test "minimize takes a tiled window out of the layout, restore puts it back where it was" {
    const f = try Fixture.init();
    defer f.deinit();
    const a = try f.newWindow();
    const b = try f.newWindow();
    const c = try f.newWindow();
    for ([_]*Window{ a, b, c }) |w| try workspace.placeTiled(&f.wm, f.cur(), w);
    const strip = &f.cur().strip;
    const mid = b.column.?;
    mid.width = 777;

    workspace.minimize(&f.wm, b);
    try check(f);
    try std.testing.expect(b.minimized);
    // Not placed anywhere: this is what hides it (applyRender hides every unplaced window).
    try std.testing.expect(b.workspace == null and b.column == null);
    try std.testing.expectEqual(@as(usize, 2), workspace.columnIndex(strip, c.column.?) + 1);

    try workspace.restore(&f.wm, b, f.cur());
    try check(f);
    try std.testing.expect(!b.minimized);
    try std.testing.expectEqual(@as(usize, 1), workspace.columnIndex(strip, b.column.?)); // its old slot
    try std.testing.expectEqual(@as(i32, 777), b.column.?.width); // and old width
    try std.testing.expect(strip.active == b.column.?);
}

test "a floating window keeps its rectangle across minimize and restore" {
    const f = try Fixture.init();
    defer f.deinit();
    const a = try f.newWindow();
    workspace.placeFloating(f.cur(), a);
    a.float_rect = .{ .x = 40, .y = 50, .w = 300, .h = 200 };
    a.has_float_rect = true;

    workspace.minimize(&f.wm, a);
    try check(f);
    try std.testing.expect(a.workspace == null and a.minimized and a.min_floating);

    try workspace.restore(&f.wm, a, f.cur());
    try check(f);
    try std.testing.expect(a.mode == .floating);
    try std.testing.expectEqual(types.Rect{ .x = 40, .y = 50, .w = 300, .h = 200 }, a.float_rect);
}

test "a fullscreen window is minimized cleanly and comes back as what it was" {
    const f = try Fixture.init();
    defer f.deinit();
    const a = try f.newWindow();
    try workspace.placeTiled(&f.wm, f.cur(), a);
    workspace.setFullscreen(&f.wm, a);
    try std.testing.expect(f.cur().fullscreen == a);

    workspace.minimize(&f.wm, a);
    try check(f);
    try std.testing.expect(f.cur().fullscreen == null);
    try workspace.restore(&f.wm, a, f.cur());
    try check(f);
    try std.testing.expect(a.mode == .tiled);
}

test "minimize and restore do nothing where they cannot, and survive a window closing" {
    const f = try Fixture.init();
    defer f.deinit();
    const a = try f.newWindow();
    // Unplaced: nothing to minimize.
    workspace.minimize(&f.wm, a);
    try std.testing.expect(!a.minimized);
    // Not minimized: nothing to restore.
    try workspace.restore(&f.wm, a, f.cur());
    try std.testing.expect(a.workspace == null);

    try workspace.placeTiled(&f.wm, f.cur(), a);
    workspace.minimize(&f.wm, a);
    workspace.minimize(&f.wm, a); // twice is fine
    try std.testing.expectEqual(@as(u64, 1), a.min_order);
    // A minimized window that closes is just unplaced: restore refuses it.
    a.closed = true;
    try workspace.restore(&f.wm, a, f.cur());
    try std.testing.expect(a.workspace == null);
    try check(f);
}

test "restore brings back the window minimized last; show_all brings back all" {
    const f = try Fixture.init();
    defer f.deinit();
    const a = try f.newWindow();
    const b = try f.newWindow();
    const c = try f.newWindow();
    for ([_]*Window{ a, b, c }) |w| try workspace.placeTiled(&f.wm, f.cur(), w);

    workspace.minimize(&f.wm, b);
    workspace.minimize(&f.wm, a);
    try std.testing.expect(workspace.lastMinimized(&f.wm) == a);

    // `restore` as a key binding.
    action_mod.run(&f.wm, .restore);
    try std.testing.expect(!a.minimized and b.minimized);
    try std.testing.expect(f.wm.focus_request == a);
    try check(f);

    workspace.minimize(&f.wm, a);
    action_mod.run(&f.wm, .show_all);
    try std.testing.expect(!a.minimized and !b.minimized);
    try std.testing.expect(workspace.lastMinimized(&f.wm) == null);
    // The one minimized last (a) is restored last, so it is the focused one.
    try std.testing.expect(f.wm.focus_request == a);
    try check(f);
}

test "hide_others minimizes other applications only; hide_app the focused one's" {
    const f = try Fixture.init();
    defer f.deinit();
    const t1 = try f.newWindow();
    const t2 = try f.newWindow();
    const web = try f.newWindow();
    const clock = try f.newWindow();
    t1.app_id = try std.testing.allocator.dupe(u8, "foot");
    t2.app_id = try std.testing.allocator.dupe(u8, "foot");
    web.app_id = try std.testing.allocator.dupe(u8, "firefox");
    clock.app_id = try std.testing.allocator.dupe(u8, "dockapp:clock");
    defer for ([_]*Window{ t1, t2, web, clock }) |w| std.testing.allocator.free(w.app_id.?);
    dockhost.adopt(&f.wm, clock); // a DockApp is in no workspace and not in the window list
    for ([_]*Window{ t1, t2, web }) |w| try workspace.placeTiled(&f.wm, f.cur(), w);
    workspace.activate(t1);

    // Nothing is focused through a seat in the fixture: `focusedWindow` falls
    // back on the workspace's last focused window, which is t1.
    action_mod.run(&f.wm, .hide_others);
    try std.testing.expect(!t1.minimized and !t2.minimized); // same application
    try std.testing.expect(web.minimized);
    try std.testing.expect(!clock.minimized); // a DockApp is never "hidden"
    try check(f);

    action_mod.run(&f.wm, .show_all);
    try std.testing.expect(!web.minimized);

    action_mod.run(&f.wm, .hide_app);
    try std.testing.expect(t1.minimized and t2.minimized);
    try std.testing.expect(!web.minimized and !clock.minimized);
    try check(f);
}

// ----------------------------------------------------------------------------
// Several outputs
// ----------------------------------------------------------------------------

/// A second output next to the fixture's first one.
fn addSecondOutput(f: *Fixture) !*Output {
    const a = std.testing.allocator;
    const out = try a.create(Output);
    out.* = .{ .obj = @ptrCast(&dummy_byte) };
    out.rect = .{ .x = 1920, .y = 0, .w = 1280, .h = 1024 };
    out.workspace_count = 2;
    for (0..2) |i| out.workspaces[i].init(out, @intCast(i));
    f.wm.outputs.append(out);
    return out;
}

fn destroySecondOutput(out: *Output) void {
    const a = std.testing.allocator;
    for (0..out.workspace_count) |i| {
        const ws = &out.workspaces[i];
        while (ws.strip.columns.first()) |c| {
            while (c.windows.first()) |w| types.unlink(&w.column_link);
            types.unlink(&c.link);
            a.destroy(c);
        }
    }
    types.unlink(&out.link);
    a.destroy(out);
}

test "cycleOutput wraps around and skips outputs that are gone" {
    const f = try Fixture.init();
    defer f.deinit();
    const second = try addSecondOutput(f);
    defer destroySecondOutput(second);

    try std.testing.expect(types.cycleOutput(&f.wm, f.out, true) == second);
    try std.testing.expect(types.cycleOutput(&f.wm, second, true) == f.out);
    try std.testing.expect(types.cycleOutput(&f.wm, f.out, false) == second);
    try std.testing.expect(types.cycleOutput(&f.wm, second, false) == f.out);

    second.removed = true;
    try std.testing.expect(types.cycleOutput(&f.wm, f.out, true) == f.out);
    second.removed = false;
}

test "focus_output_next works on an empty output, and commands then apply there" {
    const f = try Fixture.init();
    defer f.deinit();
    const second = try addSecondOutput(f);
    defer destroySecondOutput(second);

    const a = try f.newWindow();
    try workspace.placeTiled(&f.wm, f.cur(), a);
    workspace.activate(a);
    f.wm.active_output = f.out;

    action_mod.run(&f.wm, .focus_output_next);
    try std.testing.expect(f.wm.active_output == second);
    // The second output is empty: nothing to focus there.
    try std.testing.expect(f.wm.focus_request == null);
    try std.testing.expect(types.workingOutput(&f.wm) == second);

    // "workspace_next" now switches the workspace of the second output.
    action_mod.run(&f.wm, .workspace_next);
    try std.testing.expectEqual(@as(u32, 1), second.active);
    try std.testing.expectEqual(@as(u32, 0), f.out.active);

    action_mod.run(&f.wm, .focus_output_prev);
    try std.testing.expect(f.wm.active_output == f.out);
    try std.testing.expect(f.wm.focus_request == a);
}

test "move_to_output_next takes the focused window along, tiled or floating" {
    const f = try Fixture.init();
    defer f.deinit();
    const second = try addSecondOutput(f);
    defer destroySecondOutput(second);

    const t = try f.newWindow();
    const fl = try f.newWindow();
    try workspace.placeTiled(&f.wm, f.cur(), t);
    workspace.placeFloating(f.cur(), fl);
    fl.float_rect = .{ .x = 10, .y = 20, .w = 300, .h = 200 };
    fl.has_float_rect = true;
    f.wm.active_output = f.out;

    workspace.activate(t);
    action_mod.run(&f.wm, .move_to_output_next);
    try std.testing.expect(t.workspace == second.ws());
    try std.testing.expect(t.mode == .tiled);
    try std.testing.expect(f.wm.active_output == second);
    try std.testing.expect(f.wm.focus_request == t);

    f.wm.focus_request = null;
    f.wm.active_output = f.out;
    workspace.activate(fl);
    f.cur().last_focused = fl;
    action_mod.run(&f.wm, .move_to_output_next);
    try std.testing.expect(fl.workspace == second.ws());
    try std.testing.expect(fl.mode == .floating);
    try std.testing.expectEqual(@as(i32, 300), fl.float_rect.w);
}

test "with one output the output commands do nothing" {
    const f = try Fixture.init();
    defer f.deinit();
    const a = try f.newWindow();
    try workspace.placeTiled(&f.wm, f.cur(), a);
    f.wm.active_output = f.out;
    action_mod.run(&f.wm, .focus_output_next);
    action_mod.run(&f.wm, .move_to_output_prev);
    try std.testing.expect(a.workspace == f.cur());
    try std.testing.expect(f.wm.active_output == f.out);
}

test "a removed active output is never returned as the working output" {
    const f = try Fixture.init();
    defer f.deinit();
    const second = try addSecondOutput(f);
    defer destroySecondOutput(second);
    f.wm.active_output = second;
    try std.testing.expect(types.workingOutput(&f.wm) == second);
    second.removed = true;
    try std.testing.expect(types.workingOutput(&f.wm) == f.out);
    second.removed = false;
}

// ============================================================================
// Camera follows a maximized window, modular workspaces, reload, niri options
// ============================================================================

fn testSeatFor(f: *Fixture) !*types.Seat {
    const s = try std.testing.allocator.create(types.Seat);
    s.* = .{ .obj = @ptrCast(&dummy_byte), .xkb_bindings = undefined, .pointer_bindings = undefined };
    s.xkb_bindings.init();
    s.pointer_bindings.init();
    f.wm.seats.append(s);
    return s;
}

fn dropSeat(s: *types.Seat) void {
    types.unlink(&s.link);
    std.testing.allocator.destroy(s);
}

test "the view stays on a maximized column, even when it drifts or the work area changes" {
    const f = try Fixture.init();
    defer f.deinit();
    const a = try f.newWindow();
    const b = try f.newWindow();
    const c = try f.newWindow();
    try workspace.placeTiled(&f.wm, f.cur(), a);
    try workspace.placeTiled(&f.wm, f.cur(), b);
    try workspace.placeTiled(&f.wm, f.cur(), c);
    const strip = &f.cur().strip;
    strip.active = b.column.?;
    workspace.toggleMaximized(&f.wm, b.column.?);
    layout.compute(f.cur(), &f.wm.cfg, true);
    const locked = strip.scroll_x;
    try std.testing.expectEqual(b.column.?.x - f.wm.cfg.outer_gap, locked);

    // A scroll command moves the view away; the next pass (no focus change!)
    // puts it back.
    layout.scrollBy(strip, 400, 1920, &f.wm.cfg);
    layout.compute(f.cur(), &f.wm.cfg, false);
    try std.testing.expectEqual(locked, strip.scroll_x);

    // The Dock appears and takes 64px: the maximized column still fills the
    // view and the view is still on it.
    f.out.reserved = .{ .right = 64 };
    layout.compute(f.cur(), &f.wm.cfg, false);
    try std.testing.expectEqual(b.column.?.x - f.wm.cfg.outer_gap, strip.scroll_x);
    try std.testing.expectEqual(f.out.workArea().w - 2 * f.wm.cfg.outer_gap, b.column.?.width);

    // With maximize_follow = false the camera is free again.
    f.wm.cfg.maximize_follow = false;
    strip.scroll_x = 0;
    layout.compute(f.cur(), &f.wm.cfg, false);
    try std.testing.expectEqual(@as(i32, 0), strip.scroll_x);
    try check(f);
}

test "maximize_keep_focus: a new tiled window opens beside a maximized one without taking the focus" {
    const f = try Fixture.init();
    defer f.deinit();
    const window_mod = @import("window.zig");
    const seat = try testSeatFor(f);
    defer dropSeat(seat);

    const a = try f.newWindow();
    try workspace.placeTiled(&f.wm, f.cur(), a);
    a.new = false; // placed by hand: placeNew must leave it alone
    workspace.activate(a);
    workspace.toggleMaximized(&f.wm, a.column.?);
    seat.focused = a;

    // default: the new window takes the focus
    const b = try f.newWindow();
    b.new = true;
    window_mod.placeNew(&f.wm);
    try std.testing.expect(f.wm.focus_request == b);
    try std.testing.expect(f.cur().strip.active == b.column.?);
    f.wm.focus_request = null;
    seat.focused = a;
    f.cur().strip.active = a.column.?;
    a.column.?.focused = a;

    f.wm.cfg.maximize_keep_focus = true;
    const c = try f.newWindow();
    c.new = true;
    window_mod.placeNew(&f.wm);
    try std.testing.expect(f.wm.focus_request == null);
    try std.testing.expect(f.cur().strip.active == a.column.?);
    try std.testing.expect(c.column != null and c.column.? != a.column.?);
    try std.testing.expectEqual(@as(usize, 3), f.cur().strip.columnCount());
    try check(f);
}

test "setWorkspaceCount grows with empty workspaces and shrinks by moving windows to the last one" {
    const f = try Fixture.init();
    defer f.deinit();
    try std.testing.expect(workspace.setWorkspaceCount(&f.wm, f.out, 5));
    try std.testing.expectEqual(@as(u32, 5), f.out.workspace_count);
    try std.testing.expect(f.out.workspaces[4].isEmpty());
    try std.testing.expect(!workspace.setWorkspaceCount(&f.wm, f.out, 5)); // no change

    const a = try f.newWindow();
    const b = try f.newWindow();
    try workspace.placeTiled(&f.wm, &f.out.workspaces[3], a);
    workspace.placeFloating(&f.out.workspaces[4], b);
    f.out.active = 4;

    try std.testing.expect(workspace.setWorkspaceCount(&f.wm, f.out, 3));
    try std.testing.expectEqual(@as(u32, 3), f.out.workspace_count);
    try std.testing.expect(a.workspace == &f.out.workspaces[2]);
    try std.testing.expect(b.workspace == &f.out.workspaces[2]);
    try std.testing.expectEqual(@as(u32, 2), f.out.active); // the shown one was removed
    try check(f);

    // clamped to 1..max
    try std.testing.expect(workspace.setWorkspaceCount(&f.wm, f.out, 0));
    try std.testing.expectEqual(@as(u32, 1), f.out.workspace_count);
    try std.testing.expect(workspace.setWorkspaceCount(&f.wm, f.out, 99));
    try std.testing.expectEqual(@as(u32, config.max_workspaces), f.out.workspace_count);
    try check(f);
}

test "workspace_add / workspace_remove_last, and workspace N creates the workspace" {
    const f = try Fixture.init();
    defer f.deinit();
    const run = action_mod.run;
    run(&f.wm, .workspace_add);
    try std.testing.expectEqual(@as(u32, 3), f.out.workspace_count);

    const a = try f.newWindow();
    try workspace.placeTiled(&f.wm, &f.out.workspaces[2], a);
    run(&f.wm, .workspace_remove_last);
    try std.testing.expectEqual(@as(u32, 2), f.out.workspace_count);
    try std.testing.expect(a.workspace == &f.out.workspaces[1]); // moved to the one before

    run(&f.wm, .{ .workspace = 6 }); // `workspace 7` does not exist yet
    try std.testing.expectEqual(@as(u32, 7), f.out.workspace_count);
    try std.testing.expectEqual(@as(u32, 6), f.out.active);

    // never below one
    var i: u32 = 0;
    while (i < 20) : (i += 1) run(&f.wm, .workspace_remove_last);
    try std.testing.expectEqual(@as(u32, 1), f.out.workspace_count);
    try check(f);
}

test "workspace_last goes back; workspace_back_and_forth makes `workspace N` do it too" {
    const f = try Fixture.init();
    defer f.deinit();
    const run = action_mod.run;
    run(&f.wm, .{ .workspace = 1 });
    try std.testing.expectEqual(@as(u32, 1), f.out.active);
    try std.testing.expectEqual(@as(?u32, 0), f.out.prev_active);
    run(&f.wm, .workspace_last);
    try std.testing.expectEqual(@as(u32, 0), f.out.active);
    run(&f.wm, .workspace_last);
    try std.testing.expectEqual(@as(u32, 1), f.out.active);

    // On the shown workspace, `workspace 2` does nothing ...
    run(&f.wm, .{ .workspace = 1 });
    try std.testing.expectEqual(@as(u32, 1), f.out.active);
    // ... unless workspace_back_and_forth is on.
    f.wm.cfg.workspace_back_and_forth = true;
    run(&f.wm, .{ .workspace = 1 });
    try std.testing.expectEqual(@as(u32, 0), f.out.active);
}

test "dynamic workspaces: one empty one at the end, no empty ones behind it" {
    const f = try Fixture.init();
    defer f.deinit();
    f.wm.cfg.dynamic_workspaces = true;
    const min: u32 = 2;
    workspace.maintainDynamic(&f.wm, f.out, min);
    try std.testing.expectEqual(@as(u32, 2), f.out.workspace_count); // last is empty already

    const a = try f.newWindow();
    try workspace.placeTiled(&f.wm, &f.out.workspaces[1], a); // the last one gets used
    workspace.maintainDynamic(&f.wm, f.out, min);
    try std.testing.expectEqual(@as(u32, 3), f.out.workspace_count);
    try std.testing.expect(f.out.workspaces[2].isEmpty());

    workspace.unplace(&f.wm, a); // it closes again
    workspace.maintainDynamic(&f.wm, f.out, min);
    try std.testing.expectEqual(@as(u32, 2), f.out.workspace_count);

    // the shown workspace is never dropped
    try std.testing.expect(workspace.setWorkspaceCount(&f.wm, f.out, 4));
    f.out.active = 3;
    workspace.maintainDynamic(&f.wm, f.out, min);
    try std.testing.expectEqual(@as(u32, 4), f.out.workspace_count);
    try check(f);
}

test "move_to_workspace_next / _prev take the window along and keep its column width" {
    const f = try Fixture.init();
    defer f.deinit();
    const a = try f.newWindow();
    try workspace.placeTiled(&f.wm, f.cur(), a);
    a.column.?.width = 777;
    workspace.activate(a);
    const seat = try testSeatFor(f);
    defer dropSeat(seat);
    seat.focused = a;

    action_mod.run(&f.wm, .move_to_workspace_next);
    try std.testing.expectEqual(@as(u32, 1), f.out.active);
    try std.testing.expect(a.workspace == &f.out.workspaces[1]);
    try std.testing.expectEqual(@as(i32, 777), a.column.?.width);
    try std.testing.expect(f.wm.focus_request == a);

    action_mod.run(&f.wm, .move_to_workspace_prev);
    try std.testing.expectEqual(@as(u32, 0), f.out.active);
    try std.testing.expect(a.workspace == &f.out.workspaces[0]);

    // no wrap: prev on the first workspace stays
    f.wm.cfg.workspace_wrap = false;
    action_mod.run(&f.wm, .move_to_workspace_prev);
    try std.testing.expect(a.workspace == &f.out.workspaces[0]);
    try check(f);
}

test "focus_up / focus_down step through floating windows in the order they were opened" {
    const f = try Fixture.init();
    defer f.deinit();
    const seat = try testSeatFor(f);
    defer dropSeat(seat);
    const w0 = try f.newWindow();
    const w1 = try f.newWindow();
    const w2 = try f.newWindow();
    for ([_]*Window{ w0, w1, w2 }) |w| {
        w.workspace = f.cur();
        workspace.placeFloating(f.cur(), w);
    }
    seat.focused = w0;
    // Focusing raises the window; the walk must not depend on that.
    const expect_order = [_]*Window{ w1, w2, w0, w1 };
    for (expect_order) |want| {
        action_mod.run(&f.wm, .focus_down);
        try std.testing.expect(f.wm.focus_request == want);
        seat.focused = f.wm.focus_request;
    }
    const back = [_]*Window{ w0, w2, w1 };
    for (back) |want| {
        action_mod.run(&f.wm, .focus_up);
        try std.testing.expect(f.wm.focus_request == want);
        seat.focused = f.wm.focus_request;
    }
    try check(f);
}

test "set_column_width, reload_config and the new commands parse" {
    var cfg = try config.load(std.testing.io, std.testing.allocator);
    defer cfg.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const w = try action_mod.parse(a, &cfg, "set_column_width 50%");
    try std.testing.expectEqual(@as(f64, 0.5), w.set_column_width);
    const w2 = try action_mod.parse(a, &cfg, "set_column_width 0.25");
    try std.testing.expectEqual(@as(f64, 0.25), w2.set_column_width);
    try std.testing.expectError(error.BadArguments, action_mod.parse(a, &cfg, "set_column_width"));
    try std.testing.expectError(error.BadArguments, action_mod.parse(a, &cfg, "set_column_width 0"));
    try std.testing.expectError(error.BadArguments, action_mod.parse(a, &cfg, "set_column_width 101%"));
    try std.testing.expectError(error.BadArguments, action_mod.parse(a, &cfg, "set_column_width wide"));

    try std.testing.expect((try action_mod.parse(a, &cfg, "reload_config")) == .reload_config);
    try std.testing.expect((try action_mod.parse(a, &cfg, "workspace_last")) == .workspace_last);
    // up to the maximum, not just workspace_count: created when used
    try std.testing.expectEqual(@as(u32, 11), (try action_mod.parse(a, &cfg, "workspace 12")).workspace);
    try std.testing.expectError(error.BadArguments, action_mod.parse(a, &cfg, "workspace 17"));
    try std.testing.expectError(error.BadArguments, action_mod.parse(a, &cfg, "workspace 0"));

    // The shipped config binds reload_config.
    var bound = false;
    for (cfg.binds) |b| {
        if (std.mem.eql(u8, b.command, "reload_config")) bound = true;
    }
    try std.testing.expect(bound);
}

test "the reload_config command only asks for a reload (the manage pass does it)" {
    const f = try Fixture.init();
    defer f.deinit();
    try std.testing.expect(!f.wm.reload_pending);
    action_mod.run(&f.wm, .reload_config);
    try std.testing.expect(f.wm.reload_pending);
}

test "set_column_width sets the active column and ends maximize" {
    const f = try Fixture.init();
    defer f.deinit();
    const a = try f.newWindow();
    try workspace.placeTiled(&f.wm, f.cur(), a);
    workspace.toggleMaximized(&f.wm, a.column.?);
    action_mod.run(&f.wm, .{ .set_column_width = 0.5 });
    try std.testing.expect(!a.column.?.isMaximized());
    try std.testing.expectEqual(layout.columnWidthFor(1920, 0.5, &f.wm.cfg), a.column.?.width);
}

test "struts shrink the work area the windows are laid out in" {
    const f = try Fixture.init();
    defer f.deinit();
    const a = try f.newWindow();
    try workspace.placeTiled(&f.wm, f.cur(), a);
    a.column.?.width = layout.columnWidthFor(1920, 1.0, &f.wm.cfg);
    layout.compute(f.cur(), &f.wm.cfg, true);
    const base_x = a.target.x;
    const base_y = a.target.y;
    // The column keeps its share of the work area when that shrinks (layout
    // rescales it), so a full-width column stays full-width.
    f.out.struts = .{ .left = 100, .top = 40, .right = 60, .bottom = 20 };
    layout.compute(f.cur(), &f.wm.cfg, true);
    try std.testing.expectEqual(base_x + 100, a.target.x);
    try std.testing.expectEqual(base_y + 40, a.target.y);
    try std.testing.expectEqual(@as(i32, 1920 - 100 - 60 - 2 * f.wm.cfg.outer_gap - 2 * f.wm.cfg.border_width), a.target.w);
    try std.testing.expectEqual(@as(i32, 1080 - 40 - 20 - 2 * f.wm.cfg.outer_gap - 2 * f.wm.cfg.border_width), a.target.h);
}

test "center_single_column centres a lone narrow column, and only that" {
    const f = try Fixture.init();
    defer f.deinit();
    const a = try f.newWindow();
    try workspace.placeTiled(&f.wm, f.cur(), a);
    a.column.?.width = 600;
    layout.compute(f.cur(), &f.wm.cfg, true);
    const left = a.target.x;
    try std.testing.expectEqual(f.wm.cfg.outer_gap + f.wm.cfg.border_width, left);

    f.wm.cfg.center_single_column = true;
    layout.compute(f.cur(), &f.wm.cfg, true);
    const outer_l = a.target.x - f.wm.cfg.border_width;
    const outer_r = 1920 - (a.target.x - f.wm.cfg.border_width + a.column.?.width);
    try std.testing.expect(@abs(outer_l - outer_r) <= 1);

    // two columns: back to the normal strip
    const b = try f.newWindow();
    try workspace.placeTiled(&f.wm, f.cur(), b);
    layout.compute(f.cur(), &f.wm.cfg, true);
    try std.testing.expectEqual(@as(i32, 0), f.cur().strip.offset_x);
}

test "clicking a window makes it the active one, so the view follows it (focus path)" {
    // main.onManage activates the focus target before the layout; pin the order.
    const src = @embedFile("main.zig");
    const body_start = std.mem.indexOf(u8, src, "fn onManage(wm: *WindowManager) void {").?;
    const body_end = std.mem.indexOfPos(u8, src, body_start, "\n}").?;
    const body = src[body_start..body_end];
    const resolve = std.mem.indexOf(u8, body, "resolveFocus(wm)").?;
    const activate = std.mem.indexOf(u8, body, "workspace.activate(w)").?;
    const lay = std.mem.indexOf(u8, body, "layoutAll(wm)").?;
    try std.testing.expect(resolve < activate and activate < lay);
    // and the reload runs after the queued actions
    try std.testing.expect(std.mem.indexOf(u8, body, "reloadConfig(wm);\n    }").? > std.mem.indexOf(u8, body, "runPending(wm);").?);
}
