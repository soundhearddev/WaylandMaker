// SPDX-License-Identifier: GPL-3.0
//
// `zig build bench`: how long the window model takes under load.
//
// Builds synthetic window managers (dummy Wayland objects, nothing talks to a
// compositor) with 10, 100 and 1000 windows and times the operations that run
// on every manage sequence or on a user action:
//
//   layout        layout.compute of the shown workspace (follow on and off)
//   place         placing the windows one after the other
//   move          moving every window to another workspace
//   invariants    the invariant check (WMAKER_CHECKS=1 runs it every sequence)
//   outputs       monitor ordering and primary lookup with 16 monitors
//   monitors      profile and rule matching
//
// Every case runs many times; the table shows the mean, the 50th / 95th / 99th
// percentile and the worst run per call (perf.zig), in microseconds.
//
//   zig build bench -Doptimize=ReleaseFast            run and print
//   zig build bench -Doptimize=ReleaseFast -- --check  also fail when a case is over its budget
//   zig build bench -- --quick                         fewer repetitions
//   zig build bench -- --csv                           machine readable
//
// The budgets are generous (about ten times what a current laptop needs):
// they catch "the layout became quadratic", not a slow day. They only apply
// to optimized builds; a Debug build is much slower and is only printed.

const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");
const workspace = @import("workspace.zig");
const layout = @import("layout.zig");
const monitors = @import("monitors.zig");
const invariants = @import("invariants.zig");
const perf = @import("perf.zig");
const config = @import("config.zig");

var dummy_byte: u8 = 0;

const Model = struct {
    wm: types.WindowManager,
    outs: []*types.Output,
    wins: []*types.Window,

    fn init(gpa: std.mem.Allocator, n_outputs: usize, n_windows: usize) !*Model {
        const m = try gpa.create(Model);
        m.* = .{
            .wm = .{
                .gpa = gpa,
                .io = undefined,
                .cfg = .{ .arena = .init(gpa) },
                .obj = @ptrCast(&dummy_byte),
                .obj_version = 6,
                .outputs = undefined,
                .windows = undefined,
                .dock_windows = undefined,
                .seats = undefined,
            },
            .outs = try gpa.alloc(*types.Output, n_outputs),
            .wins = try gpa.alloc(*types.Window, n_windows),
        };
        m.wm.outputs.init();
        m.wm.windows.init();
        m.wm.dock_windows.init();
        m.wm.seats.init();
        m.wm.cfg.workspace_count = 4;
        for (m.outs, 0..) |*slot, i| {
            const o = try gpa.create(types.Output);
            o.* = .{ .obj = @ptrCast(&dummy_byte) };
            o.rect = .{ .x = @intCast(i * 1920), .y = 0, .w = 1920, .h = 1080 };
            o.workspace_count = 4;
            for (0..4) |w| o.workspaces[w].init(o, @intCast(w));
            m.wm.outputs.append(o);
            slot.* = o;
        }
        for (m.wins) |*slot| {
            const w = try gpa.create(types.Window);
            w.* = .{ .obj = @ptrCast(&dummy_byte), .node = @ptrCast(&dummy_byte) };
            w.ready = true;
            w.target = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
            m.wm.windows.append(w);
            slot.* = w;
        }
        return m;
    }

    fn deinit(m: *Model) void {
        const gpa = m.wm.gpa;
        for (m.outs) |o| {
            for (0..o.workspace_count) |i| {
                const ws = &o.workspaces[i];
                while (ws.strip.columns.first()) |c| {
                    while (c.windows.first()) |w| types.unlink(&w.column_link);
                    types.unlink(&c.link);
                    gpa.destroy(c);
                }
            }
            types.unlink(&o.link);
            gpa.destroy(o);
        }
        for (m.wins) |w| {
            types.unlink(&w.link);
            gpa.destroy(w);
        }
        gpa.free(m.outs);
        gpa.free(m.wins);
        m.wm.cfg.deinit();
        gpa.destroy(m);
    }

    /// Every window on the first workspace of the first output, `per_col` to a column.
    fn placeAll(m: *Model, per_col: usize) !void {
        const ws = &m.outs[0].workspaces[0];
        for (m.wins, 0..) |w, i| {
            try workspace.placeTiled(&m.wm, ws, w);
            if (per_col > 1 and i % per_col != 0) {
                // Fold into the column of the previous window: a stack.
                workspace.unplace(&m.wm, w);
                m.wm.cfg.new_window = .stack;
                try workspace.placeTiled(&m.wm, ws, w);
                m.wm.cfg.new_window = .new_column;
            }
        }
    }
};

// ---- measuring ---------------------------------------------------------------

const Case = struct {
    name: []const u8,
    n: usize,
    stat: perf.Stat,
    /// Mean budget in µs for optimized builds; 0: none.
    budget_us: u64,
};

var cases: std.ArrayList(Case) = .empty;
var gpa_state: std.mem.Allocator = undefined;

fn nowNs(io: std.Io) u64 {
    return perf.nowNs(io);
}

/// Run `f` `reps` times, each timed on its own, into a new case.
fn measure(io: std.Io, name: []const u8, n: usize, reps: usize, budget_us: u64, ctx: anytype, comptime f: anytype) !void {
    var st: perf.Stat = .{};
    var i: usize = 0;
    while (i < reps) : (i += 1) {
        const t0 = nowNs(io);
        try f(ctx);
        std.mem.doNotOptimizeAway(ctx);
        st.record(nowNs(io) - t0);
    }
    try cases.append(gpa_state, .{ .name = name, .n = n, .stat = st, .budget_us = budget_us });
}

fn repsFor(n: usize, quick: bool) usize {
    const base: usize = if (n >= 1000) 40 else if (n >= 100) 300 else 2000;
    return if (quick) @max(5, base / 10) else base;
}

// ---- the cases -----------------------------------------------------------------

const LayoutCtx = struct { m: *Model, follow: bool };

fn runLayout(c: LayoutCtx) !void {
    layout.compute(c.m.outs[0].ws(), &c.m.wm.cfg, c.follow);
}

const MoveCtx = struct { m: *Model, to: u32 };

fn runMove(c: *MoveCtx) !void {
    const out = c.m.outs[0];
    for (c.m.wins) |w| try workspace.moveToWorkspace(&c.m.wm, w, &out.workspaces[c.to]);
    c.to = (c.to + 1) % 4;
}

fn runCheck(m: *Model) !void {
    const rep = invariants.check(&m.wm);
    if (!rep.clean()) return error.InvariantsBroken;
}

const OutCtx = struct { m: *Model, sink: usize = 0 };

fn runOutputs(c: *OutCtx) !void {
    var buf: [monitors.max_monitors]*types.Output = undefined;
    const n = types.liveOutputs(&c.m.wm, &buf);
    c.sink +%= n;
    if (types.primaryOutput(&c.m.wm)) |p| c.sink +%= @intFromPtr(p) & 1;
    if (types.outputToward(&c.m.wm, c.m.outs[0], .right)) |o| c.sink +%= @intFromPtr(o) & 1;
}

const MonCtx = struct { infos: [8]monitors.Info, rules: [8]monitors.Rule, profiles: [4]monitors.Profile, sink: usize = 0 };

fn runMonitors(c: *MonCtx) !void {
    for (&c.infos) |*i| {
        if (monitors.findRule(&c.rules, i)) |r| c.sink +%= r.match.len;
    }
    if (monitors.pickProfile(&c.profiles, &c.infos)) |p| c.sink +%= p;
    c.sink +%= @intCast(monitors.Manager.setKey(&c.infos) & 1);
}

fn runCases(io: std.Io, gpa: std.mem.Allocator, quick: bool) !void {
    for ([_]usize{ 10, 100, 1000 }) |n| {
        const reps = repsFor(n, quick);

        // layout: one window per column, and stacks of four.
        {
            const m = try Model.init(gpa, 1, n);
            defer m.deinit();
            try m.placeAll(1);
            try measure(io, "layout columns, follow", n, reps, budget(n, 30, 4000), LayoutCtx{ .m = m, .follow = true }, runLayout);
            try measure(io, "layout columns", n, reps, budget(n, 30, 4000), LayoutCtx{ .m = m, .follow = false }, runLayout);
            try measure(io, "invariants", n, reps, budget(n, 60, 6000), m, runCheck);
        }
        {
            const m = try Model.init(gpa, 1, n);
            defer m.deinit();
            try m.placeAll(4);
            try measure(io, "layout stacks of 4", n, reps, budget(n, 30, 4000), LayoutCtx{ .m = m, .follow = true }, runLayout);
        }
        // placing and moving
        {
            const m = try Model.init(gpa, 1, n);
            defer m.deinit();
            var mv = MoveCtx{ .m = m, .to = 1 };
            try m.placeAll(1);
            try measure(io, "move all windows", n, @max(3, reps / 4), budget(n, 120, 15000), &mv, runMove);
        }
        {
            // Placement cost: build a fresh model each time (timed together
            // with the allocation, which is part of what a user sees).
            var st: perf.Stat = .{};
            var i: usize = 0;
            const rr = @max(3, reps / 10);
            while (i < rr) : (i += 1) {
                const m = try Model.init(gpa, 1, n);
                const t0 = nowNs(io);
                try m.placeAll(1);
                st.record(nowNs(io) - t0);
                m.deinit();
            }
            try cases.append(gpa, .{ .name = "place all windows", .n = n, .stat = st, .budget_us = budget(n, 60, 8000) });
        }
    }

    // Monitors: the number of windows does not matter, the number of outputs does.
    {
        const m = try Model.init(gpa, monitors.max_monitors, 0);
        defer m.deinit();
        var oc = OutCtx{ .m = m };
        try measure(io, "outputs: order+primary (16)", 16, if (quick) 200 else 5000, 400, &oc, runOutputs);
    }
    {
        var mc: MonCtx = .{ .infos = undefined, .rules = undefined, .profiles = undefined };
        for (&mc.infos, 0..) |*i, k| {
            i.* = .{};
            var nb: [16]u8 = undefined;
            i.name.set(std.fmt.bufPrint(&nb, "DP-{d}", .{k}) catch "DP");
            i.make.set("Acme");
            i.model.set("Display");
        }
        for (&mc.rules, 0..) |*r, k| {
            var nb: [16]u8 = undefined;
            const pat = std.fmt.bufPrint(&nb, "DP-{d}", .{k + 3}) catch "DP";
            r.* = .{ .match = try gpa.dupe(u8, pat) };
        }
        defer for (mc.rules) |r| gpa.free(r.match);
        const needs: []const []const u8 = &.{ "DP-0", "DP-1", "*" };
        for (&mc.profiles) |*p| p.* = .{ .name = "p", .needs = needs };
        try measure(io, "monitors: rules+profile (8)", 8, if (quick) 200 else 5000, 400, &mc, runMonitors);
    }
}

fn budget(n: usize, per_window_ns: u64, floor_us: u64) u64 {
    // About ten times the cost measured on a laptop, with a floor so that the
    // small cases do not fail on a noisy machine.
    return @max(floor_us, per_window_ns * 10 * n / 1000 + floor_us / 8);
}

// ---- output ----------------------------------------------------------------------

fn us(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1000.0;
}

fn printTable(w: *std.Io.Writer, csv: bool) !void {
    if (csv) {
        try w.writeAll("case,windows,runs,mean_us,p50_us,p95_us,p99_us,max_us\n");
        for (cases.items) |c| try w.print("{s},{d},{d},{d:.2},{d:.2},{d:.2},{d:.2},{d:.2}\n", .{
            c.name, c.n, c.stat.count, us(c.stat.meanNs()), us(c.stat.percentileNs(50)), us(c.stat.percentileNs(95)), us(c.stat.percentileNs(99)), us(c.stat.max_ns),
        });
        return;
    }
    try w.print("wmaker-wl model benchmark ({s} build); times per call in microseconds\n\n", .{@tagName(builtin.mode)});
    try w.print("{s:<30} {s:>7} {s:>6} {s:>11} {s:>11} {s:>11} {s:>11} {s:>11}\n", .{ "case", "n", "runs", "mean", "p50", "p95", "p99", "max" });
    for (cases.items) |c| try w.print("{s:<30} {d:>7} {d:>6} {d:>11.1} {d:>11.1} {d:>11.1} {d:>11.1} {d:>11.1}\n", .{
        c.name, c.n, c.stat.count, us(c.stat.meanNs()), us(c.stat.percentileNs(50)), us(c.stat.percentileNs(95)), us(c.stat.percentileNs(99)), us(c.stat.max_ns),
    });
}

/// Cases over their budget; prints them.
fn overBudget(w: *std.Io.Writer) !usize {
    var bad: usize = 0;
    for (cases.items) |c| {
        if (c.budget_us == 0) continue;
        const mean = us(c.stat.meanNs());
        if (mean > @as(f64, @floatFromInt(c.budget_us))) {
            bad += 1;
            try w.print("OVER BUDGET: {s} (n={d}): mean {d:.1} us, budget {d} us\n", .{ c.name, c.n, mean, c.budget_us });
        }
    }
    return bad;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    gpa_state = gpa;

    var quick = false;
    var csv = false;
    var check = false;
    var args = init.minimal.args.iterate();
    _ = args.next();
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--quick")) quick = true else if (std.mem.eql(u8, a, "--csv")) csv = true else if (std.mem.eql(u8, a, "--check")) check = true else {
            std.debug.print("bench: unknown argument `{s}` (--quick, --csv, --check)\n", .{a});
            std.process.exit(2);
        }
    }

    try runCases(io, gpa, quick);
    defer cases.deinit(gpa);

    var buf: [8192]u8 = undefined;
    var fw = std.Io.File.stdout().writer(io, &buf);
    const w = &fw.interface;
    try printTable(w, csv);
    if (check) {
        if (builtin.mode == .Debug) {
            try w.writeAll("\n--check: budgets only apply to optimized builds (-Doptimize=ReleaseFast); skipped.\n");
        } else {
            const bad = try overBudget(w);
            try w.flush();
            if (bad > 0) std.process.exit(1);
            try w.writeAll("\nall cases within budget\n");
        }
    }
    try w.flush();
}

// The benchmark's own sanity: a tiny run must produce numbers and a clean model.
test "bench: a small model is built, laid out and checked" {
    const m = try Model.init(std.testing.allocator, 2, 20);
    defer m.deinit();
    try m.placeAll(3);
    layout.compute(m.outs[0].ws(), &m.wm.cfg, true);
    try std.testing.expect(invariants.check(&m.wm).clean());
    var mv = MoveCtx{ .m = m, .to = 2 };
    try runMove(&mv);
    try std.testing.expect(invariants.check(&m.wm).clean());
}
