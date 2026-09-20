// SPDX-License-Identifier: 0BSD
//
// Commands: parsing of the text in `bind = Key, command args` and their
// execution. run() is only ever called from inside a manage sequence, so
// every window-management request an action needs is legal.
//
// Actions edit the model (workspace.zig) and record what they want in
// `focus_request`; main.zig then lays out, proposes dimensions and sends
// the focus in that order. Actions never talk to river directly, except
// for `close`, which is a plain request that is legal in manage.

const std = @import("std");

const types = @import("types.zig");
const config = @import("config.zig");
const layout = @import("layout.zig");
const workspace = @import("workspace.zig");
const proc = @import("process.zig");

const Command = types.Command;
const WindowManager = types.WindowManager;
const Window = types.Window;
const Strip = types.Strip;
const Output = types.Output;

/// Listener callbacks only get their own context, but a few (key
/// bindings) need the WindowManager. There is exactly one per process.
pub var global: ?*WindowManager = null;

/// Ask for focus on `win`. Safe from event callbacks: it only records the
/// wish and requests a manage sequence.
pub fn requestFocus(wm: *WindowManager, win: *Window) void {
    wm.focus_request = win;
    wm.follow_request = true;
    wm.obj.manageDirty();
}

// ----------------------------------------------------------------------------
// Parsing
// ----------------------------------------------------------------------------

pub const ParseError = error{ UnknownCommand, BadArguments, OutOfMemory };

/// Parse every configured bind's command text once at startup. Bad
/// commands become `.none` with a warning instead of aborting startup.
pub fn parseAll(a: std.mem.Allocator, cfg: *const config.Config) ![]const Command {
    const out = try a.alloc(Command, cfg.binds.len);
    for (cfg.binds, 0..) |b, i| {
        out[i] = parse(a, cfg, b.command) catch |err| blk: {
            std.log.warn("bind `{s}`: {t}", .{ b.command, err });
            break :blk .none;
        };
    }
    return out;
}

pub fn parse(a: std.mem.Allocator, cfg: *const config.Config, text: []const u8) ParseError!Command {
    var it = std.mem.tokenizeAny(u8, text, " \t");
    const name = it.next() orelse return error.UnknownCommand;
    const rest = std.mem.trim(u8, it.rest(), " \t");

    const eql = std.mem.eql;

    // Commands without arguments map 1:1 to union tags.
    inline for (@typeInfo(Command).@"union".fields) |f| {
        if (f.type == void and eql(u8, name, f.name)) {
            return @unionInit(Command, f.name, {});
        }
    }

    if (eql(u8, name, "spawn_terminal")) return .{ .spawn = cfg.terminal };
    if (eql(u8, name, "spawn_launcher")) return .{ .spawn = cfg.launcher };
    if (eql(u8, name, "spawn_browser")) return .{ .spawn = cfg.browser };
    if (eql(u8, name, "spawn")) {
        return .{ .spawn = config.parseCommand(a, rest) catch |e| return if (e == error.OutOfMemory)
            error.OutOfMemory
        else
            error.BadArguments };
    }

    if (eql(u8, name, "workspace")) return .{ .workspace = try workspaceArg(rest, cfg) };
    if (eql(u8, name, "move_to_workspace")) return .{ .move_to_workspace = try workspaceArg(rest, cfg) };

    if (eql(u8, name, "float_move")) {
        const p = try twoInts(rest);
        return .{ .float_move = .{ .dx = p[0], .dy = p[1] } };
    }
    if (eql(u8, name, "float_resize")) {
        const p = try twoInts(rest);
        return .{ .float_resize = .{ .dw = p[0], .dh = p[1] } };
    }

    return error.UnknownCommand;
}

/// Workspaces are 1-based in the config, 0-based internally.
fn workspaceArg(s: []const u8, cfg: *const config.Config) ParseError!u32 {
    const n = std.fmt.parseInt(u32, s, 10) catch return error.BadArguments;
    if (n < 1 or n > cfg.workspace_count) return error.BadArguments;
    return n - 1;
}

fn twoInts(s: []const u8) ParseError![2]i32 {
    var it = std.mem.tokenizeAny(u8, s, " \t");
    const a = it.next() orelse return error.BadArguments;
    const b = it.next() orelse return error.BadArguments;
    return .{
        std.fmt.parseInt(i32, a, 10) catch return error.BadArguments,
        std.fmt.parseInt(i32, b, 10) catch return error.BadArguments,
    };
}

// ----------------------------------------------------------------------------
// Execution
// ----------------------------------------------------------------------------

/// The output actions apply to: the one that holds the focused window,
/// otherwise the first.
fn currentOutput(wm: *WindowManager) ?*Output {
    if (wm.seats.first()) |s| {
        if (s.focused) |w| if (w.workspace) |ws| return ws.output;
    }
    return wm.outputs.first();
}

fn focusedWindow(wm: *WindowManager) ?*Window {
    const s = wm.seats.first() orelse return null;
    if (s.focused) |w| if (!w.closed and w.workspace != null) return w;
    const out = currentOutput(wm) orelse return null;
    return workspace.defaultFocus(out.ws());
}

pub fn run(wm: *WindowManager, cmd: Command) void {
    const out = currentOutput(wm) orelse return;
    const ws = out.ws();
    const strip = &ws.strip;
    const cfg = &wm.cfg;
    const work = out.workArea();

    switch (cmd) {
        .none => {},
        .spawn => |argv| proc.spawn(wm, argv),
        .exit => wm.quit = true,

        .close => if (focusedWindow(wm)) |w| w.obj.close(),

        // ---- mode changes ---------------------------------------------------
        .toggle_floating => if (focusedWindow(wm)) |w| toggleFloating(wm, w),

        .toggle_fullscreen => if (focusedWindow(wm)) |w| {
            if (w.mode == .fullscreen) {
                workspace.leaveFullscreen(w);
            } else {
                workspace.setFullscreen(wm, w);
            }
            wm.focus_request = w;
            wm.follow_request = true;
        },

        // Like niri's maximize-column: the focused window's column takes the
        // whole work area (inside the gaps); its neighbours are pushed off
        // to the sides. Not fullscreen. Pressing again restores the width.
        // A floating window has no column, so this does nothing for it.
        .maximize_column => {
            const w = focusedWindow(wm) orelse return;
            const col = w.column orelse return;
            workspace.toggleMaximized(wm, col);
            wm.follow_request = true;
        },

        // ---- focus ------------------------------------------------------------
        .focus_left => focusColumn(wm, strip, types.prevCol),
        .focus_right => focusColumn(wm, strip, types.nextCol),
        .focus_first_column => if (strip.columns.first()) |c| setActiveColumn(wm, strip, c),
        .focus_last_column => if (strip.columns.last()) |c| setActiveColumn(wm, strip, c),

        .focus_up => if (focusedWindow(wm)) |w| {
            if (w.mode == .floating) {
                focusFloatingStep(wm, w, .down);
            } else if (types.prevWin(w)) |t| focusWindow(wm, t);
        },
        .focus_down => if (focusedWindow(wm)) |w| {
            if (w.mode == .floating) {
                focusFloatingStep(wm, w, .up);
            } else if (types.nextWin(w)) |t| focusWindow(wm, t);
        },

        .focus_previous => if (wm.seats.first()) |s| {
            if (s.previous) |p| if (!p.closed and p.workspace != null) {
                switchToWindowWorkspace(wm, p);
                focusWindow(wm, p);
            };
        },

        // Jump between the tiled strip and the floating layer.
        .focus_toggle_floating => if (focusedWindow(wm)) |w| {
            if (w.mode == .floating) {
                if (strip.activeWindow()) |t| focusWindow(wm, t);
            } else if (ws.floating.last()) |t| focusWindow(wm, t);
        },

        // ---- moving columns / windows ----------------------------------------
        .move_column_left => if (workspace.moveColumn(strip, .left)) {
            wm.follow_request = true;
        },
        .move_column_right => if (workspace.moveColumn(strip, .right)) {
            wm.follow_request = true;
        },
        .move_column_first => if (workspace.moveColumn(strip, .first)) {
            wm.follow_request = true;
        },
        .move_column_last => if (workspace.moveColumn(strip, .last)) {
            wm.follow_request = true;
        },
        .move_window_up => if (strip.activeWindow()) |w| {
            _ = workspace.moveWindowVertical(w, .up);
        },
        .move_window_down => if (strip.activeWindow()) |w| {
            _ = workspace.moveWindowVertical(w, .down);
        },
        .consume_left => if (workspace.consumeLeft(wm, strip)) {
            wm.follow_request = true;
        },
        .expel_right => if (workspace.expelRight(wm, strip)) {
            wm.follow_request = true;
        },

        // ---- scrolling ---------------------------------------------------------
        .scroll_left => layout.scrollBy(strip, -@divTrunc(work.w, 3), work.w, cfg),
        .scroll_right => layout.scrollBy(strip, @divTrunc(work.w, 3), work.w, cfg),
        .center_column => if (strip.active) |c| layout.centerColumn(strip, c, work.w, cfg),

        // ---- column width ------------------------------------------------------
        .cycle_column_width => if (strip.active) |col| {
            col.unmaximized_width = 0;
            col.width = nextPreset(work.w, col.width, cfg);
            wm.follow_request = true;
        },
        .widen_column => resize(wm, strip, work.w, cfg.width_step, cfg),
        .narrow_column => resize(wm, strip, work.w, -cfg.width_step, cfg),

        // ---- floating geometry via keyboard ------------------------------------
        .float_move => |d| if (focusedWindow(wm)) |w| {
            if (w.mode == .floating) {
                w.float_rect.x += d.dx;
                w.float_rect.y += d.dy;
            }
        },
        .float_resize => |d| if (focusedWindow(wm)) |w| {
            if (w.mode == .floating) {
                const c = w.clampSize(w.float_rect.w + d.dw, w.float_rect.h + d.dh, cfg.min_window_size);
                w.float_rect.w = c.w;
                w.float_rect.h = c.h;
            }
        },

        // ---- workspaces --------------------------------------------------------
        .workspace => |i| switchWorkspace(wm, out, i),
        .workspace_next => switchWorkspace(wm, out, (out.active + 1) % out.workspace_count),
        .workspace_prev => switchWorkspace(wm, out, (out.active + out.workspace_count - 1) % out.workspace_count),
        .move_to_workspace => |i| sendToWorkspace(wm, out, i),
    }
}

// ----------------------------------------------------------------------------
// Helpers
// ----------------------------------------------------------------------------

/// Toggle between tiled and floating. Fullscreen is left first, because a
/// fullscreen window has to be a normal window again before it can change
/// layer.
pub fn toggleFloating(wm: *WindowManager, w: *Window) void {
    workspace.leaveFullscreen(w);
    switch (w.mode) {
        .tiled => workspace.floatWindow(wm, w),
        .floating => workspace.tileWindow(wm, w),
        .fullscreen => unreachable, // leaveFullscreen() above
    }
    workspace.activate(w);
    wm.focus_request = w;
    wm.follow_request = true;
}

fn focusWindow(wm: *WindowManager, w: *Window) void {
    workspace.activate(w);
    wm.focus_request = w;
    wm.follow_request = true;
}

fn setActiveColumn(wm: *WindowManager, strip: *Strip, col: *types.Column) void {
    strip.active = col;
    if (col.active()) |w| {
        workspace.activate(w);
        wm.focus_request = w;
    }
    wm.follow_request = true;
}

fn focusColumn(wm: *WindowManager, strip: *Strip, step: *const fn (*types.Column) ?*types.Column) void {
    const cur = strip.active orelse return;
    const target = step(cur) orelse return;
    setActiveColumn(wm, strip, target);
}

/// Floating windows are stacked bottom -> top; "up" moves toward the top.
fn focusFloatingStep(wm: *WindowManager, w: *Window, dir: enum { up, down }) void {
    const t = switch (dir) {
        .up => types.nextFloating(w),
        .down => types.prevFloating(w),
    } orelse return;
    focusWindow(wm, t);
}

fn nextPreset(work_w: i32, current: i32, cfg: *const config.Config) i32 {
    // First preset strictly wider than the current width, else wrap.
    for (cfg.width_presets) |f| {
        const w = layout.columnWidthFor(work_w, f, cfg);
        if (w > current + 2) return w;
    }
    return layout.columnWidthFor(work_w, cfg.width_presets[0], cfg);
}

fn resize(wm: *WindowManager, strip: *Strip, work_w: i32, step: f64, cfg: *const config.Config) void {
    const col = strip.active orelse return;
    col.unmaximized_width = 0;
    const full = layout.columnWidthFor(work_w, 1.0, cfg);
    const delta: i32 = @intFromFloat(@as(f64, @floatFromInt(full)) * step);
    col.width = std.math.clamp(col.width + delta, layout.minOuterWidth(cfg), full);
    wm.follow_request = true;
}

fn switchWorkspace(wm: *WindowManager, out: *Output, index: u32) void {
    if (index >= out.workspace_count or index == out.active) return;
    const from = out.ws();
    out.active = index;
    carryOmnipresent(wm, from, out.ws());
    wm.focus_request = workspace.defaultFocus(out.ws());
    wm.follow_request = true;
}

/// Window Maker's Omnipresent windows follow the user: move them from the
/// workspace being left to the one being entered.
fn carryOmnipresent(wm: *WindowManager, from: *types.Workspace, to: *types.Workspace) void {
    var it = from.floating.first();
    while (it) |w| {
        const next = types.nextFloating(w); // read before the window moves
        if (w.isOmnipresent()) {
            workspace.moveToWorkspace(wm, w, to) catch |err| {
                std.log.err("omnipresent window could not follow: {t}", .{err});
            };
        }
        it = next;
    }
}

/// Focusing a window on another workspace must show that workspace.
fn switchToWindowWorkspace(wm: *WindowManager, w: *Window) void {
    _ = wm;
    const ws = w.workspace orelse return;
    ws.output.active = ws.index;
}

fn sendToWorkspace(wm: *WindowManager, out: *Output, index: u32) void {
    if (index >= out.workspace_count or index == out.active) return;
    const w = focusedWindow(wm) orelse return;
    workspace.moveToWorkspace(wm, w, &out.workspaces[index]) catch |err| {
        std.log.err("move_to_workspace failed: {t}", .{err});
        return;
    };
    // The window leaves the visible workspace; focus what remains here.
    wm.focus_request = workspace.defaultFocus(out.ws());
    wm.follow_request = true;
}
