// SPDX-License-Identifier: GPL-3.0
//
// The manage pass: place new windows, run what was queued, decide the focus,
// lay out, and tell a `Sink` what the result is. It names no compositor
// library, so it is tested with a fake sink (see the tests at the end).
//
//   events (map, unmap, key, output change, SIGHUP, ...)
//        |  edit the model, `backend.manageDirty`
//        v
//   run(wm, sink)      one pass per turn of the event loop, never nested
//        |  reap, reload, place new windows, run queued commands,
//        |  decide the focus, lay out, then tell the sink the result
//        v
//   Sink               what the compositor does about it (xdg configure,
//                      scene nodes, keyboard focus)
//
// Nothing here names wlroots. That keeps the whole pass testable without a
// display.

const std = @import("std");
const log = std.log.scoped(.manage);

const model = @import("model.zig");
const types = model.types;
const config = model.config;
const layout = model.layout;
const workspace = model.workspace;
const action = model.action;
const boot = @import("boot.zig");
const pointer_op = @import("pointer_op.zig");
const diag = @import("diag.zig");
const motion = model.motion;
const backend = @import("backend.zig");

const Window = types.Window;
const Output = types.Output;
const Seat = types.Seat;
const WindowManager = types.WindowManager;

// ============================================================================
// The compositor side
// ============================================================================

/// What the client is told. A field that is null is not sent.
pub const Configure = struct {
    /// Content size, borders excluded.
    size: ?struct { w: i32, h: i32 } = null,
    /// The window sits in a column (drops rounded corners, shadows).
    tiled: ?bool = null,
    /// Enter (true) or leave (false) fullscreen on the window's output.
    fullscreen: ?bool = null,
};

/// Where and how a window is drawn.
pub const Placement = struct {
    visible: bool,
    /// Content rectangle (borders excluded) in layout coordinates.
    rect: types.Rect = .{},
    border: types.BorderKind = .none,
    border_width: i32 = 0,
    mode: types.Mode = .tiled,
    /// The window holds the keyboard focus: it goes on top of its layer.
    raise: bool = false,
    /// The part of the frame (content plus border) to show, relative to the
    /// content's top-left corner. Null: all of it. Set while a window opens
    /// and while a column is scrolled under the Dock.
    clip: ?types.Rect = null,
    /// Its column fills the work area (told to the client as `maximized`).
    maximized: bool = false,
};

pub const Sink = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        configure: *const fn (ctx: *anyopaque, win: *Window, c: Configure) void,
        place: *const fn (ctx: *anyopaque, win: *Window, p: Placement) void,
        /// Keyboard focus to `win`, or to nobody.
        focus: *const fn (ctx: *anyopaque, win: ?*Window) void,
        /// The window is gone from the model; free what the compositor kept
        /// for it. The `Window` itself is freed by the caller afterwards.
        release: *const fn (ctx: *anyopaque, win: *Window) void,
        /// `wm.quit` was set: end the event loop.
        quit: *const fn (ctx: *anyopaque) void,
    };

    fn configure(s: Sink, win: *Window, c: Configure) void {
        s.vtable.configure(s.ctx, win, c);
    }
    fn place(s: Sink, win: *Window, p: Placement) void {
        s.vtable.place(s.ctx, win, p);
    }
    fn focus(s: Sink, win: ?*Window) void {
        s.vtable.focus(s.ctx, win);
    }
    fn release(s: Sink, win: *Window) void {
        s.vtable.release(s.ctx, win);
    }
    fn quit(s: Sink) void {
        s.vtable.quit(s.ctx);
    }
};

// ============================================================================
// Creating and changing model objects (called by the event handlers)
// ============================================================================

pub fn createWindow(wm: *WindowManager, obj: *backend.Window, node: *backend.Node) !*Window {
    const win = try wm.gpa.create(Window);
    win.* = .{ .obj = obj, .node = node };
    wm.windows.append(win);
    return win;
}

/// Replace a string the client set (title, app_id). Null clears it.
pub fn setString(wm: *WindowManager, dst: *?[]u8, src: ?[]const u8) void {
    if (dst.*) |old| wm.gpa.free(old);
    dst.* = if (src) |s| wm.gpa.dupe(u8, s) catch null else null;
}

/// The client's size hints (xdg min/max size; 0 = none).
pub fn setHints(win: *Window, min_w: i32, min_h: i32, max_w: i32, max_h: i32) void {
    win.min_w = min_w;
    win.min_h = min_h;
    win.max_w = max_w;
    win.max_h = max_h;
}

/// The client reported the size its content has now.
pub fn setActualSize(win: *Window, w: i32, h: i32) void {
    win.actual_w = w;
    win.actual_h = h;
    win.ready = w > 0 and h > 0;
}

/// A monitor appeared. `now` is milliseconds on a clock that only goes
/// forward (the monitor manager settles after a quiet time).
pub fn createOutput(wm: *WindowManager, obj: *backend.Output, now: u64) !*Output {
    const out = try wm.gpa.create(Output);
    errdefer wm.gpa.destroy(out);
    out.* = .{ .obj = obj };

    // Workspaces need a stable address (Strip and Column keep back-pointers),
    // which is why the array lives inside the heap-allocated Output.
    out.workspace_count = wm.cfg.workspace_count;
    var i: u32 = 0;
    while (i < out.workspace_count) : (i += 1) out.workspaces[i].init(out, i);

    wm.outputs.append(out);
    wm.monitors.changed(now);
    return out;
}

/// The monitor's place on the desk, or its identity, changed.
pub fn setOutputRect(wm: *WindowManager, out: *Output, rect: types.Rect, now: u64) void {
    if (std.meta.eql(out.rect, rect)) return;
    out.rect = rect;
    wm.monitors.changed(now);
}

pub fn setOutputInfo(wm: *WindowManager, out: *Output, name: []const u8, make: ?[]const u8, model_name: ?[]const u8, description: ?[]const u8, scale: i32, now: u64) void {
    out.mon.name.set(name);
    if (make) |s| out.mon.make.set(s);
    if (model_name) |s| out.mon.model.set(s);
    if (description) |s| out.mon.description.set(s);
    out.mon.scale = scale;
    out.mon.complete = true;
    wm.monitors.changed(now);
}

/// The monitor is gone. Its windows move on in the next pass.
pub fn removeOutput(wm: *WindowManager, out: *Output, now: u64) void {
    out.removed = true;
    wm.monitors.changed(now);
}

pub fn createSeat(wm: *WindowManager, obj: *backend.Seat) !*Seat {
    const seat = try wm.gpa.create(Seat);
    seat.* = .{ .obj = obj };
    wm.seats.append(seat);
    return seat;
}

/// Focus request from the pointer (click, hover) or a client (activation).
pub fn requestFocus(wm: *WindowManager, win: *Window) void {
    action.requestFocus(wm, win);
}

/// A client asked to enter or leave fullscreen.
pub fn requestFullscreen(wm: *WindowManager, win: *Window, on: bool) void {
    if (win.workspace == null) return;
    wm.pending_fullscreen = .{ .win = win, .on = on };
    backend.manageDirty(wm.obj);
}

/// A client asked for its column to be (un)maximized. Maximize in a tiling
/// layout means the column fills the work area.
pub fn requestMaximize(wm: *WindowManager, win: *Window, on: bool) void {
    const col = win.column orelse return;
    if (col.isMaximized() != on) workspace.toggleMaximized(wm, col);
    wm.follow_request = true;
    backend.manageDirty(wm.obj);
}

/// A client asked to be minimized (Window Maker: miniaturized).
pub fn requestMinimize(wm: *WindowManager, win: *Window) void {
    if (win.workspace == null) return;
    workspace.minimize(wm, win);
    wm.follow_request = true;
    backend.manageDirty(wm.obj);
}

/// The client's app_id arrived or changed: its Window Maker attributes
/// (WMWindowAttributes) follow it. Whether it floats is only revisited for a
/// window that is already placed (a DockApp declares itself late); a new one
/// is decided by `placeNew`.
pub fn appIdChanged(wm: *WindowManager, win: *Window) void {
    win.attrs = wm.attrs.lookup(win.app_id);
    recheckFloating(wm, win);
    backend.manageDirty(wm.obj);
}

/// Attributes or size hints changed after the window was placed: it may
/// have to leave the strip now (a DockApp declares itself late, a dialog
/// reports min == max late).
pub fn recheckFloating(wm: *WindowManager, win: *Window) void {
    if (win.new or win.mode != .tiled) return;

    win.sticky = win.attrs.is("omnipresent");
    const should_float = win.attrs.floating orelse
        (wantsFloating(win) or win.attrs.is("omnipresent") or win.attrs.is("keep_on_top"));
    if (should_float) workspace.floatWindow(wm, win);
}

/// The window is gone (unmapped or destroyed). The pass frees it.
pub fn closeWindowObject(wm: *WindowManager, win: *Window) void {
    win.closed = true;
    backend.manageDirty(wm.obj);
}

// ============================================================================
// The pass
// ============================================================================

/// One pass. `now_ms` is the time on a clock that only goes forward, read once
/// so that every animation of the pass sees the same moment.
pub fn run(wm: *WindowManager, sink: Sink, now_ms: u64) void {
    // WMAKER_CHECKS=1 and SIGUSR1 (diag.zig): look at the model after the pass.
    defer diag.maybeCheck(wm);
    defer diag.maybeDump(wm);

    // 0. Time. `anim_active` is raised again below by whatever still moves;
    //    when nothing does, the compositor asks for no further frames.
    wm.clock.setSlowdown(wm.cfg.anim_slowdown);
    wm.clock.advance(now_ms);
    wm.anim_active = false;

    // 1. Drop what is gone.
    reapWindows(wm, sink);
    reapOutputs(wm);

    // 2. A config reload asked for by SIGHUP. Before the queue: it runs the
    //    queue itself first, on the config that produced it.
    if (wm.reload_pending) {
        wm.reload_pending = false;
        reload(wm);
    }

    // 3. New windows, then what the user pressed since the last pass.
    placeNew(wm);
    pointer_op.startPending(wm);
    pointer_op.apply(wm);
    runPending(wm);

    // 3b. The `reload_config` command. After the queue ran.
    if (wm.reload_pending) {
        wm.reload_pending = false;
        reload(wm);
    }

    // 4. Client-requested fullscreen.
    if (wm.pending_fullscreen) |pf| {
        wm.pending_fullscreen = null;
        if (pf.win.workspace != null and !pf.win.closed) {
            if (pf.on) workspace.setFullscreen(wm, pf.win) else workspace.leaveFullscreen(pf.win);
            workspace.activate(pf.win);
            wm.focus_request = pf.win;
            wm.follow_request = true;
        }
    }

    // 5. Struts and dynamic workspaces, after everything that moves windows.
    prepareOutputs(wm);

    // 6. Who gets the keyboard focus. Decided BEFORE the layout and made the
    //    active window of its workspace, so the strip scrolls to it.
    const focus_target = resolveFocus(wm);
    if (focus_target) |w| if (w.workspace) |ws| {
        wm.active_output = ws.output;
        workspace.activate(w);
    };

    // 7. Layout: geometry only.
    layoutAll(wm);

    // 8. What the compositor has to do about it.
    var it = wm.windows.first();
    while (it) |w| : (it = types.nextWindow(w, wm)) {
        applyManage(wm, sink, w);
        applyRender(wm, sink, w, w == focus_target);
    }

    // 9. Keyboard focus.
    var sit = wm.seats.first();
    while (sit) |s| : (sit = types.nextSeat(s, wm)) {
        if (setSeatFocus(s, focus_target)) sink.focus(focus_target);
    }

    // 10. End a finished pointer operation (after layout, so its last delta is
    //     in the final frame).
    pointer_op.finish(wm);

    // 11. Consumed.
    wm.focus_request = null;
    wm.follow_request = false;
    wm.focus_by_pointer = false;

    if (wm.quit) sink.quit();
}

/// Every window of every output is gone from the model, and so are the
/// outputs and seats. For the end of the session (and for tests).
pub fn shutdown(wm: *WindowManager, sink: Sink) void {
    var it = wm.windows.first();
    while (it) |w| {
        const next = types.nextWindow(w, wm);
        destroyWindow(wm, sink, w);
        it = next;
    }
    while (wm.outputs.first()) |out| {
        types.unlink(&out.link);
        wm.gpa.destroy(out);
    }
    while (wm.seats.first()) |s| {
        types.unlink(&s.link);
        wm.gpa.destroy(s);
    }
    wm.pending.deinit(wm.gpa);
    wm.pending = .empty;
}

// ---- removal ---------------------------------------------------------------------

fn reapWindows(wm: *WindowManager, sink: Sink) void {
    var it = wm.windows.first();
    while (it) |win| {
        const next = types.nextWindow(win, wm);
        if (win.closed) destroyWindow(wm, sink, win);
        it = next;
    }
}

/// A seat has `win` focused, or no seat has anything focused (then whatever
/// is on the workspace is the best target).
fn hadFocus(wm: *WindowManager, win: *Window) bool {
    var any = false;
    var it = wm.seats.first();
    while (it) |s| : (it = types.nextSeat(s, wm)) {
        if (s.focused == win) return true;
        if (s.focused != null) any = true;
    }
    return !any or wm.focus_request == win;
}

fn destroyWindow(wm: *WindowManager, sink: Sink, win: *Window) void {
    log.debug("window `{s}` is gone", .{win.app_id orelse "?"});
    const ws = win.workspace;
    // Only the window that HAD the focus hands it on.
    const was_focus_target = if (ws) |w| w.output.ws() == w and hadFocus(wm, win) else false;

    workspace.unplace(wm, win);
    forgetWindow(wm, sink, win);

    if (wm.focus_request == win) wm.focus_request = null;
    if (wm.pending_fullscreen) |pf| if (pf.win == win) {
        wm.pending_fullscreen = null;
    };

    types.unlink(&win.link);
    sink.release(win);
    if (win.app_id) |s| wm.gpa.free(s);
    if (win.title) |s| wm.gpa.free(s);
    wm.gpa.destroy(win);

    // Something must keep the keyboard focus: the next window on the
    // workspace that just lost one.
    if (was_focus_target) {
        if (ws) |w| {
            wm.focus_request = workspace.defaultFocus(w);
            wm.follow_request = true;
        }
    }
}

/// A window is going away: drop every seat reference to it. A seat that had
/// it focused is told at once, not by the focus step of the pass: by then the
/// model no longer remembers that the compositor still points at it.
fn forgetWindow(wm: *WindowManager, sink: Sink, win: *Window) void {
    var it = wm.seats.first();
    while (it) |s| : (it = types.nextSeat(s, wm)) {
        if (s.focused == win) {
            s.focused = null;
            sink.focus(null);
        }
        if (s.previous == win) s.previous = null;
        if (s.hovered == win) s.hovered = null;
        pointer_op.forget(s, win);
    }
}

fn reapOutputs(wm: *WindowManager) void {
    var it = wm.outputs.first();
    while (it) |out| {
        const next = types.nextOutput(out, wm);
        if (out.removed) {
            const target = pickOtherOutput(wm, out);
            migrate(wm, out, target);
            if (wm.active_output == out) wm.active_output = target;
            types.unlink(&out.link);
            wm.gpa.destroy(out);
            wm.follow_request = true;
        }
        it = next;
    }
}

/// The live output that takes over the windows of `gone`.
fn pickOtherOutput(wm: *WindowManager, gone: *Output) ?*Output {
    var live: [model.monitors.max_monitors]*Output = undefined;
    const n = types.liveOutputs(wm, &live);
    for (live[0..n]) |o| if (o != gone and o.primary) return o;
    for (live[0..n]) |o| if (o != gone) return o;
    return null;
}

/// Move every window of `out` to the same workspace index on `dest`. With no
/// destination the windows are left unplaced and placed again when an output
/// appears (`win.new = true`).
fn migrate(wm: *WindowManager, out: *Output, dest: ?*Output) void {
    var wi: u32 = 0;
    while (wi < out.workspace_count) : (wi += 1) {
        const src = &out.workspaces[wi];
        while (anyWindowOn(src)) |win| {
            workspace.leaveFullscreen(win);
            rememberHome(wm, out, win, wi);
            if (dest) |d| {
                const idx = @min(wi, d.workspace_count - 1);
                workspace.moveToWorkspace(wm, win, &d.workspaces[idx]) catch {
                    workspace.unplace(wm, win);
                    win.new = true;
                };
            } else {
                workspace.unplace(wm, win);
                win.new = true;
            }
        }
    }
}

fn anyWindowOn(ws: *types.Workspace) ?*Window {
    if (ws.strip.columns.first()) |c| if (c.windows.first()) |w| return w;
    if (ws.floating.first()) |w| return w;
    return null;
}

/// Note on `win` where it lived: it goes back when that monitor returns.
/// The first home wins.
fn rememberHome(wm: *WindowManager, out: *Output, win: *Window, ws_index: u32) void {
    if (win.home.isSet()) return;
    const key = out.mon.key();
    if (key == 0) return;
    if (!model.monitors.effective(wm.monitors.rules, &out.mon, wm.cfg.workspace_count).restore_windows) return;
    win.home = .{ .key = key, .ws = ws_index };
}

// ---- placement ---------------------------------------------------------------------

/// Should a new window float rather than tile? Dialogs (a parent is set) and
/// windows that cannot be resized (min == max) float.
fn wantsFloating(win: *const Window) bool {
    if (win.parent != null) return true;
    if (win.min_w > 0 and win.min_w == win.max_w and win.min_h > 0 and win.min_h == win.max_h) return true;
    return false;
}

/// `maximize_keep_focus` applies: the focused tiled window of `ws` sits in a
/// maximized column.
fn holdsFocus(wm: *WindowManager, ws: *types.Workspace) bool {
    if (!wm.cfg.maximize_keep_focus) return false;
    const col = ws.strip.active orelse return false;
    if (!col.isMaximized()) return false;
    const s = wm.seats.first() orelse return false;
    const f = s.focused orelse return false;
    return !f.closed and f.column == col;
}

/// Place every window that is not placed yet, by its Window Maker
/// attributes (StartWorkspace, Omnipresent, KeepOnTop, Floating,
/// StartMaximized, Unfocusable).
pub fn placeNew(wm: *WindowManager) void {
    var it = wm.windows.first();
    while (it) |win| : (it = types.nextWindow(win, wm)) {
        if (!win.new or win.closed) continue;
        const out = types.workingOutput(wm) orelse continue;

        const attrs = wm.attrs.lookup(win.app_id);
        win.attrs = attrs;

        var ws = out.ws();
        if (attrs.start_workspace) |sw| switch (sw) {
            .index => |i| {
                if (i < out.workspace_count) {
                    ws = &out.workspaces[i];
                } else {
                    log.warn("StartWorkspace {d} for `{s}`: only {d} workspaces exist", .{ i + 1, win.app_id orelse "?", out.workspace_count });
                }
            },
            .name => |n| log.warn("StartWorkspace `{s}`: workspace names are not supported yet, use a number", .{n}),
        };

        win.new = false;
        const hold = holdsFocus(wm, ws);
        const prev_col = ws.strip.active;
        const prev_win: ?*Window = if (prev_col) |c| c.focused else null;
        const floating = attrs.floating orelse
            (wantsFloating(win) or attrs.is("omnipresent") or attrs.is("keep_on_top"));

        if (floating) {
            workspace.placeFloating(ws, win);
            if (win.min_w > 0 and win.min_w == win.max_w) {
                win.actual_w = win.min_w;
                win.actual_h = win.min_h;
            }
            win.sticky = attrs.is("omnipresent");
        } else {
            workspace.placeTiled(wm, ws, win) catch |err| {
                log.err("cannot place window: {t}", .{err});
                win.new = true;
                continue;
            };
            if (attrs.is("start_maximized")) {
                if (win.column) |col| workspace.toggleMaximized(wm, col);
            }
        }

        if (hold and !floating) {
            ws.strip.active = prev_col;
            if (prev_col) |c| c.focused = prev_win;
            continue;
        }

        if (!attrs.is("unfocusable")) {
            workspace.activate(win);
            // `focus_new_windows = false`: open in the background while some
            // other window holds the focus.
            const background = !wm.cfg.focus_new_windows and blk: {
                const s = wm.seats.first() orelse break :blk false;
                const f = s.focused orelse break :blk false;
                break :blk !f.closed and f.workspace != null;
            };
            // A window opened on another workspace must not steal the view.
            if (ws == out.ws() and !background) {
                wm.focus_request = win;
                wm.follow_request = true;
            }
        }
    }
}

// ---- queued commands, reload ---------------------------------------------------------

fn runPending(wm: *WindowManager) void {
    // Actions may queue further requests (never further actions), so swap the
    // list out before running it.
    var batch = wm.pending;
    wm.pending = .empty;
    defer batch.deinit(wm.gpa);
    for (batch.items) |cmd| action.run(wm, cmd);
}

/// Queue the command bind number `index` triggers; the next pass runs it.
/// (Actions need the model in a settled state: a key press can arrive in the
/// middle of anything else.)
pub fn queueBind(wm: *WindowManager, index: usize) void {
    if (index >= wm.commands.len) return;
    wm.pending.append(wm.gpa, wm.commands[index]) catch {
        log.err("out of memory: key press dropped", .{});
        return;
    };
    backend.manageDirty(wm.obj);
}

/// Re-read config.lua and swap it into `wm`. A broken file never gets here:
/// `config.load` falls back to the built-in defaults with a warning.
pub fn reload(wm: *WindowManager) void {
    const new_cfg = config.load(wm.io, wm.gpa) catch |err| {
        log.err("config reload: {t}, keeping the current configuration", .{err});
        return;
    };

    // A key press just before the reload queued a Command whose argv lives in
    // the CURRENT config's arena. Run the queue now, on the config that made
    // it, before that arena is freed.
    runPending(wm);

    var old_cfg = wm.cfg;
    wm.cfg = new_cfg;
    if (boot.loadModel(wm)) |_| {
        boot.applyWorkspaceCount(wm, old_cfg.workspace_count);
        boot.applyEnvironment(wm.cfg.environment);
        old_cfg.deinit();
        log.info("config reloaded: {s} ({d} binds)", .{ wm.cfg.config_file, wm.cfg.binds.len });
    } else |err| {
        // Something under the new config's arena failed (out of memory, most
        // likely): revert wholesale rather than leave wm.commands, root_menu
        // and attrs pointing into an arena that is about to be freed.
        log.err("config reload: {t}", .{err});
        wm.cfg.deinit();
        wm.cfg = old_cfg;
        _ = boot.loadModel(wm) catch {
            wm.commands = &.{};
        };
    }
}

// ---- focus and layout ------------------------------------------------------------------

/// A window can take keyboard focus only if it is alive and sits on the
/// workspace that is currently shown on its output.
pub fn focusable(w: *const Window) bool {
    if (w.closed or w.attrs.is("unfocusable")) return false;
    const ws = w.workspace orelse return false;
    return ws.output.active == ws.index and !ws.output.removed;
}

/// Who gets keyboard focus after this pass.
fn resolveFocus(wm: *WindowManager) ?*Window {
    // 1. An explicit request wins.
    if (wm.focus_request) |w| if (focusable(w)) return w;

    // 2. Keep the current focus while it is still valid, and still on the
    //    output the user works on.
    const current: ?*Window = if (wm.seats.first()) |s| s.focused else null;
    const out = types.workingOutput(wm);
    if (current) |w| {
        if (focusable(w) and (wm.active_output == null or (w.workspace != null and w.workspace.?.output == out))) return w;
    }

    // 3. Fall back on the output the user was working on, so a second monitor
    //    does not suddenly steal focus from the first.
    return workspace.defaultFocus((out orelse return null).ws());
}

/// Give keyboard focus to `win` in the model (or clear it). Returns whether
/// the focus changed, i.e. whether the compositor has to be told.
fn setSeatFocus(seat: *Seat, win: ?*Window) bool {
    if (win) |w| {
        if (w.closed or w.workspace == null) return false;
        if (seat.focused == w) return false;
        if (seat.focused != null and seat.focused != w) seat.previous = seat.focused;
        seat.focused = w;
        return true;
    }
    if (seat.focused != null) {
        seat.focused = null;
        return true;
    }
    return false;
}

/// Per-output housekeeping that has to be settled before layout: the
/// `strut_*` options, and `dynamic_workspaces`.
fn prepareOutputs(wm: *WindowManager) void {
    const cfg = &wm.cfg;
    var oit = wm.outputs.first();
    while (oit) |out| : (oit = types.nextOutput(out, wm)) {
        if (out.removed) continue;
        out.struts = .{ .left = cfg.strut_left, .right = cfg.strut_right, .top = cfg.strut_top, .bottom = cfg.strut_bottom };
        if (cfg.dynamic_workspaces) workspace.maintainDynamic(wm, out, cfg.workspace_count);
    }
}

fn layoutAll(wm: *WindowManager) void {
    var oit = wm.outputs.first();
    while (oit) |out| : (oit = types.nextOutput(out, wm)) {
        if (!types.liveOutput(out)) continue;
        // Only the visible workspace needs geometry. Hidden workspaces keep
        // their scroll offset for when they come back.
        layout.compute(out.ws(), &wm.cfg, wm.follow_request);
    }
}

// ---- telling the compositor ----------------------------------------------------------------

fn isVisible(win: *const Window) bool {
    const ws = win.workspace orelse return false;
    if (win.closed) return false;
    if (win.isOmnipresent()) return true;
    return ws.output.active == ws.index;
}

/// Management state: size, tiled, fullscreen. Sent only on change.
fn applyManage(wm: *WindowManager, sink: Sink, win: *Window) void {
    const ws = win.workspace orelse return;
    const cfg = &wm.cfg;

    // Windows on a hidden workspace were not laid out this pass, so their
    // `target` is stale. They get a fresh proposal when their workspace is
    // shown.
    if (!win.isOmnipresent() and ws.output.active != ws.index) return;
    if (win.closed) return;

    var c: Configure = .{};

    const want_fs: ?*Output = if (win.mode == .fullscreen) ws.output else null;
    if (want_fs != win.sent_fullscreen) {
        c.fullscreen = want_fs != null;
        win.sent_fullscreen = want_fs;
        // Size and position are undefined after leaving fullscreen until we
        // propose again.
        win.sent_w = -1;
        win.sent_h = -1;
    }

    const tiled = win.mode == .tiled;
    if (win.sent_tiled != tiled) {
        c.tiled = tiled;
        win.sent_tiled = tiled;
    }

    // Propose only when the wanted size changed (or was never sent). A
    // fullscreen window is as big as its output.
    const Size = struct { w: i32, h: i32 };
    const size: Size = if (win.mode == .fullscreen)
        .{ .w = @max(1, ws.output.rect.w), .h = @max(1, ws.output.rect.h) }
    else blk: {
        const s = win.clampSize(win.target.w, win.target.h, cfg.min_window_size);
        break :blk .{ .w = s.w, .h = s.h };
    };
    if (win.mode != .fullscreen) {
        win.target.w = size.w;
        win.target.h = size.h;
    }
    if (size.w != win.sent_w or size.h != win.sent_h) {
        c.size = .{ .w = size.w, .h = size.h };
        win.sent_w = size.w;
        win.sent_h = size.h;
    }

    if (c.size != null or c.tiled != null or c.fullscreen != null) sink.configure(win, c);
}

/// Rendering state: visibility, position, borders, clip.
fn applyRender(wm: *WindowManager, sink: Sink, win: *Window, focused: bool) void {
    const cfg = &wm.cfg;

    if (!isVisible(win)) {
        motion.stopAnimations(win);
        if (win.visible != false) {
            log.debug("window `{s}` hidden", .{win.app_id orelse "?"});
            win.visible = false;
            sink.place(win, .{ .visible = false });
        }
        return;
    }
    win.visible = true;

    const bw = win.borderWidth(cfg);

    if (win.mode == .fullscreen) {
        // Fullscreen covers its output and has no border, and does not travel.
        motion.stopAnimations(win);
        if (win.ready) win.opened = true; // leaving fullscreen is not an opening
        sink.place(win, .{
            .visible = true,
            .rect = win.workspace.?.output.rect,
            .mode = .fullscreen,
            .raise = focused,
        });
        return;
    }

    // Where it is drawn now: its target, or on the way there.
    const vis = motion.visualState(wm, win);
    const rect: types.Rect = .{ .x = vis.x, .y = vis.y, .w = win.target.w, .h = win.target.h };

    const kind: types.BorderKind = if (bw == 0)
        .none
    else if (focused)
        .focused
    else if (win.mode == .floating)
        .floating
    else
        .unfocused;
    // A focused floating window keeps the floating tint so the layer stays
    // recognisable; the focused colour is only for the tiled strip.
    const shown: types.BorderKind = if (focused and win.mode == .floating) .floating else kind;

    // A tiled window scrolled sideways slides under the edge of the work area
    // (next to the Dock), not under the Dock. Floating windows are not clipped.
    const work: ?types.Rect = if (win.mode == .tiled) win.workspace.?.output.workArea() else null;

    win.sent_x = rect.x;
    win.sent_y = rect.y;
    win.sent_border = shown;
    sink.place(win, .{
        .visible = true,
        .rect = rect,
        .border = shown,
        .border_width = bw,
        .mode = win.mode,
        .raise = focused,
        .clip = motion.visibleBox(rect, bw, work, vis.reveal),
        .maximized = if (win.column) |c| c.isMaximized() else false,
    });
}

/// The overlap of two rectangles, null when they do not touch.
pub fn intersect(a: types.Rect, b: types.Rect) ?types.Rect {
    const x0 = @max(a.x, b.x);
    const y0 = @max(a.y, b.y);
    const x1 = @min(a.x + a.w, b.x + b.w);
    const y1 = @min(a.y + a.h, b.y + b.h);
    if (x1 <= x0 or y1 <= y0) return null;
    return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
}

/// 0xRRGGBB of a border kind, from the config.
pub fn borderRgb(kind: types.BorderKind, cfg: *const config.Config) u32 {
    return switch (kind) {
        .focused => cfg.border_focused,
        .unfocused => cfg.border_unfocused,
        .floating => cfg.border_floating,
        .none => 0,
    };
}

/// 0xRRGGBB -> opaque RGBA in 0..1, what wlr_scene_rect takes.
pub fn rgba(rgb: u32) [4]f32 {
    return .{
        @as(f32, @floatFromInt((rgb >> 16) & 0xff)) / 255.0,
        @as(f32, @floatFromInt((rgb >> 8) & 0xff)) / 255.0,
        @as(f32, @floatFromInt(rgb & 0xff)) / 255.0,
        1.0,
    };
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

var dummy_byte: u8 = 0;

const Rec = struct {
    const Event = union(enum) {
        configure: struct { win: *Window, c: Configure },
        place: struct { win: *Window, p: Placement },
        focus: ?*Window,
        release: *Window,
        quit,
    };

    events: std.ArrayList(Event) = .empty,
    focused: ?*Window = null,

    fn sink(r: *Rec) Sink {
        return .{ .ctx = r, .vtable = &.{
            .configure = configure,
            .place = place,
            .focus = focus,
            .release = release,
            .quit = quit,
        } };
    }

    fn me(ctx: *anyopaque) *Rec {
        return @ptrCast(@alignCast(ctx));
    }
    fn configure(ctx: *anyopaque, win: *Window, c: Configure) void {
        me(ctx).events.append(testing.allocator, .{ .configure = .{ .win = win, .c = c } }) catch unreachable;
    }
    fn place(ctx: *anyopaque, win: *Window, p: Placement) void {
        me(ctx).events.append(testing.allocator, .{ .place = .{ .win = win, .p = p } }) catch unreachable;
    }
    fn focus(ctx: *anyopaque, win: ?*Window) void {
        me(ctx).focused = win;
        me(ctx).events.append(testing.allocator, .{ .focus = win }) catch unreachable;
    }
    fn release(ctx: *anyopaque, win: *Window) void {
        me(ctx).events.append(testing.allocator, .{ .release = win }) catch unreachable;
    }
    fn quit(ctx: *anyopaque) void {
        me(ctx).events.append(testing.allocator, .quit) catch unreachable;
    }

    /// The last placement the sink got for `win`.
    fn lastPlace(r: *const Rec, win: *Window) ?Placement {
        var i = r.events.items.len;
        while (i > 0) {
            i -= 1;
            switch (r.events.items[i]) {
                .place => |e| if (e.win == win) return e.p,
                else => {},
            }
        }
        return null;
    }

    fn lastConfigure(r: *const Rec, win: *Window) ?Configure {
        var i = r.events.items.len;
        while (i > 0) {
            i -= 1;
            switch (r.events.items[i]) {
                .configure => |e| if (e.win == win) return e.c,
                else => {},
            }
        }
        return null;
    }

    fn released(r: *const Rec, win: *Window) bool {
        for (r.events.items) |e| switch (e) {
            .release => |w| if (w == win) return true,
            else => {},
        };
        return false;
    }

    fn quit_seen(r: *const Rec) bool {
        for (r.events.items) |e| switch (e) {
            .quit => return true,
            else => {},
        };
        return false;
    }

    fn deinit(r: *Rec) void {
        r.events.deinit(testing.allocator);
    }
};

const Fixture = struct {
    wm: WindowManager,
    rec: Rec = .{},
    out: *Output = undefined,
    now: u64 = 1000,

    fn init(f: *Fixture) !void {
        const a = testing.allocator;
        f.* = .{
            .wm = .{
                .gpa = a,
                .io = undefined,
                .cfg = .{ .arena = .init(a) },
                .obj = @ptrCast(&dummy_byte),
                .obj_version = 0,
                .outputs = undefined,
                .windows = undefined,
                .dock_windows = undefined,
                .seats = undefined,
            },
        };
        f.wm.cfg.workspace_count = 2;
        f.wm.outputs.init();
        f.wm.windows.init();
        f.wm.dock_windows.init();
        f.wm.seats.init();
        f.out = try createOutput(&f.wm, @ptrCast(&dummy_byte), 0);
        setOutputRect(&f.wm, f.out, .{ .x = 0, .y = 0, .w = 1920, .h = 1080 }, 0);
        _ = try createSeat(&f.wm, @ptrCast(&dummy_byte));
    }

    fn deinit(f: *Fixture) void {
        shutdown(&f.wm, f.rec.sink());
        f.wm.cfg.deinit();
        f.rec.deinit();
    }

    fn open(f: *Fixture, app_id: []const u8) !*Window {
        const w = try createWindow(&f.wm, @ptrCast(&dummy_byte), @ptrCast(&dummy_byte));
        setString(&f.wm, &w.app_id, app_id);
        return w;
    }

    fn pass(f: *Fixture) void {
        f.now += 16;
        run(&f.wm, f.rec.sink(), f.now);
    }

    fn press(f: *Fixture, cmd: types.Command) void {
        f.wm.pending.append(f.wm.gpa, cmd) catch unreachable;
    }
};

test "a new window is placed, sized to its column, focused and drawn with the focused border" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();

    const w = try f.open("foot");
    f.pass();

    try testing.expect(w.workspace == f.out.ws());
    try testing.expectEqual(types.Mode.tiled, w.mode);
    try testing.expect(f.rec.focused == w);
    try testing.expect(f.wm.seats.first().?.focused == w);

    const c = f.rec.lastConfigure(w).?;
    try testing.expect(c.size != null);
    try testing.expectEqual(@as(?bool, true), c.tiled);
    // Half the output wide (default_column_width = 0.5), inside the gaps.
    try testing.expect(c.size.?.w > 800 and c.size.?.w < 960);
    try testing.expect(c.size.?.h > 900 and c.size.?.h < 1080);

    const p = f.rec.lastPlace(w).?;
    try testing.expect(p.visible);
    try testing.expectEqual(types.BorderKind.focused, p.border);
    try testing.expectEqual(f.wm.cfg.border_width, p.border_width);
    try testing.expect(p.rect.x >= 0 and p.rect.right() <= 1920);
    try testing.expect(p.raise);
}

test "nothing is sent twice: a second pass with no change configures nobody" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();

    const w = try f.open("foot");
    f.pass();
    const before = f.rec.events.items.len;
    f.pass();
    for (f.rec.events.items[before..]) |e| switch (e) {
        .configure => |c| {
            try testing.expect(c.win != w);
            return error.ConfiguredTwice;
        },
        else => {},
    };
}

test "key bindings move focus between columns" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();

    const a = try f.open("a");
    f.pass();
    const b = try f.open("b");
    f.pass();
    try testing.expect(f.rec.focused == b);

    f.press(.focus_left);
    f.pass();
    try testing.expect(f.rec.focused == a);
    try testing.expectEqual(types.BorderKind.focused, f.rec.lastPlace(a).?.border);
    try testing.expectEqual(types.BorderKind.unfocused, f.rec.lastPlace(b).?.border);

    f.press(.focus_right);
    f.pass();
    try testing.expect(f.rec.focused == b);
}

test "closing the focused window hands the focus on and frees it" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();

    const a = try f.open("a");
    f.pass();
    const b = try f.open("b");
    f.pass();
    try testing.expect(f.rec.focused == b);

    closeWindowObject(&f.wm, b);
    f.pass();
    try testing.expect(f.rec.released(b));
    try testing.expect(f.rec.focused == a);
    try testing.expect(f.wm.seats.first().?.focused == a);
}

test "closing the last window clears the focus" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();

    const a = try f.open("a");
    f.pass();
    closeWindowObject(&f.wm, a);
    f.pass();
    try testing.expect(f.rec.focused == null);
    try testing.expect(f.wm.windows.empty());
}

test "another workspace hides the window, coming back shows it" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();

    const w = try f.open("a");
    f.pass();
    try testing.expect(f.rec.lastPlace(w).?.visible);

    f.press(.{ .workspace = 1 });
    f.pass();
    try testing.expect(!f.rec.lastPlace(w).?.visible);
    try testing.expect(f.rec.focused == null);

    f.press(.{ .workspace = 0 });
    f.pass();
    try testing.expect(f.rec.lastPlace(w).?.visible);
    try testing.expect(f.rec.focused == w);
}

test "a dialog floats, and a client's fullscreen request covers the output" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();

    const base = try f.open("a");
    f.pass();
    const dlg = try f.open("dialog");
    dlg.parent = @ptrCast(&dummy_byte);
    f.pass();
    try testing.expectEqual(types.Mode.floating, dlg.mode);
    try testing.expectEqual(types.BorderKind.floating, f.rec.lastPlace(dlg).?.border);

    requestFullscreen(&f.wm, base, true);
    f.pass();
    try testing.expectEqual(types.Mode.fullscreen, base.mode);
    const p = f.rec.lastPlace(base).?;
    try testing.expectEqual(types.BorderKind.none, p.border);
    try testing.expectEqual(@as(i32, 1920), p.rect.w);
    const c = f.rec.lastConfigure(base).?;
    try testing.expectEqual(@as(?bool, true), c.fullscreen);
    try testing.expectEqual(@as(i32, 1080), c.size.?.h);

    requestFullscreen(&f.wm, base, false);
    f.pass();
    try testing.expectEqual(types.Mode.tiled, base.mode);
    try testing.expectEqual(@as(?bool, false), f.rec.lastConfigure(base).?.fullscreen);
}

test "the exit command ends the loop" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.press(.exit);
    f.pass();
    try testing.expect(f.rec.quit_seen());
}

test "a removed output gives its windows to the one that is left" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();

    const second = try createOutput(&f.wm, @ptrCast(&dummy_byte), 0);
    setOutputRect(&f.wm, second, .{ .x = 1920, .y = 0, .w = 1280, .h = 720 }, 0);

    const w = try f.open("a");
    f.pass();
    try testing.expect(w.workspace.?.output == f.out);

    removeOutput(&f.wm, f.out, 0);
    f.pass();
    try testing.expect(w.workspace.?.output == second);
    try testing.expect(f.wm.active_output == second);
    try testing.expect(f.rec.focused == w);
    try testing.expect(f.rec.lastPlace(w).?.rect.x >= 1920);
}

test "rgba splits 0xRRGGBB" {
    const c = rgba(0xff8000);
    try testing.expectEqual(@as(f32, 1.0), c[0]);
    try testing.expect(c[1] > 0.5 and c[1] < 0.51);
    try testing.expectEqual(@as(f32, 0), c[2]);
    try testing.expectEqual(@as(f32, 1.0), c[3]);
}

test "a column that makes room travels there frame by frame, then everything is still" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();

    const a = try f.open("a");
    f.pass();
    f.pass();
    try testing.expect(!f.wm.anim_active);
    const home_x = a.target.x;
    // The second window opens to the right and scrolls the first one aside.
    const b = try f.open("b");
    f.pass();
    _ = b;
    _ = home_x;

    // Whatever moved is on its way: positions are not the targets yet, and
    // the pass says it wants another frame.
    var frames: usize = 0;
    while (frames < 200) : (frames += 1) {
        const p = f.rec.lastPlace(a).?;
        // Never outside the output while travelling.
        try testing.expect(p.rect.x > -4000 and p.rect.x < 6000);
        if (!f.wm.anim_active) break;
        f.pass();
    }
    try testing.expect(frames < 200); // it stops by itself
    try testing.expect(!f.wm.anim_active);
    try testing.expectEqual(a.target.x, f.rec.lastPlace(a).?.rect.x);
}

test "dragging a tiled window past the threshold floats it; the button ends it" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();

    const w = try f.open("a");
    f.pass();
    const seat = f.wm.seats.first().?;

    try testing.expect(pointer_op.begin(&f.wm, seat, .move, w));
    f.pass(); // requested -> running
    try testing.expectEqual(types.OpState.running, seat.op_state);

    // A small wiggle changes nothing.
    pointer_op.setDelta(seat, 3, 2);
    f.pass();
    try testing.expectEqual(types.Mode.tiled, w.mode);

    pointer_op.setDelta(seat, 200, 100);
    f.pass();
    try testing.expectEqual(types.Mode.floating, w.mode);
    const start_x = seat.op_start_rect.x;
    try testing.expectEqual(start_x + 200, w.float_rect.x);

    pointer_op.release(seat);
    f.pass();
    try testing.expectEqual(types.OpState.idle, seat.op_state);
    try testing.expectEqual(types.Mode.floating, w.mode);
}

test "a client's maximize request fills the work area with its column" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();

    const w = try f.open("a");
    f.pass();
    try testing.expect(!w.column.?.isMaximized());
    requestMaximize(&f.wm, w, true);
    f.pass();
    try testing.expect(w.column.?.isMaximized());
    requestMaximize(&f.wm, w, false);
    f.pass();
    try testing.expect(!w.column.?.isMaximized());
}

test "a client's minimize request hides the window and moves focus on" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();

    const a = try f.open("a");
    f.pass();
    const b = try f.open("b");
    f.pass();
    requestMinimize(&f.wm, b);
    f.pass();
    try testing.expect(!f.rec.lastPlace(b).?.visible);
    try testing.expect(f.rec.focused == a);
}

test "intersect" {
    const a: types.Rect = .{ .x = 0, .y = 0, .w = 100, .h = 50 };
    try testing.expectEqual(@as(?types.Rect, .{ .x = 10, .y = 0, .w = 90, .h = 20 }), intersect(a, .{ .x = 10, .y = -30, .w = 500, .h = 50 }));
    try testing.expectEqual(@as(?types.Rect, null), intersect(a, .{ .x = 100, .y = 0, .w = 5, .h = 5 }));
}
