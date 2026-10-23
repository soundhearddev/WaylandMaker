// SPDX-License-Identifier: GPL-3.0
//
// The data-model invariants (types.zig, I1..I5), checked on a live model.
//
// model_test.zig checks them after every operation of a test; this does the
// same for the running window manager: with WMAKER_CHECKS=1 main.zig runs
// `check` after every manage sequence and logs what is wrong as `err(check)`.
// A broken invariant is the kind of bug that shows up much later as a crash
// (a dangling column, a window in two lists), so the first sequence that
// breaks it is the one worth knowing about.
//
// `check` allocates nothing: violations go into a fixed list (the first
// `max_violations`; `total` counts all of them). Every list walk is capped, so
// a corrupted (circular) list is reported instead of hanging the session.

const std = @import("std");
const types = @import("types.zig");
const config = @import("config.zig");

const Window = types.Window;
const Workspace = types.Workspace;
const WindowManager = types.WindowManager;

pub const max_violations = 24;
pub const msg_len = 140;
/// No list is longer than this; more means it is circular.
const walk_cap = 1 << 20;

pub const Report = struct {
    n: usize = 0,
    total: usize = 0,
    msgs: [max_violations][msg_len]u8 = undefined,
    lens: [max_violations]u8 = undefined,

    pub fn clean(r: *const Report) bool {
        return r.total == 0;
    }

    pub fn message(r: *const Report, i: usize) []const u8 {
        return r.msgs[i][0..r.lens[i]];
    }

    fn add(r: *Report, comptime fmt: []const u8, args: anytype) void {
        r.total += 1;
        if (r.n == max_violations) return;
        var w: std.Io.Writer = .fixed(&r.msgs[r.n]);
        w.print(fmt, args) catch {};
        r.lens[r.n] = @intCast(w.buffered().len);
        r.n += 1;
    }

    pub fn write(r: *const Report, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (r.clean()) return w.writeAll("invariants: all hold\n");
        try w.print("invariants: {d} violation(s)\n", .{r.total});
        for (0..r.n) |i| try w.print("  - {s}\n", .{r.message(i)});
        if (r.total > r.n) try w.print("  ... and {d} more\n", .{r.total - r.n});
    }
};

pub fn check(wm: *WindowManager) Report {
    var r: Report = .{};
    checkOutputs(wm, &r);
    checkWindows(wm, &r);
    checkDockWindows(wm, &r);
    checkSeats(wm, &r);
    return r;
}

fn checkOutputs(wm: *WindowManager, r: *Report) void {
    var oi: usize = 0;
    var oit = wm.outputs.first();
    var active_found = wm.active_output == null;
    var tiled_total: usize = 0;
    var floating_total: usize = 0;
    while (oit) |out| : (oit = types.nextOutput(out, wm)) {
        oi += 1;
        if (oi > walk_cap) return r.add("output list is circular", .{});
        if (wm.active_output == out) active_found = true;
        if (out.workspace_count < 1 or out.workspace_count > config.max_workspaces) {
            r.add("output {d}: workspace_count {d} out of range", .{ oi - 1, out.workspace_count });
            continue;
        }
        if (out.active >= out.workspace_count) r.add("output {d}: active workspace {d} >= count {d}", .{ oi - 1, out.active, out.workspace_count });
        if (out.prev_active) |p| if (p >= out.workspace_count) r.add("output {d}: prev_active {d} >= count {d}", .{ oi - 1, p, out.workspace_count });
        var wi: u32 = 0;
        while (wi < out.workspace_count) : (wi += 1) {
            checkWorkspace(&out.workspaces[wi], out, wi, r, &tiled_total, &floating_total);
        }
    }
    if (!active_found) r.add("wm.active_output is not in the output list", .{});

    // Every placed window of wm.windows was seen exactly once above.
    var placed: usize = 0;
    var n: usize = 0;
    var it = wm.windows.first();
    while (it) |w| : (it = types.nextWindow(w, wm)) {
        n += 1;
        if (n > walk_cap) return r.add("window list is circular", .{});
        if (w.workspace != null) placed += 1;
    }
    if (placed != tiled_total + floating_total) {
        r.add("{d} placed windows, but {d} tiled + {d} floating found in the workspaces", .{ placed, tiled_total, floating_total });
    }
}

fn checkWorkspace(ws: *Workspace, out: *types.Output, wi: u32, r: *Report, tiled_total: *usize, floating_total: *usize) void {
    if (ws.output != out) r.add("workspace {d}: output back-pointer is wrong", .{wi});
    if (ws.index != wi) r.add("workspace {d}: index says {d}", .{ wi, ws.index });
    if (ws.strip.workspace != ws) r.add("workspace {d}: strip back-pointer is wrong", .{wi});

    var active_is_member = ws.strip.active == null;
    var members_fullscreen = ws.fullscreen == null;
    var cn: usize = 0;
    var cit = ws.strip.columns.first();
    while (cit) |col| : (cit = types.nextCol(col)) {
        cn += 1;
        if (cn > walk_cap) return r.add("workspace {d}: column list is circular", .{wi});
        if (ws.strip.active == col) active_is_member = true;
        if (col.strip != &ws.strip) r.add("workspace {d}: column {d} has the wrong strip", .{ wi, cn - 1 });
        if (col.windows.empty()) r.add("workspace {d}: column {d} is empty (I4)", .{ wi, cn - 1 });
        if (col.width <= 0) r.add("workspace {d}: column {d} width {d}", .{ wi, cn - 1, col.width });
        var focused_member = col.focused == null;
        var wn: usize = 0;
        var wit = col.windows.first();
        while (wit) |w| : (wit = types.nextWin(w)) {
            wn += 1;
            if (wn > walk_cap) return r.add("workspace {d}: window list of column {d} is circular", .{ wi, cn - 1 });
            tiled_total.* += 1;
            if (col.focused == w) focused_member = true;
            if (ws.fullscreen == w) members_fullscreen = true;
            if (w.column != col) r.add("workspace {d}: a window's column pointer is wrong", .{wi});
            if (w.workspace != ws) r.add("workspace {d}: a tiled window points at another workspace", .{wi});
            if (!(w.mode == .tiled or (w.mode == .fullscreen and w.restore == .tiled))) r.add("workspace {d}: a window in a column has mode {t}", .{ wi, w.mode });
            if (types.isLinked(&w.floating_link)) r.add("workspace {d}: a tiled window is also linked as floating (I2)", .{wi});
            if (w.role != .normal) r.add("workspace {d}: a DockApp is in a strip (I1)", .{wi});
        }
        if (!focused_member) r.add("workspace {d}: column {d} focuses a window that is not in it", .{ wi, cn - 1 });
    }
    if (!active_is_member) r.add("workspace {d}: strip.active is not one of its columns", .{wi});

    var fn_: usize = 0;
    var fit = ws.floating.first();
    while (fit) |w| : (fit = types.nextFloating(w)) {
        fn_ += 1;
        if (fn_ > walk_cap) return r.add("workspace {d}: floating list is circular", .{wi});
        floating_total.* += 1;
        if (ws.fullscreen == w) members_fullscreen = true;
        if (w.workspace != ws) r.add("workspace {d}: a floating window points at another workspace", .{wi});
        if (w.column != null or types.isLinked(&w.column_link)) r.add("workspace {d}: a floating window is also in a column (I2)", .{wi});
        if (!(w.mode == .floating or (w.mode == .fullscreen and w.restore == .floating))) r.add("workspace {d}: a floating window has mode {t}", .{ wi, w.mode });
    }
    if (!members_fullscreen) r.add("workspace {d}: fullscreen window is in no container", .{wi});
    if (ws.fullscreen) |f| if (f.mode != .fullscreen) r.add("workspace {d}: ws.fullscreen has mode {t}", .{ wi, f.mode });
    if (ws.last_focused) |lf| if (lf.workspace != ws) r.add("workspace {d}: last_focused is a window of another workspace", .{wi});
}

fn checkWindows(wm: *WindowManager, r: *Report) void {
    var it = wm.windows.first();
    while (it) |w| : (it = types.nextWindow(w, wm)) {
        if (w.role != .normal) r.add("a DockApp is in wm.windows (I1)", .{});
        if (w.workspace == null) {
            // I3: not placed anywhere.
            if (w.column != null or types.isLinked(&w.column_link) or types.isLinked(&w.floating_link)) {
                r.add("an unplaced window is still linked into a container (I3)", .{});
            }
        } else if (w.workspace) |ws| {
            if (ws.output.removed and !w.closed) r.add("a window sits on a removed output", .{});
        }
    }
}

fn checkDockWindows(wm: *WindowManager, r: *Report) void {
    var n: usize = 0;
    var it = wm.dock_windows.first();
    while (it) |w| : (it = types.nextDockWindow(w, wm)) {
        n += 1;
        if (n > walk_cap) return r.add("dock window list is circular", .{});
        if (w.role != .dockapp) r.add("a normal window is in wm.dock_windows (I1)", .{});
        if (w.workspace != null or w.column != null) r.add("a DockApp is placed on a workspace (I1)", .{});
        if (types.isLinked(&w.column_link) or types.isLinked(&w.floating_link)) r.add("a DockApp is linked into a container (I1)", .{});
    }
}

fn checkSeats(wm: *WindowManager, r: *Report) void {
    var sit = wm.seats.first();
    while (sit) |s| : (sit = types.nextSeat(s, wm)) {
        for ([_]?*Window{ s.focused, s.previous, s.hovered, s.op_window }) |maybe| {
            const w = maybe orelse continue;
            if (!inList(wm, w)) r.add("a seat refers to a window that is in no list (dangling)", .{});
        }
    }
}

fn inList(wm: *WindowManager, w: *Window) bool {
    var it = wm.windows.first();
    while (it) |x| : (it = types.nextWindow(x, wm)) if (x == w) return true;
    var dit = wm.dock_windows.first();
    while (dit) |x| : (dit = types.nextDockWindow(x, wm)) if (x == w) return true;
    return false;
}
