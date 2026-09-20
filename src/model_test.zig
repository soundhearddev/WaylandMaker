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
                .seats = undefined,
            },
            .out = undefined,
        };
        f.wm.outputs.init();
        f.wm.windows.init();
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

    // Reaching here means default_config.conf parsed; now every bind's
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
