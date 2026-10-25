// SPDX-License-Identifier: GPL-3.0
//
// Commands: parsing of the text in `bind = Key, command args` and their
// execution. run() is only ever called from inside a manage sequence, so
// every window-management request an action needs is legal.
//
// Actions edit the model (workspace.zig) and record what they want in
// `focus_request`; main.zig then lays out, proposes dimensions and sends
// the focus in that order. Actions never talk to the compositor directly, except
// for `close`, which is a plain request that is legal in manage.

const std = @import("std");
const log = std.log.scoped(.action);

const types = @import("types.zig");
const config = @import("config.zig");
const layout = @import("layout.zig");
const workspace = @import("workspace.zig");
const proc = @import("process.zig");
const backend = @import("backend.zig");

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
    requestFocusFollow(wm, win, true);
}

/// `requestFocus`, with the choice whether the view scrolls to the window
/// (`focus_follows_mouse_scroll = false` asks for no scrolling).
pub fn requestFocusFollow(wm: *WindowManager, win: *Window, follow: bool) void {
    // Hovering or clicking a DockApp (the clock in the Dock) must not touch
    // the focus -- and not set follow_request either, which would scroll
    // the strip back to the focused window under the user's hands.
    if (win.attrs.is("unfocusable")) return;
    wm.focus_request = win;
    if (follow) wm.follow_request = true;
    wm.focus_by_pointer = true;
    backend.manageDirty(wm.obj);
}

/// What `run("workspace 2")`, `spawn("foot")` and `shell("...")` do inside a
/// Lua function of config.lua: the same commands as a key binding's text.
/// (Set as `config.runner` at start-up.)
pub fn runFromLua(text: []const u8) void {
    const wm = global orelse return;
    // A function calling `run("lua N")` could loop for ever.
    if (std.mem.startsWith(u8, std.mem.trimStart(u8, text, " \t"), "lua")) {
        log.warn("config.lua: run() cannot start a Lua function", .{});
        return;
    }
    var arena: std.heap.ArenaAllocator = .init(wm.gpa);
    defer arena.deinit();
    const cmd = parse(arena.allocator(), &wm.cfg, text) catch |err| {
        log.warn("config.lua: bad command `{s}`: {t}", .{ text, err });
        return;
    };
    run(wm, cmd);
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
            log.warn("bind `{s}`: {t}", .{ b.command, err });
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

    // `shell`/`exec`/`shexec` (alias for the same thing) run the rest of
    // the line through `/bin/sh -c`, verbatim -- no word-splitting or
    // quote handling on our side, the shell does that. This is the
    // "bind any key to any command" escape hatch: pipes, `&&`, `~`/`$VAR`
    // expansion, backgrounding with `&`, multiple commands, all work.
    //
    //   bind = Super+p, shell grim -g "$(slurp)" ~/Pictures/shot.png
    //   bind = Super+l, shell swaylock -f || pkill swaylock
    //   bind = Super+m, shell playerctl play-pause &
    if (eql(u8, name, "shell") or eql(u8, name, "exec") or eql(u8, name, "shexec")) {
        if (rest.len == 0) return error.BadArguments;
        return .{ .shell = try a.dupe(u8, rest) };
    }

    // `lua N`: written by config.zig for `bind(combo, function)`, not by hand.
    if (eql(u8, name, "lua")) {
        return .{ .lua = std.fmt.parseInt(i32, rest, 10) catch return error.BadArguments };
    }

    if (eql(u8, name, "workspace")) return .{ .workspace = try workspaceArg(rest, cfg) };
    if (eql(u8, name, "move_to_workspace")) return .{ .move_to_workspace = try workspaceArg(rest, cfg) };

    if (eql(u8, name, "set_column_width")) return .{ .set_column_width = try fractionArg(rest) };

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
    _ = cfg;
    // Up to the maximum: a workspace that does not exist yet is created when
    // the command runs (modular workspaces).
    if (n < 1 or n > config.max_workspaces) return error.BadArguments;
    return n - 1;
}

/// `0.5` or `50%`: a fraction of the work area, more than 0 and at most 1.
fn fractionArg(s: []const u8) ParseError!f64 {
    const t = std.mem.trim(u8, s, " \t");
    const pct = std.mem.endsWith(u8, t, "%");
    const num = if (pct) t[0 .. t.len - 1] else t;
    const v = std.fmt.parseFloat(f64, std.mem.trim(u8, num, " \t")) catch return error.BadArguments;
    const f = if (pct) v / 100.0 else v;
    if (!(f > 0 and f <= 1.0)) return error.BadArguments;
    return f;
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
    return types.workingOutput(wm);
}

fn focusedWindow(wm: *WindowManager) ?*Window {
    // No seat yet (start-up) or nothing focused: the workspace's own idea of
    // its active window is the best answer.
    if (wm.seats.first()) |s| {
        if (s.focused) |w| if (!w.closed and w.workspace != null) return w;
    }
    const out = currentOutput(wm) orelse return null;
    return workspace.defaultFocus(out.ws());
}

pub fn run(wm: *WindowManager, cmd: Command) void {
    log.debug("run {s}", .{@tagName(cmd)});
    const out = currentOutput(wm) orelse return;
    const ws = out.ws();
    const strip = &ws.strip;
    const cfg = &wm.cfg;
    const work = out.workArea();

    switch (cmd) {
        .none => {},
        .spawn => |argv| proc.spawn(wm, argv),
        .shell => |sh| proc.spawnShell(wm, sh),
        .lua => |ref| config.callLua(cfg, ref),
        .exit => wm.quit = true,

        .close => if (focusedWindow(wm)) |w| backend.closeWindow(w.obj),

        // ---- minimize / hide (Window Maker's miniaturize, HIDE, HIDE_OTHERS) ---
        .minimize => if (focusedWindow(wm)) |w| {
            workspace.minimize(wm, w);
            // The next window gets the focus (see resolveFocus); the strip
            // follows it.
            wm.follow_request = true;
        },
        .hide_app => if (focusedWindow(wm)) |w| {
            hideMatching(wm, w, .same_app);
            wm.follow_request = true;
        },
        .hide_others => if (focusedWindow(wm)) |w| {
            hideMatching(wm, w, .other_apps);
            wm.follow_request = true;
        },
        // The Dock follows in the same sequence (main.onManage 6b).
        .toggle_mini_dock => wm.cfg.mini_dock = !wm.cfg.mini_dock,
        // ---- several monitors -----------------------------------------------------
        .focus_output_next => focusOutput(wm, out, true),
        .focus_output_prev => focusOutput(wm, out, false),
        .move_to_output_next => moveToOutput(wm, out, true),
        .move_to_output_prev => moveToOutput(wm, out, false),

        .restore => if (workspace.lastMinimized(wm)) |w| restoreWindow(wm, w, out),
        .show_all => showAll(wm, out),

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

        // Maximize column: the focused window's column takes the
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

        // Floating windows: previous / next in the order they were opened (a
        // stable order: stepping through the z-order would only swap the top
        // two windows, because focusing one raises it).
        .focus_up => if (focusedWindow(wm)) |w| {
            if (w.mode == .floating) {
                focusFloatingStep(wm, w, false);
            } else if (types.prevWin(w)) |t| focusWindow(wm, t);
        },
        .focus_down => if (focusedWindow(wm)) |w| {
            if (w.mode == .floating) {
                focusFloatingStep(wm, w, true);
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
        .workspace => |i| {
            // A workspace that does not exist yet is created (modular workspaces).
            if (i >= out.workspace_count) _ = workspace.setWorkspaceCount(wm, out, i + 1);
            if (i == out.active and cfg.workspace_back_and_forth) {
                if (out.prev_active) |p| switchWorkspace(wm, out, p);
            } else switchWorkspace(wm, out, i);
        },
        .workspace_last => if (out.prev_active) |p| switchWorkspace(wm, out, p),
        .workspace_add => if (!workspace.addWorkspace(wm, out)) {
            log.warn("workspace_add: already {d} workspaces", .{out.workspace_count});
        },
        .workspace_remove_last => if (workspace.removeLastWorkspace(wm, out)) {
            wm.focus_request = workspace.defaultFocus(out.ws());
            wm.follow_request = true;
        },
        .move_to_workspace_next, .move_to_workspace_prev => {
            const fwd = cmd == .move_to_workspace_next;
            const target = stepWorkspace(cfg, out, fwd) orelse return;
            const w = focusedWindow(wm) orelse return;
            w.home = .{}; // moved on purpose: it no longer belongs to the monitor it was taken from
            workspace.moveToWorkspace(wm, w, &out.workspaces[target]) catch |err| {
                log.err("move window to workspace failed: {t}", .{err});
                return;
            };
            switchWorkspace(wm, out, target);
            workspace.activate(w);
            wm.focus_request = w;
        },
        .focus_window_or_workspace_up => if (focusedWindow(wm)) |w| {
            if (w.mode != .floating and types.prevWin(w) != null) {
                focusWindow(wm, types.prevWin(w).?);
            } else if (stepWorkspace(cfg, out, false)) |t| switchWorkspace(wm, out, t);
        },
        .focus_window_or_workspace_down => if (focusedWindow(wm)) |w| {
            if (w.mode != .floating and types.nextWin(w) != null) {
                focusWindow(wm, types.nextWin(w).?);
            } else if (stepWorkspace(cfg, out, true)) |t| switchWorkspace(wm, out, t);
        },
        .focus_column_or_output_left => if (strip.active != null and types.prevCol(strip.active.?) != null) {
            focusColumn(wm, strip, types.prevCol);
        } else focusOutput(wm, out, false),
        .focus_column_or_output_right => if (strip.active != null and types.nextCol(strip.active.?) != null) {
            focusColumn(wm, strip, types.nextCol);
        } else focusOutput(wm, out, true),
        .set_column_width => |f| if (strip.active) |col| {
            col.unmaximized_width = 0;
            col.width = layout.columnWidthFor(work.w, f, cfg);
            wm.follow_request = true;
        },
        .reload_config => wm.reload_pending = true,
        // `workspace_wrap = false`: stop at the last / first workspace.
        .workspace_next => if (stepWorkspace(cfg, out, true)) |t| switchWorkspace(wm, out, t),
        .workspace_prev => if (stepWorkspace(cfg, out, false)) |t| switchWorkspace(wm, out, t),
        .move_to_workspace => |i| sendToWorkspace(wm, out, i),
    }
}

// ----------------------------------------------------------------------------
// Helpers
// ----------------------------------------------------------------------------

/// Work on the next/previous output. Focus goes to the window that was
/// active there, or nowhere if the output is empty: the point is that the
/// next workspace/spawn/move command then applies to THAT output.
fn focusOutput(wm: *WindowManager, from: *Output, forward: bool) void {
    const target = types.cycleOutput(wm, from, forward) orelse return;
    if (target == from) return;
    wm.active_output = target;
    wm.focus_request = workspace.defaultFocus(target.ws());
    wm.follow_request = true;
}

/// Send the focused window to the next/previous output's current workspace
/// and follow it there.
fn moveToOutput(wm: *WindowManager, from: *Output, forward: bool) void {
    const w = focusedWindow(wm) orelse return;
    const target = types.cycleOutput(wm, from, forward) orelse return;
    if (target == from) return;
    w.home = .{}; // moved on purpose: it no longer belongs to the monitor it was taken from
    workspace.moveToWorkspace(wm, w, target.ws()) catch |err| {
        log.warn("cannot move window to the other output: {t}", .{err});
        return;
    };
    wm.active_output = target;
    wm.focus_request = w;
    wm.follow_request = true;
}

const HideWhich = enum { same_app, other_apps };

/// Is `w` a window the user would call "an application window" -- not a
/// DockApp (they live in the Dock and have no title bar to restore from)?
fn hideable(w: *const Window) bool {
    if (w.closed or w.minimized or w.workspace == null) return false;
    return !(w.attrs.is("unfocusable") or w.attrs.is("skip_window_list"));
}

/// Window Maker's HIDE / HIDE_OTHERS. Applications are told apart by app_id;
/// a window without one counts as an application of its own.
fn hideMatching(wm: *WindowManager, keep: *Window, which: HideWhich) void {
    var it = wm.windows.first();
    while (it) |w| : (it = types.nextWindow(w, wm)) {
        if (!hideable(w)) continue;
        const same = w == keep or (w.app_id != null and keep.app_id != null and
            std.mem.eql(u8, w.app_id.?, keep.app_id.?));
        const hide = switch (which) {
            .same_app => same,
            .other_apps => !same,
        };
        if (hide) workspace.minimize(wm, w);
    }
}

/// Put a minimized window onto the workspace the user is on, and focus it.
pub fn restoreWindow(wm: *WindowManager, w: *Window, out: *Output) void {
    workspace.restore(wm, w, out.ws()) catch |err| {
        log.warn("cannot restore window: {t}", .{err});
        return;
    };
    wm.focus_request = w;
    wm.follow_request = true;
}

fn showAll(wm: *WindowManager, out: *Output) void {
    // Oldest first, so the one minimized last ends up focused.
    var n: usize = 0;
    var it = wm.windows.first();
    while (it) |w| : (it = types.nextWindow(w, wm)) {
        if (w.minimized and !w.closed) n += 1;
    }
    while (n > 0) : (n -= 1) {
        var oldest: ?*Window = null;
        var it2 = wm.windows.first();
        while (it2) |w| : (it2 = types.nextWindow(w, wm)) {
            if (!w.minimized or w.closed) continue;
            if (oldest == null or w.min_order < oldest.?.min_order) oldest = w;
        }
        const w = oldest orelse break;
        restoreWindow(wm, w, out);
    }
}

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

/// The floating window after (`forward`) or before `w` among the floating
/// windows of its workspace, in the order they were opened, wrapping around.
fn focusFloatingStep(wm: *WindowManager, w: *Window, forward: bool) void {
    const ws = w.workspace orelse return;
    var first: ?*Window = null;
    var last: ?*Window = null;
    var before: ?*Window = null;
    var after: ?*Window = null;
    var seen = false;
    var it = wm.windows.first();
    while (it) |o| : (it = types.nextWindow(o, wm)) {
        if (o.workspace != ws or o.mode != .floating or o.closed or o.attrs.is("unfocusable")) {
            if (o != w) continue;
        }
        if (first == null) first = o;
        last = o;
        if (o == w) {
            seen = true;
        } else if (!seen) {
            before = o;
        } else if (after == null) {
            after = o;
        }
    }
    const t = (if (forward) after orelse first else before orelse last) orelse return;
    if (t == w) return;
    focusWindow(wm, t);
}

/// The workspace after / before the shown one (wrapping if `workspace_wrap`),
/// or null at the end when it does not wrap, or with only one workspace.
fn stepWorkspace(cfg: *const config.Config, out: *Output, forward: bool) ?u32 {
    return stepIndex(out.workspace_count, out.active, forward, cfg.workspace_wrap);
}

/// The arithmetic of `stepWorkspace` on plain numbers: `n` workspaces, `active`
/// shown.
fn stepIndex(n: u32, active: u32, forward: bool, wrap: bool) ?u32 {
    if (n < 2) return null;
    if (forward) {
        if (active + 1 < n) return active + 1;
        return if (wrap) 0 else null;
    }
    if (active > 0) return active - 1;
    return if (wrap) n - 1 else null;
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
    out.prev_active = out.active;
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
            w.home = .{}; // moved on purpose: it no longer belongs to the monitor it was taken from
            workspace.moveToWorkspace(wm, w, to) catch |err| {
                log.err("omnipresent window could not follow: {t}", .{err});
            };
        }
        it = next;
    }
}

/// Focusing a window on another workspace must show that workspace.
fn switchToWindowWorkspace(wm: *WindowManager, w: *Window) void {
    const ws = w.workspace orelse return;
    switchWorkspace(wm, ws.output, ws.index);
}

/// Show the workspace `ws` is on its output (from the root menu, a Dock tile):
/// the same switch as `workspace N`, so omnipresent windows come along.
pub fn showWorkspace(wm: *WindowManager, ws: *types.Workspace) void {
    switchWorkspace(wm, ws.output, ws.index);
}

fn sendToWorkspace(wm: *WindowManager, out: *Output, index: u32) void {
    if (index >= out.workspace_count) _ = workspace.setWorkspaceCount(wm, out, index + 1);
    if (index >= out.workspace_count or index == out.active) return;
    const w = focusedWindow(wm) orelse return;
    w.home = .{}; // moved on purpose: it no longer belongs to the monitor it was taken from
    workspace.moveToWorkspace(wm, w, &out.workspaces[index]) catch |err| {
        log.err("move_to_workspace failed: {t}", .{err});
        return;
    };
    // The window leaves the visible workspace; focus what remains here.
    wm.focus_request = workspace.defaultFocus(out.ws());
    wm.follow_request = true;
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

test "workspaceArg: 1-based in the config, 0-based inside, 1..max_workspaces only" {
    var cfg: config.Config = .{ .arena = .init(std.testing.allocator) };
    defer cfg.deinit();
    try std.testing.expectEqual(@as(u32, 0), try workspaceArg("1", &cfg));
    try std.testing.expectEqual(@as(u32, 4), try workspaceArg("5", &cfg));
    try std.testing.expectEqual(@as(u32, config.max_workspaces - 1), try workspaceArg("16", &cfg));
    for ([_][]const u8{ "0", "17", "-1", "", "x", "1.5", "2 3" }) |bad| {
        try std.testing.expectError(error.BadArguments, workspaceArg(bad, &cfg));
    }
}

test "fractionArg: 0.5 and 50% are the same, more than 0 and at most 1" {
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), try fractionArg("0.5"), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), try fractionArg("50%"), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), try fractionArg("  25 % "), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), try fractionArg("1"), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), try fractionArg("100%"), 1e-9);
    for ([_][]const u8{ "0", "0%", "-0.1", "1.5", "101%", "", "%", "abc", "nan", "inf" }) |bad| {
        try std.testing.expectError(error.BadArguments, fractionArg(bad));
    }
}

test "twoInts: two whole numbers, signs allowed, anything else is a bad argument" {
    const a = try twoInts("3 -4");
    try std.testing.expectEqual(@as(i32, 3), a[0]);
    try std.testing.expectEqual(@as(i32, -4), a[1]);
    const b = try twoInts("  \t10\t  20  ");
    try std.testing.expectEqual(@as(i32, 10), b[0]);
    try std.testing.expectEqual(@as(i32, 20), b[1]);
    for ([_][]const u8{ "", "7", "7 x", "x 7", "1.5 2", "99999999999 1" }) |bad| {
        try std.testing.expectError(error.BadArguments, twoInts(bad));
    }
}

test "parse: the numeric commands go through the same checks" {
    var cfg: config.Config = .{ .arena = .init(std.testing.allocator) };
    defer cfg.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const ws = try parse(a, &cfg, "workspace 3");
    try std.testing.expectEqual(@as(u32, 2), ws.workspace);
    const mv = try parse(a, &cfg, "move_to_workspace 1");
    try std.testing.expectEqual(@as(u32, 0), mv.move_to_workspace);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), (try parse(a, &cfg, "set_column_width 50%")).set_column_width, 1e-9);
    const fm = try parse(a, &cfg, "float_move 10 -20");
    try std.testing.expectEqual(@as(i32, 10), fm.float_move.dx);
    try std.testing.expectEqual(@as(i32, -20), fm.float_move.dy);
    const fr = try parse(a, &cfg, "float_resize -5 8");
    try std.testing.expectEqual(@as(i32, -5), fr.float_resize.dw);
    try std.testing.expectEqual(@as(i32, 8), fr.float_resize.dh);
    try std.testing.expectEqual(@as(i32, 7), (try parse(a, &cfg, "lua 7")).lua);

    try std.testing.expectError(error.BadArguments, parse(a, &cfg, "workspace 0"));
    try std.testing.expectError(error.BadArguments, parse(a, &cfg, "workspace"));
    try std.testing.expectError(error.BadArguments, parse(a, &cfg, "set_column_width 2"));
    try std.testing.expectError(error.BadArguments, parse(a, &cfg, "float_move 1"));
    try std.testing.expectError(error.BadArguments, parse(a, &cfg, "lua x"));
    try std.testing.expectError(error.UnknownCommand, parse(a, &cfg, "no_such_command"));
    try std.testing.expectError(error.UnknownCommand, parse(a, &cfg, ""));
    try std.testing.expectError(error.UnknownCommand, parse(a, &cfg, "   \t "));
}

test "stepIndex: next and previous workspace, with and without wrapping" {
    // One workspace (or none): nowhere to go.
    try std.testing.expectEqual(@as(?u32, null), stepIndex(0, 0, true, true));
    try std.testing.expectEqual(@as(?u32, null), stepIndex(1, 0, true, true));
    try std.testing.expectEqual(@as(?u32, null), stepIndex(1, 0, false, true));
    // In the middle.
    try std.testing.expectEqual(@as(?u32, 2), stepIndex(4, 1, true, false));
    try std.testing.expectEqual(@as(?u32, 0), stepIndex(4, 1, false, false));
    // At the ends: wrap around, or stop.
    try std.testing.expectEqual(@as(?u32, 0), stepIndex(4, 3, true, true));
    try std.testing.expectEqual(@as(?u32, null), stepIndex(4, 3, true, false));
    try std.testing.expectEqual(@as(?u32, 3), stepIndex(4, 0, false, true));
    try std.testing.expectEqual(@as(?u32, null), stepIndex(4, 0, false, false));
    // Two workspaces bounce between each other.
    try std.testing.expectEqual(@as(?u32, 1), stepIndex(2, 0, true, true));
    try std.testing.expectEqual(@as(?u32, 0), stepIndex(2, 1, true, true));
}

test "nextPreset: the next wider preset, wrapping to the first one" {
    var cfg: config.Config = .{ .arena = .init(std.testing.allocator) };
    defer cfg.deinit();
    const work_w: i32 = 1000;
    const presets = cfg.width_presets;
    try std.testing.expect(presets.len >= 2);

    // Walking up through the presets visits them in order ...
    var current: i32 = 0;
    for (presets) |f| {
        const want = layout.columnWidthFor(work_w, f, &cfg);
        const got = nextPreset(work_w, current, &cfg);
        try std.testing.expectEqual(want, got);
        current = got;
    }
    // ... and after the widest one it starts over.
    try std.testing.expectEqual(
        layout.columnWidthFor(work_w, presets[0], &cfg),
        nextPreset(work_w, current + 1000, &cfg),
    );
}
