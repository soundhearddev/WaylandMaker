// SPDX-License-Identifier: GPL-3.0
//
// A readable picture of the whole window manager state, for bug reports.
//
// `pkill -USR1 wmaker-wl` writes it to the log (`info(dump)`) and to
// `$XDG_STATE_HOME/wmaker-wl/state-dump.txt` (else ~/.local/state/...):
// outputs and the monitors behind them, every workspace with its columns and
// windows, seats, the monitor rules in force, the perf table, the invariant
// check and the last log lines. Reads the model only; no Wayland requests.

const std = @import("std");
const types = @import("types.zig");
const monitors = @import("monitors.zig");
const invariants = @import("invariants.zig");
const perf = @import("perf.zig");
const trace = @import("trace.zig");
const version = @import("version.zig");

const WindowManager = types.WindowManager;
const Window = types.Window;
const Error = std.Io.Writer.Error;

pub fn write(wm: *WindowManager, w: *std.Io.Writer, log_lines: usize) Error!void {
    try w.print("wmaker-wl {s} state dump\n", .{version.version});
    try w.print("config: {s} ({d} warning(s))\n\n", .{ wm.cfg.config_file, wm.cfg.parse_warnings });
    try writeOutputs(wm, w);
    try writeMonitorPolicy(wm, w);
    try writeSeats(wm, w);
    try w.writeByte('\n');
    const rep = invariants.check(wm);
    try rep.write(w);
    try w.writeByte('\n');
    try perf.report(w);
    try w.writeByte('\n');
    try trace.dump(w, log_lines);
}

fn writeOutputs(wm: *WindowManager, w: *std.Io.Writer) Error!void {
    var n: usize = 0;
    var oit = wm.outputs.first();
    while (oit) |out| : (oit = types.nextOutput(out, wm)) {
        var lbl: [200]u8 = undefined;
        try w.print("output {d}: {s} {d}x{d}+{d}+{d}", .{ n, out.mon.label(&lbl), out.rect.w, out.rect.h, out.rect.x, out.rect.y });
        if (out.removed) try w.writeAll(" REMOVED");
        if (out.disabled) try w.writeAll(" disabled");
        if (out.primary) try w.writeAll(" primary");
        if (wm.active_output == out) try w.writeAll(" [working]");
        if (!out.settled) try w.writeAll(" (not settled)");
        try w.print("\n  key={x} wl_global={d} usable={s}\n", .{ out.mon.key(), out.wl_global, if (out.usable != null) "layer-shell" else "full" });
        var wi: u32 = 0;
        while (wi < out.workspace_count) : (wi += 1) {
            const ws = &out.workspaces[wi];
            if (ws.isEmpty() and wi != out.active) continue;
            try w.print("  workspace {d}{s}: {d} column(s), {d} floating\n", .{
                wi + 1, if (wi == out.active) " (shown)" else "", ws.strip.columnCount(), countFloating(ws),
            });
            var cit = ws.strip.columns.first();
            var ci: usize = 0;
            while (cit) |col| : ({
                cit = types.nextCol(col);
                ci += 1;
            }) {
                try w.print("    column {d}{s} width={d}{s}\n", .{ ci, if (ws.strip.active == col) "*" else "", col.width, if (col.isMaximized()) " maximized" else "" });
                var wit = col.windows.first();
                while (wit) |win| : (wit = types.nextWin(win)) try writeWindow(w, win, "      ");
            }
            var fit = ws.floating.first();
            while (fit) |win| : (fit = types.nextFloating(win)) try writeWindow(w, win, "    floating ");
        }
        n += 1;
    }
    if (n == 0) try w.writeAll("no outputs\n");
    // Windows that are on no workspace.
    var it = wm.windows.first();
    while (it) |win| : (it = types.nextWindow(win, wm)) {
        if (win.workspace == null) try writeWindow(w, win, "unplaced ");
    }
}

fn countFloating(ws: *types.Workspace) usize {
    var n: usize = 0;
    var it = ws.floating.first();
    while (it) |x| : (it = types.nextFloating(x)) n += 1;
    return n;
}

fn writeWindow(w: *std.Io.Writer, win: *Window, indent: []const u8) Error!void {
    try w.print("{s}{s} \"{s}\" {t}", .{ indent, if (win.app_id) |a| a else "(no app_id)", clip(win.title orelse ""), win.mode });
    try w.print(" {d}x{d}+{d}+{d}", .{ win.target.w, win.target.h, win.target.x, win.target.y });
    if (win.minimized) try w.writeAll(" minimized");
    if (win.closed) try w.writeAll(" closed");
    if (win.new) try w.writeAll(" new");
    if (win.home.isSet()) try w.print(" home={x}/ws{d}", .{ win.home.key, win.home.ws + 1 });
    try w.writeByte('\n');
}

fn clip(s: []const u8) []const u8 {
    return s[0..@min(s.len, 48)];
}

fn writeMonitorPolicy(wm: *WindowManager, w: *std.Io.Writer) Error!void {
    const m = &wm.monitors;
    try w.print("\nmonitors: order={t} settle={d}ms rules={d} profiles={d} changes={d} settled={d}{s}\n", .{
        m.order, m.settle.ms, m.rules.len, m.profiles.len, m.changes, m.settles, if (m.settle.pending()) " (change pending)" else "",
    });
    for (m.rules) |r| {
        try w.print("  rule \"{s}\": enabled={} primary={} workspaces={?d} restore_windows={}\n", .{ r.match, r.enabled, r.primary, r.workspaces, r.restore_windows });
    }
    if (m.last_profile) |i| if (i < m.profiles.len) try w.print("  last profile: {s}\n", .{m.profiles[i].name});
}

fn writeSeats(wm: *WindowManager, w: *std.Io.Writer) Error!void {
    var sit = wm.seats.first();
    var i: usize = 0;
    while (sit) |s| : (sit = types.nextSeat(s, wm)) {
        try w.print("seat {d}: focused=\"{s}\" op={t}/{t}{s}\n", .{
            i, if (s.focused) |f| (f.app_id orelse "?") else "-", s.op, s.op_state, if (s.removed) " REMOVED" else "",
        });
        i += 1;
    }
}
