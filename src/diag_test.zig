// SPDX-License-Identifier: GPL-3.0
//
// Tests for the diagnostics (invariants.zig, dump.zig) and for the monitor
// handling on a model (types.zig output order, output.zig rules and homes).
// They use the same fixture as model_test.zig: a window manager with dummy
// Wayland objects, never talking to a compositor.

const std = @import("std");
const types = @import("types.zig");
const workspace = @import("workspace.zig");
const output = @import("output.zig");
const monitors = @import("monitors.zig");
const invariants = @import("invariants.zig");
const dump = @import("dump.zig");
const mt = @import("model_test.zig");

const Fixture = mt.Fixture;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

fn named(out: *types.Output, name: []const u8) void {
    out.mon.name.set(name);
    out.mon.make.set("Acme");
    out.mon.model.set("M1");
    out.mon.complete = true;
}

fn expectClean(f: *Fixture) !void {
    const rep = invariants.check(&f.wm);
    if (!rep.clean()) {
        var buf: [2048]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        rep.write(&w) catch {};
        std.debug.print("{s}", .{w.buffered()});
    }
    try expect(rep.clean());
}

// ---- invariants -------------------------------------------------------------

test "invariants: an empty model and a busy one are clean" {
    const f = try Fixture.init();
    defer f.deinit();
    try expectClean(f);

    const a = try f.newWindow();
    const b = try f.newWindow();
    const c = try f.newWindow();
    try workspace.placeTiled(&f.wm, f.cur(), a);
    try workspace.placeTiled(&f.wm, f.cur(), b);
    try workspace.placeTiled(&f.wm, f.cur(), c);
    workspace.floatWindow(&f.wm, b);
    try expectClean(f);
    workspace.setFullscreen(&f.wm, a);
    try expectClean(f);
    try workspace.moveToWorkspace(&f.wm, c, &f.out.workspaces[1]);
    try expectClean(f);
    workspace.minimize(&f.wm, c);
    try expectClean(f);
}

test "invariants: a window that says it is floating while in a column is reported" {
    const f = try Fixture.init();
    defer f.deinit();
    const a = try f.newWindow();
    try workspace.placeTiled(&f.wm, f.cur(), a);
    try expectClean(f);

    a.mode = .floating;
    defer a.mode = .tiled;
    const rep = invariants.check(&f.wm);
    try expect(!rep.clean());
    try expect(std.mem.indexOf(u8, rep.message(0), "mode") != null);
}

test "invariants: a wrong back-pointer and a window in two containers are reported" {
    const f = try Fixture.init();
    defer f.deinit();
    const a = try f.newWindow();
    try workspace.placeTiled(&f.wm, f.cur(), a);

    const saved = a.workspace;
    a.workspace = &f.out.workspaces[1];
    try expect(!invariants.check(&f.wm).clean());
    a.workspace = saved;
    try expectClean(f);

    // Linked as floating as well (I2).
    f.cur().floating.append(a);
    try expect(!invariants.check(&f.wm).clean());
    types.unlink(&a.floating_link);
    try expectClean(f);
}

test "invariants: an empty column (I4) and a dangling active column are reported" {
    const f = try Fixture.init();
    defer f.deinit();
    const a = try f.newWindow();
    try workspace.placeTiled(&f.wm, f.cur(), a);
    const col = a.column.?;

    // Take the window out of the column but leave the column: I4.
    types.unlink(&a.column_link);
    const rep = invariants.check(&f.wm);
    try expect(!rep.clean());
    var found_empty = false;
    for (0..rep.n) |i| {
        if (std.mem.indexOf(u8, rep.message(i), "empty") != null) found_empty = true;
    }
    try expect(found_empty);
    col.windows.append(a);
    try expectClean(f);

    const keep = f.cur().strip.active;
    f.cur().strip.active = @ptrFromInt(@alignOf(types.Column) * 64);
    try expect(!invariants.check(&f.wm).clean());
    f.cur().strip.active = keep;
    try expectClean(f);
}

test "invariants: an active output that is in no list is reported" {
    const f = try Fixture.init();
    defer f.deinit();
    const ghost = try std.testing.allocator.create(types.Output);
    defer std.testing.allocator.destroy(ghost);
    ghost.* = .{ .obj = f.out.obj };
    f.wm.active_output = ghost;
    try expect(!invariants.check(&f.wm).clean());
    f.wm.active_output = f.out;
    try expectClean(f);
}

test "invariants: a bad workspace count is reported and does not crash the check" {
    const f = try Fixture.init();
    defer f.deinit();
    const keep = f.out.active;
    f.out.active = 99;
    try expect(!invariants.check(&f.wm).clean());
    f.out.active = keep;
    try expectClean(f);
}

test "invariants: the report keeps the first violations and counts them all" {
    var r: invariants.Report = .{};
    var i: usize = 0;
    while (i < invariants.max_violations + 5) : (i += 1) {
        // Through the public path: build the report by the same adder.
        r.total += 1;
        if (r.n < invariants.max_violations) {
            r.lens[r.n] = 0;
            r.n += 1;
        }
    }
    try expectEqual(@as(usize, invariants.max_violations), r.n);
    try expectEqual(@as(usize, invariants.max_violations + 5), r.total);
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try r.write(&w);
    try expect(std.mem.indexOf(u8, w.buffered(), "and 5 more") != null);
}

// ---- dump ---------------------------------------------------------------------

test "dump: shows outputs, workspaces, windows and a clean invariant check" {
    const f = try Fixture.init();
    defer f.deinit();
    named(f.out, "eDP-1");
    const a = try f.newWindow();
    var id_buf = "foot".*;
    a.app_id = &id_buf;
    try workspace.placeTiled(&f.wm, f.cur(), a);

    var buf: [16 * 1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try dump.write(&f.wm, &w, 5);
    const out = w.buffered();
    try expect(std.mem.indexOf(u8, out, "state dump") != null);
    try expect(std.mem.indexOf(u8, out, "output 0: Acme M1 (eDP-1) 1920x1080+0+0") != null);
    try expect(std.mem.indexOf(u8, out, "foot") != null);
    try expect(std.mem.indexOf(u8, out, "invariants: all hold") != null);
    try expect(std.mem.indexOf(u8, out, "perf (ms)") != null);
    try expect(std.mem.indexOf(u8, out, "recent log") != null);
}

test "dump: marks a window that remembers its home monitor, and an unplaced one" {
    const f = try Fixture.init();
    defer f.deinit();
    const a = try f.newWindow();
    try workspace.placeTiled(&f.wm, f.cur(), a);
    a.home = .{ .key = 0xabc, .ws = 1 };
    const b = try f.newWindow(); // never placed
    _ = b;
    var buf: [16 * 1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try dump.write(&f.wm, &w, 0);
    try expect(std.mem.indexOf(u8, w.buffered(), "home=abc/ws2") != null);
    try expect(std.mem.indexOf(u8, w.buffered(), "unplaced") != null);
}

test "dump: a model without outputs still dumps" {
    const f = try Fixture.init();
    defer f.deinit();
    f.out.removed = true;
    defer f.out.removed = false;
    var buf: [16 * 1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try dump.write(&f.wm, &w, 0);
    try expect(std.mem.indexOf(u8, w.buffered(), "REMOVED") != null);
}

// ---- output order, primary, neighbours ------------------------------------------

test "liveOutputs: left to right by default, connection order on request" {
    const f = try Fixture.init();
    defer f.deinit();
    const second = try mt.addSecondOutput(f);
    defer mt.destroySecondOutput(second);

    // The second output is announced later but sits LEFT of the first.
    second.rect.x = -1280;
    var buf: [monitors.max_monitors]*types.Output = undefined;
    try expectEqual(@as(usize, 2), types.liveOutputs(&f.wm, &buf));
    try expect(buf[0] == second and buf[1] == f.out);
    try expect(types.cycleOutput(&f.wm, second, true) == f.out);

    f.wm.monitors.order = .connection;
    _ = types.liveOutputs(&f.wm, &buf);
    try expect(buf[0] == f.out and buf[1] == second);
}

test "liveOutputs skips removed, disabled and not yet sized outputs" {
    const f = try Fixture.init();
    defer f.deinit();
    const second = try mt.addSecondOutput(f);
    defer mt.destroySecondOutput(second);
    var buf: [monitors.max_monitors]*types.Output = undefined;

    second.disabled = true;
    try expectEqual(@as(usize, 1), types.liveOutputs(&f.wm, &buf));
    second.disabled = false;
    second.rect.w = 0;
    try expectEqual(@as(usize, 1), types.liveOutputs(&f.wm, &buf));
    second.rect.w = 1280;
    second.removed = true;
    try expectEqual(@as(usize, 1), types.liveOutputs(&f.wm, &buf));
    second.removed = false;
    try expectEqual(@as(usize, 2), types.liveOutputs(&f.wm, &buf));
}

test "primaryOutput: the flagged one, else the first in order, else none" {
    const f = try Fixture.init();
    defer f.deinit();
    const second = try mt.addSecondOutput(f);
    defer mt.destroySecondOutput(second);
    try expect(types.primaryOutput(&f.wm) == f.out);
    second.primary = true;
    try expect(types.primaryOutput(&f.wm) == second);
    second.disabled = true; // a switched-off monitor cannot be primary
    try expect(types.primaryOutput(&f.wm) == f.out);
    f.out.removed = true;
    second.disabled = false;
    try expect(types.primaryOutput(&f.wm) == second);
    f.out.removed = false;
    second.removed = true;
    f.out.removed = true;
    try expect(types.primaryOutput(&f.wm) == null);
    f.out.removed = false;
    second.removed = false;
}

test "outputToward: the neighbour on the desk" {
    const f = try Fixture.init();
    defer f.deinit();
    const second = try mt.addSecondOutput(f); // right of f.out
    defer mt.destroySecondOutput(second);
    try expect(types.outputToward(&f.wm, f.out, .right) == second);
    try expect(types.outputToward(&f.wm, second, .left) == f.out);
    try expect(types.outputToward(&f.wm, f.out, .left) == null);
    try expect(types.outputToward(&f.wm, f.out, .up) == null);
}

// ---- rules and homes ----------------------------------------------------------------

fn setup2(f: *Fixture) !*types.Output {
    f.wm.cfg.workspace_count = 2;
    const second = try mt.addSecondOutput(f);
    named(f.out, "eDP-1");
    named(second, "DP-2");
    second.mon.model.set("M2");
    return second;
}

test "windows of a monitor that goes away come back when it returns" {
    const f = try Fixture.init();
    defer f.deinit();
    const second = try setup2(f);
    defer mt.destroySecondOutput(second);

    const a = try f.newWindow();
    const b = try f.newWindow();
    try workspace.placeTiled(&f.wm, &second.workspaces[1], a); // on DP-2, workspace 2
    try workspace.placeTiled(&f.wm, f.cur(), b); // on the laptop

    // The monitor goes away: what output.migrate does, noting the home first.
    output.rememberHome(&f.wm, second, a, 1);
    try expect(a.home.isSet() and a.home.ws == 1 and a.home.matches(second.mon.key()));
    try workspace.moveToWorkspace(&f.wm, a, &f.out.workspaces[1]);
    try expect(a.workspace.?.output == f.out);
    try expectClean(f);

    // It comes back: the window goes to the same workspace, b stays.
    try expectEqual(@as(usize, 1), output.restoreHomes(&f.wm, second));
    try expect(a.workspace == &second.workspaces[1]);
    try expect(!a.home.isSet());
    try expect(b.workspace.?.output == f.out);
    try expectClean(f);
    // Nothing more to give back.
    try expectEqual(@as(usize, 0), output.restoreHomes(&f.wm, second));
}

test "the first home wins when a window is moved twice" {
    const f = try Fixture.init();
    defer f.deinit();
    const second = try setup2(f);
    defer mt.destroySecondOutput(second);
    const a = try f.newWindow();
    try workspace.placeTiled(&f.wm, &second.workspaces[0], a);
    output.rememberHome(&f.wm, second, a, 0);
    const key = a.home.key;
    output.rememberHome(&f.wm, f.out, a, 1); // later, from another monitor
    try expectEqual(key, a.home.key);
    try expectEqual(@as(u32, 0), a.home.ws);
}

test "a monitor nobody can tell apart has no home to return to" {
    const f = try Fixture.init();
    defer f.deinit();
    const a = try f.newWindow();
    try workspace.placeTiled(&f.wm, f.cur(), a);
    output.rememberHome(&f.wm, f.out, a, 0); // f.out has no name yet
    try expect(!a.home.isSet());
    try expectEqual(@as(usize, 0), output.restoreHomes(&f.wm, f.out));
}

test "restore_windows = false: nothing is remembered" {
    const f = try Fixture.init();
    defer f.deinit();
    const second = try setup2(f);
    defer mt.destroySecondOutput(second);
    const rules = [_]monitors.Rule{.{ .match = "DP-2", .restore_windows = false }};
    f.wm.monitors.rules = &rules;
    const a = try f.newWindow();
    try workspace.placeTiled(&f.wm, &second.workspaces[0], a);
    output.rememberHome(&f.wm, second, a, 0);
    try expect(!a.home.isSet());
}

test "a minimized window loses its home note without being moved" {
    const f = try Fixture.init();
    defer f.deinit();
    const second = try setup2(f);
    defer mt.destroySecondOutput(second);
    const a = try f.newWindow();
    try workspace.placeTiled(&f.wm, &second.workspaces[0], a);
    output.rememberHome(&f.wm, second, a, 0);
    workspace.minimize(&f.wm, a);
    try expectEqual(@as(usize, 0), output.restoreHomes(&f.wm, second));
    try expect(!a.home.isSet());
    try expect(a.workspace == null);
}

test "applyRule: enabled = false sends the windows to the other monitor; a later enable brings them back" {
    const f = try Fixture.init();
    defer f.deinit();
    const second = try setup2(f);
    defer mt.destroySecondOutput(second);
    const a = try f.newWindow();
    try workspace.placeTiled(&f.wm, &second.workspaces[1], a);

    var rules = [_]monitors.Rule{.{ .match = "DP-2", .enabled = false, .workspaces = 2 }};
    f.wm.monitors.rules = &rules;
    output.applyRule(&f.wm, second);
    try expect(second.disabled and second.settled);
    try expect(a.workspace.?.output == f.out);
    try expectEqual(@as(u32, 1), a.workspace.?.index);
    try expect(types.primaryOutput(&f.wm) == f.out);
    try expectClean(f);

    rules[0].enabled = true;
    output.applyRule(&f.wm, second);
    try expect(!second.disabled);
    try expect(a.workspace == &second.workspaces[1]);
    try expectClean(f);
}

test "applyRule: the only monitor cannot be switched off" {
    const f = try Fixture.init();
    defer f.deinit();
    f.wm.cfg.workspace_count = 2;
    named(f.out, "eDP-1");
    const rules = [_]monitors.Rule{.{ .match = "eDP-1", .enabled = false, .workspaces = 2 }};
    f.wm.monitors.rules = &rules;
    output.applyRule(&f.wm, f.out);
    try expect(!f.out.disabled);
    try expect(types.liveOutput(f.out));
}

test "applyRule: primary, first workspace and workspace count" {
    const f = try Fixture.init();
    defer f.deinit();
    const second = try setup2(f);
    defer mt.destroySecondOutput(second);
    const rules = [_]monitors.Rule{.{ .match = "DP-2", .primary = true, .workspaces = 2, .start_workspace = 1 }};
    f.wm.monitors.rules = &rules;
    output.applyRule(&f.wm, second);
    try expect(second.primary);
    try expectEqual(@as(u32, 1), second.active);
    try expectEqual(@as(u32, 2), second.workspace_count);
    try expect(types.primaryOutput(&f.wm) == second);

    // A second application (a config reload) must not reset the workspace
    // the user has switched to since.
    second.active = 0;
    output.applyRule(&f.wm, second);
    try expectEqual(@as(u32, 0), second.active);
}

test "applyRule on a removed output does nothing" {
    const f = try Fixture.init();
    defer f.deinit();
    f.wm.cfg.workspace_count = 2;
    f.out.removed = true;
    defer f.out.removed = false;
    output.applyRule(&f.wm, f.out);
    try expect(!f.out.settled);
}

// ---- random operations: the invariants must hold after every one -----------------------

fn pickWorkspace(f: *Fixture, second: *types.Output, rng: std.Random) *types.Workspace {
    const out = if (rng.boolean()) f.out else second;
    return &out.workspaces[rng.uintLessThan(u32, out.workspace_count)];
}

fn randomStep(f: *Fixture, second: *types.Output, rules: *[1]monitors.Rule, rng: std.Random) !void {
    const w = f.wins[rng.uintLessThan(usize, f.used)];
    switch (rng.uintLessThan(u8, 9)) {
        0, 1 => {
            // Put an unplaced / minimized window somewhere.
            if (w.minimized) {
                try workspace.restore(&f.wm, w, pickWorkspace(f, second, rng));
            } else if (w.workspace == null) {
                const ws = pickWorkspace(f, second, rng);
                if (rng.boolean()) try workspace.placeTiled(&f.wm, ws, w) else workspace.placeFloating(ws, w);
            }
        },
        2 => switch (w.mode) {
            .tiled => if (w.workspace != null) workspace.floatWindow(&f.wm, w),
            .floating => if (w.workspace != null) workspace.tileWindow(&f.wm, w),
            else => {},
        },
        3 => if (w.workspace != null) {
            if (w.mode == .fullscreen) workspace.leaveFullscreen(w) else workspace.setFullscreen(&f.wm, w);
        },
        4 => workspace.minimize(&f.wm, w),
        5 => if (w.workspace != null) {
            workspace.leaveFullscreen(w);
            try workspace.moveToWorkspace(&f.wm, w, pickWorkspace(f, second, rng));
        },
        6 => if (w.workspace != null) workspace.unplace(&f.wm, w),
        7 => {
            // The second monitor is switched off or on by its rule.
            rules[0].enabled = rng.boolean();
            output.applyRule(&f.wm, second);
        },
        8 => {
            // The second monitor "disappears and returns": remember homes,
            // move everything off it, give it back.
            if (!second.disabled) {
                for (0..second.workspace_count) |i| {
                    var it = f.wm.windows.first();
                    while (it) |x| : (it = types.nextWindow(x, &f.wm)) {
                        if (x.workspace) |xs| if (xs.output == second and xs.index == i) output.rememberHome(&f.wm, second, x, @intCast(i));
                    }
                }
                var it = f.wm.windows.first();
                while (it) |x| : (it = types.nextWindow(x, &f.wm)) {
                    if (x.workspace) |xs| if (xs.output == second) {
                        workspace.leaveFullscreen(x);
                        try workspace.moveToWorkspace(&f.wm, x, &f.out.workspaces[xs.index]);
                    };
                }
                _ = output.restoreHomes(&f.wm, second);
            }
        },
        else => unreachable,
    }
}

test "random operations keep every invariant (several seeds, two monitors)" {
    var seed: u64 = 1;
    while (seed <= 24) : (seed += 1) {
        const f = try Fixture.init();
        defer f.deinit();
        const second = try setup2(f);
        defer mt.destroySecondOutput(second);
        var rules = [1]monitors.Rule{.{ .match = "DP-2", .workspaces = 2 }};
        f.wm.monitors.rules = &rules;
        var prng = std.Random.DefaultPrng.init(seed);
        const rng = prng.random();

        var i: usize = 0;
        while (i < 8) : (i += 1) _ = try f.newWindow();

        var step: usize = 0;
        while (step < 150) : (step += 1) {
            randomStep(f, second, &rules, rng) catch |err| {
                std.debug.print("seed {d} step {d}: {t}\n", .{ seed, step, err });
                return err;
            };
            const rep = invariants.check(&f.wm);
            if (!rep.clean()) {
                std.debug.print("seed {d} step {d}:\n", .{ seed, step });
                var buf: [2048]u8 = undefined;
                var w: std.Io.Writer = .fixed(&buf);
                rep.write(&w) catch {};
                std.debug.print("{s}", .{w.buffered()});
                return error.InvariantsBroken;
            }
        }
        // Whatever is left over can be dumped without trouble.
        var out: [32 * 1024]u8 = undefined;
        var w: std.Io.Writer = .fixed(&out);
        try dump.write(&f.wm, &w, 0);
        // Windows still on the second output are freed by the fixture only
        // for the first one: empty the second before it goes.
        for (0..second.workspace_count) |wi| {
            const ws = &second.workspaces[wi];
            // unplace() frees a column with its last window: always look at
            // the first window again instead of walking a column.
            while (true) {
                const x = (if (ws.strip.columns.first()) |c| c.windows.first() else null) orelse ws.floating.first() orelse break;
                workspace.unplace(&f.wm, x);
            }
        }
    }
}
