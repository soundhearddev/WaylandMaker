// SPDX-License-Identifier: GPL-3.0
//
// `zig build bench`: how long the window model takes under load.
//
// This is a MODEL benchmark: synthetic window managers (dummy Wayland objects,
// nothing talks to a compositor, nothing is rendered) with 1, 10, 50, 100, 500
// and 1000 windows. It times the operations that run on every manage sequence
// or on a user action:
//
//   layout        layout.compute of the shown workspace (follow on and off),
//                 with one output and with windows spread over four
//   place         placing the windows one after the other
//   move          moving every window to another workspace
//   invariants    the invariant check (WMAKER_CHECKS=1 runs it every sequence)
//   outputs       monitor ordering and primary lookup with 16 monitors
//   monitors      profile and rule matching
//   animation     motion.visualState for every window, as one animated frame
//                 asks for it: all windows moving (a spring restarts on every
//                 call) and all at rest (the common case while only one window
//                 changes)
//
// What it does NOT measure: real clients, frame times, missed deadlines,
// rendering, the Dock, the requests sent to the clients. Numbers from here say "the model is not the
// problem" or "the model became quadratic", nothing about what a user sees.
//
// How a number is made (so that it can be trusted, or not):
//
//   * Each case is run `warm-up` times untimed, then timed call by call (or,
//     for calls too short to time one by one, in batches: the table says
//     how many calls to a batch). The timer's own cost is measured at the
//     start and printed; a case whose median is within a few timer costs
//     and is not batched is marked `*`.
//   * The whole set is run `--repeat` times (default 3); the table shows all
//     samples together and `spread` = how far apart the per-run means were.
//     A big spread means a noisy machine, not a slow model.
//   * A percentile is only printed when there are enough samples for it to be
//     more than the maximum in disguise (p50: 10, p95: 20, p99: 100); else `-`.
//   * `allocs` and `bytes` are what ONE call allocates (a counting allocator
//     under the model), so a hot path that starts allocating shows up.
//   * `!` after the maximum: it is more than ten times the p99, i.e. an
//     outlier (page fault, scheduler), not the typical cost.
//
//   zig build bench -Doptimize=ReleaseFast             run and print
//   zig build bench -- --check                         also fail when a case is over its budget
//   zig build bench -- --quick                         fewer repetitions (1 run)
//   zig build bench -- --repeat N --warmup N           runs of the whole set, warm-up calls per case
//   zig build bench -- --csv | --json                  machine readable
//   zig build bench -- --json --out dump/new.json      write to a file instead of stdout
//   zig build bench -- --baseline dump/old.json        compare with an earlier --json run,
//                                                      exit 1 on a regression (--threshold PCT, default 50)
//
// The budgets are generous (about ten times what a current laptop needs):
// they catch "the layout became quadratic", not a slow day. They only apply
// to optimized builds; a Debug build is much slower and is only printed.
// A baseline is only meaningful from the SAME machine and build mode.

const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");
const workspace = @import("workspace.zig");
const layout = @import("layout.zig");
const monitors = @import("monitors.zig");
const invariants = @import("invariants.zig");
const perf = @import("perf.zig");
const motion = @import("motion.zig");
const config = @import("config.zig");
const fileutil = @import("fileutil.zig");

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
        defer m.wm.cfg.new_window = .new_column;
        for (m.wins, 0..) |w, i| {
            // Every window is placed once: the first of each group opens a
            // column, the others join the active one (a stack). (This used
            // to place every window as a new column first, take it out
            // again and place it a second time.)
            m.wm.cfg.new_window = if (per_col > 1 and i % per_col != 0) .stack else .new_column;
            try workspace.placeTiled(&m.wm, ws, w);
        }
    }

    /// The windows dealt out over all outputs, one column each (a window per
    /// column is the case the layout is slowest at).
    fn placeSpread(m: *Model) !void {
        defer m.wm.cfg.new_window = .new_column;
        m.wm.cfg.new_window = .new_column;
        for (m.wins, 0..) |w, i| {
            const out = m.outs[i % m.outs.len];
            try workspace.placeTiled(&m.wm, &out.workspaces[0], w);
        }
    }
};

// ---- counting allocations ------------------------------------------------------

/// Counts what the model asks the allocator for. The benchmark builds its
/// models on top of one of these and reads the counters around a single call.
const Counting = struct {
    backing: std.mem.Allocator,
    allocs: u64 = 0,
    bytes: u64 = 0,

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn allocator(c: *Counting) std.mem.Allocator {
        return .{ .ptr = c, .vtable = &vtable };
    }

    fn from(ctx: *anyopaque) *Counting {
        return @ptrCast(@alignCast(ctx));
    }

    fn reset(c: *Counting) void {
        c.allocs = 0;
        c.bytes = 0;
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const c = from(ctx);
        const p = c.backing.rawAlloc(len, alignment, ret_addr) orelse return null;
        c.allocs += 1;
        c.bytes += len;
        return p;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const c = from(ctx);
        if (!c.backing.rawResize(memory, alignment, new_len, ret_addr)) return false;
        if (new_len > memory.len) c.bytes += new_len - memory.len;
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const c = from(ctx);
        const p = c.backing.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        c.allocs += 1;
        c.bytes += new_len;
        return p;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        from(ctx).backing.rawFree(memory, alignment, ret_addr);
    }
};

var counting: Counting = undefined;

// ---- measuring ---------------------------------------------------------------

/// Fewest samples for which a percentile says more than the maximum does.
const min_samples_p50: usize = 10;
const min_samples_p95: usize = 20;
const min_samples_p99: usize = 100;

/// A call shorter than this is timed in batches: the clock read costs tens of
/// nanoseconds, which would be most of what a 100 ns call "takes".
const batch_below_ns: u64 = 2_000;
const batch_target_ns: u64 = 10_000;
const batch_max: usize = 4096;

/// A case is marked `*` when its median is less than this many timer costs
/// and it was not batched.
const timer_bound_factor: u64 = 10;

/// One run of one case.
const Case = struct {
    name: []const u8,
    n: usize,
    /// Which pass over the whole set (--repeat) this is from.
    run: usize,
    stat: perf.Stat,
    /// Every single timed sample in ns per call, sorted. perf.Stat's histogram
    /// rounds a percentile up to the top of a power-of-two bucket of
    /// microseconds (and never above the maximum), so below 2 us it reports
    /// the maximum for p50, p95 and p99 alike -- useless for the sub-microsecond
    /// cases of an optimized build. The percentiles in the table come from here.
    samples: []u64,
    /// Calls to one timed sample (1: every call timed on its own).
    batch: usize = 1,
    /// What one call allocated (count, bytes).
    allocs: u64 = 0,
    alloc_bytes: u64 = 0,
    /// Mean budget in µs for optimized builds; 0: none.
    budget_us: u64,
};

var cases: std.ArrayList(Case) = .empty;
var gpa_state: std.mem.Allocator = undefined;

const Opts = struct {
    quick: bool = false,
    csv: bool = false,
    json: bool = false,
    check: bool = false,
    repeat: usize = 3,
    /// null: a tenth of the repetitions, 3 to 100.
    warmup: ?usize = null,
    out: ?[]const u8 = null,
    baseline: ?[]const u8 = null,
    threshold_pct: f64 = 50,
};

var run_index: usize = 0;
var timer_overhead_ns: u64 = 0;

fn nowNs(io: std.Io) u64 {
    return perf.nowNs(io);
}

/// Nearest-rank percentile of sorted samples (ns).
fn pct(sorted: []const u64, p: usize) u64 {
    if (sorted.len == 0) return 0;
    const rank = @max(1, (sorted.len * p + 99) / 100);
    return sorted[rank - 1];
}

/// The percentile, or null when there are too few samples for it to mean
/// anything (the p99 of 40 samples is just the largest of them).
fn pctReliable(sorted: []const u64, p: usize) ?u64 {
    const need: usize = switch (p) {
        0...50 => min_samples_p50,
        51...95 => min_samples_p95,
        else => min_samples_p99,
    };
    if (sorted.len < need) return null;
    return pct(sorted, p);
}

/// The cost of one `nowNs` call as seen by a timed section: the median of
/// the difference between two back-to-back reads.
fn measureTimerOverhead(io: std.Io) u64 {
    var d: [1001]u64 = undefined;
    for (&d) |*slot| {
        const t0 = nowNs(io);
        const t1 = nowNs(io);
        slot.* = t1 -| t0;
    }
    std.mem.sort(u64, &d, {}, std.sort.asc(u64));
    return d[d.len / 2];
}

/// Sort the samples and file the case. On success it owns `samples` (the
/// caller's `errdefer` frees them if this fails).
fn addCase(c: Case) !void {
    var k = c;
    std.mem.sort(u64, k.samples, {}, std.sort.asc(u64));
    k.run = run_index;
    try cases.append(gpa_state, k);
}

fn freeCases() void {
    for (cases.items) |c| gpa_state.free(c.samples);
    cases.deinit(gpa_state);
}

/// How many calls make one timed sample, from the fastest of a few trial calls.
fn batchFor(io: std.Io, ctx: anytype, comptime f: anytype) !usize {
    var best: u64 = std.math.maxInt(u64);
    for (0..5) |_| {
        const t0 = nowNs(io);
        try f(ctx);
        best = @min(best, nowNs(io) -| t0);
    }
    if (best >= batch_below_ns) return 1;
    const per = @max(best -| timer_overhead_ns, 1);
    return @min(batch_max, @max(2, batch_target_ns / per));
}

/// Run `f` `reps` times, each timed on its own (or in batches for very short
/// calls), into a new case.
fn measure(io: std.Io, o: Opts, name: []const u8, n: usize, reps: usize, budget_us: u64, ctx: anytype, comptime f: anytype) !void {
    // Untimed calls first: the first ones pay for cold caches and page
    // faults, which showed up as an outlier in `max`.
    const warm = o.warmup orelse std.math.clamp(reps / 10, 3, 100);
    for (0..warm) |_| try f(ctx);

    // What one call allocates: one more call with the counter running.
    counting.reset();
    try f(ctx);
    const allocs = counting.allocs;
    const bytes = counting.bytes;

    const batch = try batchFor(io, ctx, f);
    const samples = try gpa_state.alloc(u64, reps);
    errdefer gpa_state.free(samples);
    var st: perf.Stat = .{};
    for (samples) |*slot| {
        const t0 = nowNs(io);
        for (0..batch) |_| try f(ctx);
        std.mem.doNotOptimizeAway(ctx);
        const dt = nowNs(io) -| t0;
        const per_call = if (batch == 1) dt else (dt + batch / 2) / batch;
        slot.* = per_call;
        st.record(per_call);
    }
    try addCase(.{ .name = name, .n = n, .run = 0, .stat = st, .samples = samples, .batch = batch, .allocs = allocs, .alloc_bytes = bytes, .budget_us = budget_us });
}

const Weight = enum { cheap, heavy };

/// Timed repetitions of one case. At least a thousand where that is
/// practical: the cheap cases always, the heavy ones (placing or moving every
/// window, which takes milliseconds at 1000 windows) fewer with many windows.
fn repsFor(n: usize, quick: bool, weight: Weight) usize {
    const base: usize = switch (weight) {
        .cheap => 1000,
        .heavy => if (n >= 1000) 100 else if (n >= 500) 300 else 1000,
    };
    return if (quick) @max(10, base / 10) else base;
}

/// The window counts. 1 and 50 are there to see the scaling between the
/// decades, 500 for where a plain loop starts to cost.
const window_counts = [_]usize{ 1, 10, 50, 100, 500, 1000 };

// ---- the cases -----------------------------------------------------------------

const LayoutCtx = struct { m: *Model, follow: bool };

fn runLayout(c: LayoutCtx) !void {
    layout.compute(c.m.outs[0].ws(), &c.m.wm.cfg, c.follow);
}

/// The layout of every output (windows spread over them), as a manage pass does.
fn runLayoutAll(c: LayoutCtx) !void {
    for (c.m.outs) |o| layout.compute(o.ws(), &c.m.wm.cfg, c.follow);
}

const AnimCtx = struct { m: *Model, phase: i32 = 0, moving: bool };

/// What an animated frame does for every window: ask `visualState` where it
/// is drawn. `moving`: the destination changes before every call, so each
/// window starts a new spring; else the windows have arrived and the call
/// only has to see that nothing moves.
fn runVisual(c: *AnimCtx) !void {
    if (c.moving) {
        c.phase = 1 - c.phase;
        for (c.m.wins) |w| w.target.x = c.phase * 200;
    }
    var sink: i32 = 0;
    for (c.m.wins) |w| {
        const v = motion.visualState(&c.m.wm, w);
        sink +%= v.x +% v.y;
    }
    std.mem.doNotOptimizeAway(sink);
}

/// Place the windows and run one pass, so that `has_shown` and the
/// workspace they were shown on are set: from then on `visualState` animates.
fn animSetup(m: *Model, moving: bool) !AnimCtx {
    try m.placeAll(1);
    m.wm.cfg.animations = true;
    for (m.wins) |w| w.opened = true; // no open animation: only movement is measured
    var c: AnimCtx = .{ .m = m, .moving = false };
    try runVisual(&c);
    c.moving = moving;
    return c;
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

fn runCases(io: std.Io, gpa: std.mem.Allocator, o: Opts) !void {
    const mgpa = counting.allocator();
    for (window_counts) |n| {
        const cheap = repsFor(n, o.quick, .cheap);
        const heavy = repsFor(n, o.quick, .heavy);

        // layout: one window per column, and stacks of four.
        {
            const m = try Model.init(mgpa, 1, n);
            defer m.deinit();
            try m.placeAll(1);
            try measure(io, o, "layout columns, follow", n, cheap, budget(n, 30, 40), LayoutCtx{ .m = m, .follow = true }, runLayout);
            try measure(io, o, "layout columns", n, cheap, budget(n, 30, 40), LayoutCtx{ .m = m, .follow = false }, runLayout);
            try measure(io, o, "invariants", n, cheap, budget(n, 60, 60), m, runCheck);
        }
        {
            const m = try Model.init(mgpa, 1, n);
            defer m.deinit();
            try m.placeAll(4);
            try measure(io, o, "layout stacks of 4", n, cheap, budget(n, 30, 40), LayoutCtx{ .m = m, .follow = true }, runLayout);
        }
        // Animation: every window asks `visualState` once, as in a frame.
        {
            const m = try Model.init(mgpa, 1, n);
            defer m.deinit();
            var ac = try animSetup(m, true);
            try measure(io, o, "animation: all windows moving", n, cheap, budget(n, 200, 40), &ac, runVisual);
        }
        {
            const m = try Model.init(mgpa, 1, n);
            defer m.deinit();
            var ac = try animSetup(m, false);
            try measure(io, o, "animation: all windows at rest", n, cheap, budget(n, 60, 40), &ac, runVisual);
        }
        // The same windows over four outputs: what a manage pass lays out on
        // a multi-monitor desk (the work per window is the same, the number of
        // strips and the cache behaviour are not).
        {
            const m = try Model.init(mgpa, 4, n);
            defer m.deinit();
            try m.placeSpread();
            try measure(io, o, "layout 4 outputs, follow", n, cheap, budget(n, 30, 80), LayoutCtx{ .m = m, .follow = true }, runLayoutAll);
        }
        // placing and moving
        {
            const m = try Model.init(mgpa, 1, n);
            defer m.deinit();
            var mv = MoveCtx{ .m = m, .to = 1 };
            try m.placeAll(1);
            try measure(io, o, "move all windows", n, heavy, budget(n, 120, 150), &mv, runMove);
        }
        {
            // Placement cost: a fresh model each time, because placing needs
            // unplaced windows. Only the placing is timed (columns are
            // allocated in it), not building the model. Warm-up and the
            // allocation count are done the same way.
            const warm = o.warmup orelse std.math.clamp(heavy / 10, 3, 100);
            for (0..warm) |_| {
                const m = try Model.init(mgpa, 1, n);
                defer m.deinit();
                try m.placeAll(1);
            }
            var allocs: u64 = 0;
            var bytes: u64 = 0;
            {
                const m = try Model.init(mgpa, 1, n);
                defer m.deinit();
                counting.reset();
                try m.placeAll(1);
                allocs = counting.allocs;
                bytes = counting.bytes;
            }
            var st: perf.Stat = .{};
            const samples = try gpa.alloc(u64, heavy);
            errdefer gpa.free(samples);
            for (samples) |*slot| {
                const m = try Model.init(mgpa, 1, n);
                defer m.deinit();
                const t0 = nowNs(io);
                try m.placeAll(1);
                const dt = nowNs(io) -| t0;
                slot.* = dt;
                st.record(dt);
            }
            try addCase(.{ .name = "place all windows", .n = n, .run = 0, .stat = st, .samples = samples, .allocs = allocs, .alloc_bytes = bytes, .budget_us = budget(n, 60, 80) });
        }
    }

    // Monitors: the number of windows does not matter, the number of outputs does.
    const short = if (o.quick) @as(usize, 200) else 5000;
    {
        const m = try Model.init(mgpa, monitors.max_monitors, 0);
        defer m.deinit();
        var oc = OutCtx{ .m = m };
        try measure(io, o, "outputs: order+primary", monitors.max_monitors, short, 400, &oc, runOutputs);
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
        try measure(io, o, "monitors: rules+profile", 8, short, 400, &mc, runMonitors);
    }
}

fn budget(n: usize, per_window_ns: u64, base_us: u64) u64 {
    // About ten times the cost per window measured on a laptop, plus a small
    // fixed part so that the small cases do not fail on a noisy machine.
    // (The fixed part used to be a floor of 4-15 ms: `@max(floor, ...)` was
    // always the floor, so no budget depended on `n` and a layout that had
    // become quadratic, ~1 ms at 1000 windows, would have passed.)
    return base_us + per_window_ns * 10 * n / 1000;
}

// ---- putting the runs together -----------------------------------------------------

/// One row of the result: a case over all `--repeat` runs.
const Row = struct {
    name: []const u8,
    n: usize,
    /// All samples of all runs, sorted.
    samples: []u64,
    runs: usize,
    mean_ns: u64,
    max_ns: u64,
    /// How far apart the per-run means were, in percent of the smallest.
    spread_pct: f64,
    batch: usize,
    allocs: u64,
    alloc_bytes: u64,
    budget_us: u64,
};

fn freeRows(rows: []Row) void {
    for (rows) |r| gpa_state.free(r.samples);
    gpa_state.free(rows);
}

/// Cases with the same name and window count, in the order they first appeared.
fn buildRows() ![]Row {
    var rows: std.ArrayList(Row) = .empty;
    errdefer {
        for (rows.items) |r| gpa_state.free(r.samples);
        rows.deinit(gpa_state);
    }
    for (cases.items, 0..) |c, i| {
        // Only the first case of a (name, n) group starts a row.
        var first = true;
        for (cases.items[0..i]) |p| {
            if (p.n == c.n and std.mem.eql(u8, p.name, c.name)) first = false;
        }
        if (!first) continue;

        var total_samples: usize = 0;
        var total_ns: u64 = 0;
        var count: u64 = 0;
        var max_ns: u64 = 0;
        var lo: u64 = std.math.maxInt(u64);
        var hi: u64 = 0;
        var nruns: usize = 0;
        for (cases.items[i..]) |p| {
            if (p.n != c.n or !std.mem.eql(u8, p.name, c.name)) continue;
            total_samples += p.samples.len;
            total_ns +%= p.stat.total_ns;
            count += p.stat.count;
            max_ns = @max(max_ns, p.stat.max_ns);
            const mean = p.stat.meanNs();
            lo = @min(lo, mean);
            hi = @max(hi, mean);
            nruns += 1;
        }
        const all = try gpa_state.alloc(u64, total_samples);
        errdefer gpa_state.free(all);
        var at: usize = 0;
        for (cases.items[i..]) |p| {
            if (p.n != c.n or !std.mem.eql(u8, p.name, c.name)) continue;
            @memcpy(all[at..][0..p.samples.len], p.samples);
            at += p.samples.len;
        }
        std.mem.sort(u64, all, {}, std.sort.asc(u64));
        const spread: f64 = if (nruns > 1 and lo > 0)
            @as(f64, @floatFromInt(hi - lo)) * 100.0 / @as(f64, @floatFromInt(lo))
        else
            0;
        try rows.append(gpa_state, .{
            .name = c.name,
            .n = c.n,
            .samples = all,
            .runs = nruns,
            .mean_ns = if (count == 0) 0 else total_ns / count,
            .max_ns = max_ns,
            .spread_pct = spread,
            .batch = c.batch,
            .allocs = c.allocs,
            .alloc_bytes = c.alloc_bytes,
            .budget_us = c.budget_us,
        });
    }
    return rows.toOwnedSlice(gpa_state);
}

/// Max is more than ten times the p99: one bad sample, not the typical cost.
fn isOutlier(r: Row) bool {
    const p99 = pct(r.samples, 99);
    return p99 > 0 and r.max_ns > p99 * 10;
}

/// Not batched and so short that the clock read is a large part of it.
fn isTimerBound(r: Row) bool {
    return r.batch == 1 and pct(r.samples, 50) < timer_overhead_ns * timer_bound_factor;
}

// ---- output ----------------------------------------------------------------------

fn us(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1000.0;
}

fn usOpt(ns: ?u64) ?f64 {
    return if (ns) |v| us(v) else null;
}

/// A table cell: the number, or `-` when it is not reliable.
fn cell(w: *std.Io.Writer, width: usize, v: ?f64) !void {
    var b: [32]u8 = undefined;
    const text = if (v) |x| std.fmt.bufPrint(&b, "{d:.2}", .{x}) catch "?" else "-";
    try w.splatByteAll(' ', width -| text.len);
    try w.writeAll(text);
}

fn cpuName() []const u8 {
    return builtin.cpu.model.name;
}

fn printMeta(w: *std.Io.Writer, o: Opts) !void {
    try w.print("wmaker-wl MODEL benchmark: not a compositor measurement\n", .{});
    try w.print("build {s}, zig {s}, {s}-{s}, cpu {s}\n", .{ @tagName(builtin.mode), builtin.zig_version_string, @tagName(builtin.cpu.arch), @tagName(builtin.os.tag), cpuName() });
    try w.print("{d} run(s) of the whole set{s}, warm-up {s}, timer overhead about {d} ns per read\n", .{
        o.repeat,
        if (o.quick) " (--quick)" else "",
        if (o.warmup) |_| "set by --warmup" else "a tenth of the repetitions (3 to 100 calls)",
        timer_overhead_ns,
    });
    try w.print("times per call in microseconds; `-`: too few samples for that percentile; `*` timer-bound; `!` outlier max\n\n", .{});
}

fn printTable(w: *std.Io.Writer, rows: []const Row, o: Opts) !void {
    if (o.csv) {
        try w.writeAll("case,windows,samples,batch,mean_us,p50_us,p95_us,p99_us,max_us,spread_pct,allocs,alloc_bytes\n");
        for (rows) |r| {
            try w.print("{s},{d},{d},{d},{d:.2},", .{ r.name, r.n, r.samples.len, r.batch, us(r.mean_ns) });
            for ([_]usize{ 50, 95, 99 }) |p| {
                if (usOpt(pctReliable(r.samples, p))) |v| try w.print("{d:.2},", .{v}) else try w.writeAll(",");
            }
            try w.print("{d:.2},{d:.1},{d},{d}\n", .{ us(r.max_ns), r.spread_pct, r.allocs, r.alloc_bytes });
        }
        return;
    }
    try printMeta(w, o);
    try w.print("{s:<28} {s:>5} {s:>7} {s:>8} {s:>9} {s:>9} {s:>9} {s:>10} {s:>7} {s:>7} {s:>9}\n", .{ "case", "n", "samples", "mean", "p50", "p95", "p99", "max", "spread%", "allocs", "bytes" });
    var any_bound = false;
    var any_outlier = false;
    for (rows) |r| {
        try w.print("{s:<28} {d:>5} {d:>7} ", .{ r.name, r.n, r.samples.len });
        try cell(w, 8, us(r.mean_ns));
        try w.writeAll(" ");
        try cell(w, 9, usOpt(pctReliable(r.samples, 50)));
        try w.writeAll(" ");
        try cell(w, 9, usOpt(pctReliable(r.samples, 95)));
        try w.writeAll(" ");
        try cell(w, 9, usOpt(pctReliable(r.samples, 99)));
        try w.writeAll(" ");
        try cell(w, 9, us(r.max_ns));
        const out = isOutlier(r);
        const bound = isTimerBound(r);
        try w.writeAll(if (out) "!" else " ");
        any_outlier = any_outlier or out;
        any_bound = any_bound or bound;
        try w.print(" {d:>6.1}{s} {d:>7} {d:>9}\n", .{ r.spread_pct, if (bound) "*" else " ", r.allocs, r.alloc_bytes });
    }
    if (any_bound) try w.writeAll("\n*  the median is within a few timer reads: treat it as an upper bound.\n");
    if (any_outlier) try w.writeAll("!  the maximum is over ten times the p99: look at p99 for the typical worst case.\n");
}

fn writeJsonString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |ch| switch (ch) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        0...0x1f => try w.print("\\u{x:0>4}", .{ch}),
        else => try w.writeByte(ch),
    };
    try w.writeByte('"');
}

fn jsonOpt(w: *std.Io.Writer, v: ?f64) !void {
    if (v) |x| try w.print("{d:.3}", .{x}) else try w.writeAll("null");
}

fn printJson(w: *std.Io.Writer, rows: []const Row, o: Opts) !void {
    try w.writeAll("{\n  \"meta\": {\n    \"kind\": \"model\",\n    \"mode\": ");
    try writeJsonString(w, @tagName(builtin.mode));
    try w.writeAll(",\n    \"zig\": ");
    try writeJsonString(w, builtin.zig_version_string);
    try w.writeAll(",\n    \"arch\": ");
    try writeJsonString(w, @tagName(builtin.cpu.arch));
    try w.writeAll(",\n    \"os\": ");
    try writeJsonString(w, @tagName(builtin.os.tag));
    try w.writeAll(",\n    \"cpu\": ");
    try writeJsonString(w, cpuName());
    try w.print(",\n    \"repeat\": {d},\n    \"quick\": {s},\n    \"timer_overhead_ns\": {d}\n  }},\n  \"cases\": [\n", .{ o.repeat, if (o.quick) "true" else "false", timer_overhead_ns });
    for (rows, 0..) |r, i| {
        try w.writeAll("    {\"name\": ");
        try writeJsonString(w, r.name);
        try w.print(", \"n\": {d}, \"samples\": {d}, \"batch\": {d}, \"mean_us\": {d:.3}, \"p50_us\": ", .{ r.n, r.samples.len, r.batch, us(r.mean_ns) });
        try jsonOpt(w, usOpt(pctReliable(r.samples, 50)));
        try w.writeAll(", \"p95_us\": ");
        try jsonOpt(w, usOpt(pctReliable(r.samples, 95)));
        try w.writeAll(", \"p99_us\": ");
        try jsonOpt(w, usOpt(pctReliable(r.samples, 99)));
        try w.print(", \"max_us\": {d:.3}, \"spread_pct\": {d:.1}, \"allocs\": {d}, \"alloc_bytes\": {d}}}{s}\n", .{ us(r.max_ns), r.spread_pct, r.allocs, r.alloc_bytes, if (i + 1 < rows.len) "," else "" });
    }
    try w.writeAll("  ]\n}\n");
}

/// Cases over their budget; prints them.
fn overBudget(w: *std.Io.Writer, rows: []const Row) !usize {
    var bad: usize = 0;
    for (rows) |r| {
        if (r.budget_us == 0) continue;
        const mean = us(r.mean_ns);
        if (mean > @as(f64, @floatFromInt(r.budget_us))) {
            bad += 1;
            try w.print("OVER BUDGET: {s} (n={d}): mean {d:.1} us, budget {d} us\n", .{ r.name, r.n, mean, r.budget_us });
        }
    }
    return bad;
}

// ---- comparing with an earlier run ---------------------------------------------------

/// The part of a `--json` file that a comparison needs.
const BaseCase = struct { name: []const u8, n: usize, mean_us: f64 };
const BaseFile = struct { cases: []const BaseCase };

/// A case got slower when its mean is over `threshold_pct` percent above the
/// baseline AND the difference is more than this (timer noise below that).
const regression_floor_us: f64 = 1.0;

fn isRegression(base_us: f64, now_us: f64, threshold_pct: f64) bool {
    if (now_us - base_us <= regression_floor_us) return false;
    return now_us > base_us * (1.0 + threshold_pct / 100.0);
}

/// Print every case that regressed against `base`; returns how many. Cases
/// missing from the baseline are skipped (a new case is not a regression).
fn compareBaseline(w: *std.Io.Writer, rows: []const Row, base: BaseFile, threshold_pct: f64) !usize {
    var bad: usize = 0;
    for (rows) |r| {
        for (base.cases) |b| {
            if (b.n != r.n or !std.mem.eql(u8, b.name, r.name)) continue;
            const now_us = us(r.mean_ns);
            if (isRegression(b.mean_us, now_us, threshold_pct)) {
                bad += 1;
                try w.print("REGRESSION: {s} (n={d}): mean {d:.2} us, baseline {d:.2} us (+{d:.0}%)\n", .{ r.name, r.n, now_us, b.mean_us, (now_us / b.mean_us - 1.0) * 100.0 });
            }
            break;
        }
    }
    return bad;
}

const c_io = @cImport({
    @cInclude("stdio.h");
});

fn writeFile(path: []const u8, data: []const u8) !void {
    const z = try gpa_state.dupeZ(u8, path);
    defer gpa_state.free(z);
    const f = c_io.fopen(z.ptr, "wb") orelse return error.CannotWrite;
    defer _ = c_io.fclose(f);
    if (c_io.fwrite(data.ptr, 1, data.len, f) != data.len) return error.CannotWrite;
}

fn parseArgs(init: std.process.Init) Opts {
    var o: Opts = .{};
    var args = init.minimal.args.iterate();
    _ = args.next();
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--quick")) {
            o.quick = true;
            o.repeat = 1;
        } else if (std.mem.eql(u8, a, "--csv")) {
            o.csv = true;
        } else if (std.mem.eql(u8, a, "--json")) {
            o.json = true;
        } else if (std.mem.eql(u8, a, "--check")) {
            o.check = true;
        } else if (std.mem.eql(u8, a, "--repeat")) {
            o.repeat = numArg(&args, a, 1, 100);
        } else if (std.mem.eql(u8, a, "--warmup")) {
            o.warmup = numArg(&args, a, 0, 100_000);
        } else if (std.mem.eql(u8, a, "--threshold")) {
            o.threshold_pct = @floatFromInt(numArg(&args, a, 1, 10_000));
        } else if (std.mem.eql(u8, a, "--out")) {
            o.out = args.next() orelse usage(a);
        } else if (std.mem.eql(u8, a, "--baseline")) {
            o.baseline = args.next() orelse usage(a);
        } else usage(a);
    }
    return o;
}

fn numArg(args: anytype, flag: []const u8, lo: usize, hi: usize) usize {
    const text = args.next() orelse usage(flag);
    const v = std.fmt.parseInt(usize, text, 10) catch usage(flag);
    if (v < lo or v > hi) usage(flag);
    return v;
}

fn usage(bad: []const u8) noreturn {
    std.debug.print(
        "bench: bad or incomplete argument `{s}`\n" ++
            "  --quick  --csv  --json  --check  --repeat N  --warmup N\n" ++
            "  --out FILE  --baseline FILE  --threshold PCT\n",
        .{bad},
    );
    std.process.exit(2);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    gpa_state = gpa;
    counting = .{ .backing = gpa };

    const o = parseArgs(init);

    timer_overhead_ns = measureTimerOverhead(io);
    defer freeCases(); // before the runs: a failing case still frees what it filed
    for (0..o.repeat) |r| {
        run_index = r;
        try runCases(io, gpa, o);
    }

    const rows = try buildRows();
    defer freeRows(rows);

    var buf: [8192]u8 = undefined;
    var fw = std.Io.File.stdout().writer(io, &buf);
    const w = &fw.interface;

    // The table or the JSON: to stdout, or with --out to a file.
    if (o.out) |path| {
        var alloc: std.Io.Writer.Allocating = .init(gpa);
        defer alloc.deinit();
        if (o.json) try printJson(&alloc.writer, rows, o) else try printTable(&alloc.writer, rows, o);
        writeFile(path, alloc.written()) catch {
            std.debug.print("bench: cannot write {s} (does its directory exist?)\n", .{path});
            std.process.exit(2);
        };
        try w.print("wrote {s}\n", .{path});
    } else if (o.json) {
        try printJson(w, rows, o);
    } else {
        try printTable(w, rows, o);
    }

    var failed = false;
    if (o.check) {
        if (builtin.mode == .Debug) {
            try w.writeAll("\n--check: budgets only apply to optimized builds (-Doptimize=ReleaseFast); skipped.\n");
        } else {
            const bad = try overBudget(w, rows);
            if (bad > 0) failed = true else try w.writeAll("\nall cases within budget\n");
        }
    }
    if (o.baseline) |path| {
        const z = try gpa.dupeZ(u8, path);
        defer gpa.free(z);
        const text = fileutil.readSmallFile(gpa, z) orelse {
            try w.print("\n--baseline: cannot read {s}\n", .{path});
            try w.flush();
            std.process.exit(2);
        };
        defer gpa.free(text);
        const parsed = std.json.parseFromSlice(BaseFile, gpa, text, .{ .ignore_unknown_fields = true }) catch {
            try w.print("\n--baseline: {s} is not a --json result of this benchmark\n", .{path});
            try w.flush();
            std.process.exit(2);
        };
        defer parsed.deinit();
        const bad = try compareBaseline(w, rows, parsed.value, o.threshold_pct);
        if (bad > 0) failed = true else try w.print("\nno regression against {s} (threshold {d:.0}%)\n", .{ path, o.threshold_pct });
    }
    try w.flush();
    if (failed) std.process.exit(1);
}

// The benchmark's own sanity: a tiny run must produce numbers and a clean model.
test "bench: a small model is built, laid out and checked" {
    const m = try Model.init(std.testing.allocator, 2, 20);
    defer m.deinit();
    try m.placeAll(3);
    // 20 windows, three to a column: seven columns (six of three, one of two).
    // Without this the "stacks of 4" case could silently measure single columns.
    try std.testing.expectEqual(@as(usize, 7), m.outs[0].workspaces[0].strip.columns.length());
    try std.testing.expectEqual(config.NewWindowMode.new_column, m.wm.cfg.new_window);
    layout.compute(m.outs[0].ws(), &m.wm.cfg, true);
    try std.testing.expect(invariants.check(&m.wm).clean());
    var mv = MoveCtx{ .m = m, .to = 2 };
    try runMove(&mv);
    try std.testing.expect(invariants.check(&m.wm).clean());
}

test "bench: percentiles need enough samples" {
    var few: [9]u64 = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9 };
    try std.testing.expect(pctReliable(&few, 50) == null);
    var ten: [10]u64 = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    try std.testing.expectEqual(@as(?u64, 5), pctReliable(&ten, 50));
    try std.testing.expect(pctReliable(&ten, 95) == null);
    try std.testing.expect(pctReliable(&ten, 99) == null);
    var hundred: [100]u64 = undefined;
    for (&hundred, 0..) |*s, i| s.* = i + 1;
    try std.testing.expectEqual(@as(?u64, 99), pctReliable(&hundred, 99));
    try std.testing.expectEqual(@as(?u64, 95), pctReliable(&hundred, 95));
}

test "bench: the counting allocator counts allocations and bytes" {
    var c: Counting = .{ .backing = std.testing.allocator };
    const a = c.allocator();
    const p = try a.alloc(u8, 100);
    const q = try a.alloc(u32, 4);
    try std.testing.expectEqual(@as(u64, 2), c.allocs);
    try std.testing.expectEqual(@as(u64, 116), c.bytes);
    a.free(p);
    a.free(q);
    c.reset();
    try std.testing.expectEqual(@as(u64, 0), c.allocs);
}

test "bench: a regression needs both a relative and an absolute change" {
    try std.testing.expect(!isRegression(100, 120, 50)); // +20%
    try std.testing.expect(isRegression(100, 200, 50)); // +100%
    try std.testing.expect(!isRegression(0.2, 0.9, 50)); // +350% but under a microsecond: noise
    try std.testing.expect(!isRegression(100, 50, 50)); // faster
}

test "bench: a baseline file is read and compared" {
    const gpa = std.testing.allocator;
    const text =
        \\{"meta": {"kind": "model", "extra": 1}, "cases": [
        \\  {"name": "layout columns", "n": 10, "mean_us": 10.0, "p50_us": null},
        \\  {"name": "invariants", "n": 10, "mean_us": 5.0, "p50_us": 4.0}
        \\]}
    ;
    const parsed = try std.json.parseFromSlice(BaseFile, gpa, text, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.value.cases.len);

    var samples = [_]u64{20_000} ** 10;
    const rows = [_]Row{
        .{ .name = "layout columns", .n = 10, .samples = &samples, .runs = 1, .mean_ns = 20_000, .max_ns = 20_000, .spread_pct = 0, .batch = 1, .allocs = 0, .alloc_bytes = 0, .budget_us = 0 },
        .{ .name = "invariants", .n = 10, .samples = &samples, .runs = 1, .mean_ns = 5_500, .max_ns = 5_500, .spread_pct = 0, .batch = 1, .allocs = 0, .alloc_bytes = 0, .budget_us = 0 },
        .{ .name = "new case", .n = 10, .samples = &samples, .runs = 1, .mean_ns = 999_000, .max_ns = 999_000, .spread_pct = 0, .batch = 1, .allocs = 0, .alloc_bytes = 0, .budget_us = 0 },
    };
    var sink: std.Io.Writer.Allocating = .init(gpa);
    defer sink.deinit();
    const bad = try compareBaseline(&sink.writer, &rows, parsed.value, 50);
    try std.testing.expectEqual(@as(usize, 1), bad); // only the first doubled; the new case has no baseline
    try std.testing.expect(std.mem.indexOf(u8, sink.written(), "layout columns") != null);
}

test "bench: the JSON output is valid JSON and has the cases" {
    const gpa = std.testing.allocator;
    var samples = [_]u64{ 1000, 2000, 3000, 4000, 5000, 6000, 7000, 8000, 9000, 10000 };
    const rows = [_]Row{
        .{ .name = "a \"quoted\" name", .n = 3, .samples = &samples, .runs = 1, .mean_ns = 5500, .max_ns = 10000, .spread_pct = 1.5, .batch = 1, .allocs = 2, .alloc_bytes = 64, .budget_us = 0 },
    };
    var sink: std.Io.Writer.Allocating = .init(gpa);
    defer sink.deinit();
    timer_overhead_ns = 30;
    try printJson(&sink.writer, &rows, .{});
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, sink.written(), .{});
    defer parsed.deinit();
    const cs = parsed.value.object.get("cases").?.array;
    try std.testing.expectEqual(@as(usize, 1), cs.items.len);
    try std.testing.expectEqualStrings("a \"quoted\" name", cs.items[0].object.get("name").?.string);
    // 10 samples: p50 is there, p95 and p99 are not.
    try std.testing.expect(cs.items[0].object.get("p50_us").? != .null);
    try std.testing.expect(cs.items[0].object.get("p99_us").? == .null);
}

test "bench: runs of the same case are put together into one row" {
    const gpa = std.testing.allocator;
    gpa_state = gpa;
    cases = .empty;
    defer freeCases();
    timer_overhead_ns = 30;
    for (0..3) |r| {
        const s = try gpa.alloc(u64, 4);
        for (s, 0..) |*x, i| x.* = (@as(u64, r) + 1) * 1000 + i;
        var st: perf.Stat = .{};
        for (s) |x| st.record(x);
        run_index = r;
        try addCase(.{ .name = "x", .n = 7, .run = 0, .stat = st, .samples = s, .budget_us = 0 });
    }
    const rows = try buildRows();
    defer freeRows(rows);
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqual(@as(usize, 12), rows[0].samples.len);
    try std.testing.expectEqual(@as(usize, 3), rows[0].runs);
    try std.testing.expect(rows[0].spread_pct > 100); // 1000 vs 3000 per call
}
