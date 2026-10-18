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
    wm.obj.manageDirty();
}

/// What `run("workspace 2")`, `spawn("foot")` and `shell("...")` do inside a
/// Lua function of config.lua: the same commands as a key binding's text.
/// (Set as `config.runner` at start-up.)
pub fn runFromLua(text: []const u8) void {
    const wm = global orelse return;
    // A function calling `run("lua N")` could loop for ever.
    if (std.mem.startsWith(u8, std.mem.trimStart(u8, text, " \t"), "lua")) {
        std.log.warn("config.lua: run() cannot start a Lua function", .{});
        return;
    }
    var arena: std.heap.ArenaAllocator = .init(wm.gpa);
    defer arena.deinit();
    const cmd = parse(arena.allocator(), &wm.cfg, text) catch |err| {
        std.log.warn("config.lua: bad command `{s}`: {t}", .{ text, err });
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

        .close => if (focusedWindow(wm)) |w| w.obj.close(),

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
            std.log.warn("workspace_add: already {d} workspaces", .{out.workspace_count});
        },
        .workspace_remove_last => if (workspace.removeLastWorkspace(wm, out)) {
            wm.focus_request = workspace.defaultFocus(out.ws());
            wm.follow_request = true;
        },
        .move_to_workspace_next, .move_to_workspace_prev => {
            const fwd = cmd == .move_to_workspace_next;
            const target = stepWorkspace(cfg, out, fwd) orelse return;
            const w = focusedWindow(wm) orelse return;
            workspace.moveToWorkspace(wm, w, &out.workspaces[target]) catch |err| {
                std.log.err("move window to workspace failed: {t}", .{err});
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
    workspace.moveToWorkspace(wm, w, target.ws()) catch |err| {
        std.log.warn("cannot move window to the other output: {t}", .{err});
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
        std.log.warn("cannot restore window: {t}", .{err});
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
    const n = out.workspace_count;
    if (n < 2) return null;
    if (forward) {
        if (out.active + 1 < n) return out.active + 1;
        return if (cfg.workspace_wrap) 0 else null;
    }
    if (out.active > 0) return out.active - 1;
    return if (cfg.workspace_wrap) n - 1 else null;
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
            workspace.moveToWorkspace(wm, w, to) catch |err| {
                std.log.err("omnipresent window could not follow: {t}", .{err});
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
    workspace.moveToWorkspace(wm, w, &out.workspaces[index]) catch |err| {
        std.log.err("move_to_workspace failed: {t}", .{err});
        return;
    };
    // The window leaves the visible workspace; focus what remains here.
    wm.focus_request = workspace.defaultFocus(out.ws());
    wm.follow_request = true;
}
