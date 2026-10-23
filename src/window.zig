// SPDX-License-Identifier: GPL-3.0
//
// river_window_v1: events, and the two functions that turn our model into
// protocol requests:
//
//   applyManage()  - management state. Legal only between manage_start and
//                    manage_finish: propose_dimensions, set_tiled, use_ssd,
//                    fullscreen / exit_fullscreen, hide/show decisions are
//                    *computed* here but see below.
//   applyRender()  - rendering state. Legal between render_start and
//                    render_finish: set_position, place_top, set_borders,
//                    show / hide.
//
// The split is the rule the previous implementation kept violating.
// Nothing outside these two functions sends window requests, except
// `close`, which is legal in a manage sequence and lives in action.zig.

const std = @import("std");
const log = std.log.scoped(.window);
const anim_log = std.log.scoped(.anim);
const wayland = @import("wayland");
const river = wayland.client.river;

const types = @import("types.zig");
const config = @import("config.zig");
const workspace = @import("workspace.zig");
const layout = @import("layout.zig");
const seatmod = @import("seat.zig");
const dockhost = @import("dockhost.zig");
const animation = @import("animation.zig");

const Window = types.Window;
const WindowManager = types.WindowManager;
const Output = types.Output;

// ----------------------------------------------------------------------------
// Creation / events
// ----------------------------------------------------------------------------

pub fn create(wm: *WindowManager, obj: *river.WindowV1) !*Window {
    const node = try obj.getNode();
    errdefer node.destroy();

    const win = try wm.gpa.create(Window);
    errdefer wm.gpa.destroy(win);
    win.* = .{ .obj = obj, .node = node };

    wm.windows.append(win);
    obj.setListener(*WindowManager, listener, wm);
    log.debug("river announced a new window", .{});
    return win;
}

fn find(wm: *WindowManager, obj: *river.WindowV1) ?*Window {
    var it = wm.windows.first();
    while (it) |w| : (it = types.nextWindow(w, wm)) {
        if (w.obj == obj) return w;
    }
    var dit = wm.dock_windows.first();
    while (dit) |w| : (dit = types.nextDockWindow(w, wm)) {
        if (w.obj == obj) return w;
    }
    return null;
}

/// A DockApp is an icon: it reports its size and name, and that is all of
/// its events that mean anything. It cannot ask to be moved, resized or made
/// fullscreen, and its role never changes again.
fn dockEvent(wm: *WindowManager, win: *Window, event: river.WindowV1.Event) void {
    switch (event) {
        .closed => {
            win.closed = true;
            wm.obj.manageDirty();
        },
        .dimensions => |d| {
            win.actual_w = d.width;
            win.actual_h = d.height;
            win.ready = true;
            wm.obj.manageDirty();
        },
        .dimensions_hint => |h| {
            win.min_w = h.min_width;
            win.min_h = h.min_height;
            win.max_w = h.max_width;
            win.max_h = h.max_height;
            wm.obj.manageDirty();
        },
        .app_id => |a| {
            setString(wm, &win.app_id, a.app_id);
            wm.obj.manageDirty();
        },
        .title => |t| setString(wm, &win.title, t.title),
        else => {},
    }
}

fn setString(wm: *WindowManager, dst: *?[]u8, src: ?[*:0]const u8) void {
    if (dst.*) |old| wm.gpa.free(old);
    dst.* = if (src) |s| wm.gpa.dupe(u8, std.mem.span(s)) catch null else null;
}

fn listener(obj: *river.WindowV1, event: river.WindowV1.Event, wm: *WindowManager) void {
    const win = find(wm, obj) orelse return;
    if (win.role == .dockapp) return dockEvent(wm, win, event);
    switch (event) {
        .closed => {
            win.closed = true;
            wm.obj.manageDirty();
        },

        .dimensions => |d| {
            win.actual_w = d.width;
            win.actual_h = d.height;
            // First dimensions event: the window has content and can be
            // shown and focused.
            if (!win.ready) {
                win.ready = true;
                log.debug("window `{s}` has content ({d}x{d})", .{ win.app_id orelse "?", d.width, d.height });
                anim_log.debug("window has content ({d}x{d}) real={d}", .{ d.width, d.height, realMs(wm) });
                wm.obj.manageDirty();
            }
        },

        .dimensions_hint => |h| {
            win.min_w = h.min_width;
            win.min_h = h.min_height;
            win.max_w = h.max_width;
            win.max_h = h.max_height;
            // A fixed-size hint (the DockApp shape) can arrive after the
            // window was already tiled on first placement; see
            // recheckFloating.
            recheckFloating(wm, win);
            wm.obj.manageDirty();
        },

        .app_id => |a| {
            setString(wm, &win.app_id, a.app_id);
            log.debug("window app_id is `{s}`", .{win.app_id orelse "?"});
            // The tag `dockapp:<name>` makes this an icon, not a window, from
            // now on and whatever state it was in (see dockhost.zig).
            if (dockhost.isDockApp(win.app_id)) {
                dockhost.adopt(wm, win);
                wm.obj.manageDirty();
                return;
            }
            // Decoration attributes follow the real app_id; where the window
            // lives was decided when it was placed.
            win.attrs = wm.attrs.lookup(win.app_id);
            recheckFloating(wm, win);
            wm.obj.manageDirty();
        },
        .title => |t| setString(wm, &win.title, t.title),

        .parent => |p| {
            win.parent = p.parent;
            // A dialog whose parent shows up late should float too, same
            // reasoning as the app_id/dimensions_hint cases above.
            recheckFloating(wm, win);
            wm.obj.manageDirty();
        },

        // Client asked for a move / resize (CSD title bar, resize handle).
        // Same state machine as Super+mouse.
        .pointer_move_requested => |ev| {
            if (ev.seat) |s| seatmod.beginClientOp(wm, s, .move, win, null);
        },
        .pointer_resize_requested => |ev| {
            if (ev.seat) |s| seatmod.beginClientOp(wm, s, .resize, win, ev.edges);
        },

        .fullscreen_requested => {
            if (win.workspace != null) {
                wm.pending_fullscreen = .{ .win = win, .on = true };
                wm.obj.manageDirty();
            }
        },
        .exit_fullscreen_requested => {
            if (win.workspace != null) {
                wm.pending_fullscreen = .{ .win = win, .on = false };
                wm.obj.manageDirty();
            }
        },

        else => {},
    }
}

// ----------------------------------------------------------------------------
// Placement policy
// ----------------------------------------------------------------------------

/// Should a new window float rather than tile? Dialogs (a parent is set)
/// and windows that cannot be resized (min == max) float.
fn wantsFloating(win: *const Window) bool {
    if (win.parent != null) return true;
    if (win.min_w > 0 and win.min_w == win.max_w and win.min_h > 0 and win.min_h == win.max_h) return true;
    return false;
}

/// placeNew() decides workspace/floating exactly once, the moment a window
/// is first placed (see types.zig's `attrs` doc comment and docs/TODO.md,
/// "Attribute mit später eintreffender app_id"). Several clients -- most
/// DockApps included -- only reveal the state that makes them a DockApp
/// (a fixed-size hint, or an app_id with the "dockapp:"/"dockapp-" prefix)
/// in an event that arrives strictly after that first placement. Without
/// this, such a window is stuck tiled forever: full border, part of a
/// column, a "dockapp:clock" looking exactly like an ordinary xterm.
///
/// Called from the app_id / dimensions_hint / parent handlers above, every
/// time one of them changes something wantsFloating()/attrs.floating could
/// depend on. A no-op for a window that is not yet placed (placeNew will
/// use the now-current state) or is already floating.
///
/// Deliberately narrow: only the floating/tiled mode and `sticky`
/// (Omnipresent) are revisited. StartWorkspace is not -- moving a window
/// that may already be sitting in a column with others to a different
/// workspace after the fact is a bigger, rarer change than a late DockApp
/// declaration calls for, and is left as a known limitation (see
/// docs/TODO.md).
pub fn recheckFloating(wm: *WindowManager, win: *Window) void {
    if (win.new or win.mode != .tiled) return;

    win.sticky = win.attrs.is("omnipresent");
    const should_float = win.attrs.floating orelse
        (wantsFloating(win) or win.attrs.is("omnipresent") or win.attrs.is("keep_on_top"));
    if (should_float) workspace.floatWindow(wm, win);
}

/// Place every window that is not placed yet. Manage only.
///
/// A window is placed at once, WITHOUT waiting for its first `dimensions`
/// event: river only sends that event after we made propose_dimensions, so
/// waiting for it here would wait forever (protocol: "A newly created window
/// will not be displayed until the window manager makes a propose_dimensions
/// or fullscreen request").
///
/// Window Maker attributes (WMWindowAttributes) decide where and how:
///   StartWorkspace   workspace number (1-based); names are not supported yet
///   Omnipresent      floating, and follows the user across workspaces
///   KeepOnTop        floating
///   Floating         wmaker-wl extension, overrides the two above
///   StartMaximized   the new column fills the work area
///   Unfocusable      never takes keyboard focus
pub fn placeNew(wm: *WindowManager) void {
    var it = wm.windows.first();
    while (it) |win| : (it = types.nextWindow(win, wm)) {
        if (!win.new or win.closed) continue;
        const out = targetOutput(wm) orelse continue;

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
        // `maximize_keep_focus`: a window that is on a maximized column keeps
        // the focus, the new tiled window opens beside it, unseen.
        const hold = holdsFocus(wm, ws);
        const prev_col = ws.strip.active;
        const prev_win: ?*Window = if (prev_col) |c| c.focused else null;
        const floating = attrs.floating orelse
            (wantsFloating(win) or attrs.is("omnipresent") or attrs.is("keep_on_top"));

        if (floating) {
            // Fixed-size windows keep the size they asked for.
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
            // other window holds the focus. (With nothing focused, the new
            // window still takes it, or the keyboard would have no target.)
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

/// Output new windows go to: the one with the focused window, else first.
fn targetOutput(wm: *WindowManager) ?*Output {
    return types.workingOutput(wm);
}

// ----------------------------------------------------------------------------
// Removal
// ----------------------------------------------------------------------------

/// Destroy windows river reported closed. Manage only.
pub fn reap(wm: *WindowManager) void {
    var it = wm.windows.first();
    while (it) |win| {
        const next = types.nextWindow(win, wm);
        if (win.closed) destroy(wm, win);
        it = next;
    }
    var dit = wm.dock_windows.first();
    while (dit) |win| {
        const next = types.nextDockWindow(win, wm);
        if (win.closed) destroy(wm, win);
        dit = next;
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

fn destroy(wm: *WindowManager, win: *Window) void {
    log.debug("window `{s}` is gone", .{win.app_id orelse "?"});
    const ws = win.workspace;
    // Only the window that HAD the focus hands it on. (Any window of the
    // shown workspace used to: closing a background dialog moved the focus.)
    const was_focus_target = if (ws) |w| w.output.ws() == w and hadFocus(wm, win) else false;

    workspace.unplace(wm, win);
    seatmod.forgetWindow(wm, win);

    // If the closed window held the focus request, pick a new one.
    if (wm.focus_request == win) wm.focus_request = null;
    if (wm.pending_fullscreen) |pf| if (pf.win == win) {
        wm.pending_fullscreen = null;
    };
    // The root menu may hold this window (window list, focus to return).
    if (wm.pending_ui) |req| switch (req) {
        .focus => |w| if (w == win) {
            wm.pending_ui = null;
        },
        else => {},
    };
    if (wm.ui) |u| u.forgetWindow(win);

    types.unlink(&win.link);
    win.node.destroy();
    win.obj.destroy();
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

// ----------------------------------------------------------------------------
// Management state
// ----------------------------------------------------------------------------

fn isVisible(win: *const Window) bool {
    const ws = win.workspace orelse return false;
    if (win.isOmnipresent()) return true;
    return ws.output.active == ws.index and !win.closed;
}

/// Send management-state requests. Requires that layout.compute() already
/// ran for every visible workspace.
pub fn applyManage(wm: *WindowManager, win: *Window) void {
    const ws = win.workspace orelse return;
    const cfg = &wm.cfg;

    // Windows on a hidden workspace were not laid out this pass, so their
    // `target` is stale. Proposing it would resize them to old geometry;
    // they get a fresh proposal the moment their workspace is shown.
    if (!win.isOmnipresent() and ws.output.active != ws.index) return;
    if (win.closed) return;

    // Fullscreen is a management request. Send it only on change.
    const want_fs: ?*Output = if (win.mode == .fullscreen) ws.output else null;
    if (want_fs != win.sent_fullscreen) {
        if (want_fs) |out| {
            win.obj.fullscreen(out.obj);
            win.obj.informFullscreen();
        } else {
            win.obj.exitFullscreen();
            win.obj.informNotFullscreen();
            // Position and size are undefined after exit_fullscreen until
            // we propose again; force it below.
            win.sent_w = -1;
            win.sent_h = -1;
        }
        win.sent_fullscreen = want_fs;
    }

    if (win.mode == .fullscreen) return; // river owns fullscreen geometry

    // Server-side decorations are chosen once, before the first commit.
    if (win.sent_tiled == null) {
        if (cfg.prefer_no_csd) win.obj.useSsd() else win.obj.useCsd();
    }

    // Tiled windows tell the client so (it drops rounded corners / shadows
    // and sizes to the slot); floating windows must NOT be told they are
    // tiled.
    const tiled = win.mode == .tiled;
    if (win.sent_tiled != tiled) {
        win.obj.setTiled(if (tiled)
            .{ .top = true, .bottom = true, .left = true, .right = true }
        else
            .{});
        win.sent_tiled = tiled;
    }

    // Propose only when the wanted size changed (or was never sent).
    const size = win.clampSize(win.target.w, win.target.h, cfg.min_window_size);
    win.target.w = size.w;
    win.target.h = size.h;
    if (size.w != win.sent_w or size.h != win.sent_h) {
        win.obj.proposeDimensions(size.w, size.h);
        win.sent_w = size.w;
        win.sent_h = size.h;
    }
}

// ----------------------------------------------------------------------------
// Rendering state
// ----------------------------------------------------------------------------

pub fn applyRender(wm: *WindowManager, win: *Window, focused: bool) void {
    const cfg = &wm.cfg;

    // A window that is coming back from the Dock stays hidden until the
    // animation of its frame is over (Window Maker maps it afterwards).
    const held = if (wm.ui) |u| u.animHolding(win) else false;
    if (held or !isVisible(win)) {
        stopAnimations(win);
        if (win.visible != false) {
            log.debug("window `{s}` hidden", .{win.app_id orelse "?"});
            win.obj.hide();
            win.visible = false;
        }
        return;
    }
    if (win.visible != true) {
        log.debug("window `{s}` shown", .{win.app_id orelse "?"});
        win.obj.show();
        win.visible = true;
    }

    if (win.mode == .fullscreen) {
        // river positions it. Borders are not drawn in fullscreen.
        stopAnimations(win);
        if (win.ready) win.opened = true; // leaving fullscreen is not an opening
        if (focused) win.node.placeTop();
        return;
    }

    // Position. Sent only on change; a tiled window's position changes on
    // every scroll step, a floating one on every drag step. While a window
    // travels (animation.zig) this is where it is now, not `target`.
    const vis = visualState(wm, win);
    if (vis.x != win.sent_x or vis.y != win.sent_y) {
        win.node.setPosition(vis.x, vis.y);
        win.sent_x = vis.x;
        win.sent_y = vis.y;
    }

    // Borders (rendering state). Colours come from config.
    const kind: types.BorderKind = if (win.borderWidth(cfg) == 0)
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
    if (shown != win.sent_border) {
        setBorders(win, shown, cfg);
        win.sent_border = shown;
    }

    applyClip(wm, win, .{ .x = vis.x, .y = vis.y, .w = win.target.w, .h = win.target.h }, vis.reveal);

    if (focused) win.node.placeTop();
}

// ----------------------------------------------------------------------------
// Animations
// ----------------------------------------------------------------------------
//
// The layout only knows where a window belongs (`target`); what is shown is
// decided here, in the one place that sends the position. Two animations:
//
//   movement  a tiled window whose `target` changed travels to it, on a
//             spring (`anim_window_movement`). This covers a column that makes
//             room for a new one, the gap a closed window leaves, scrolling the
//             view and resizing a column. It starts where the window is NOW, so
//             a new target in mid-flight turns around without a jump.
//   open      a window that appears is uncovered from its middle
//             (`anim_window_open`), by growing its clip box. river has no
//             opacity or scale for a window, so this is what the protocol
//             allows.
//
// A window that closes cannot be animated: river has already dropped its
// surface when `closed` arrives. Its neighbours still close the gap (movement).
//
// What does not animate: windows that appear on a workspace switch (they
// jump, like before), floating windows (they follow the pointer when dragged),
// and anything while a pointer drag is going on.

pub const Visual = struct { x: i32, y: i32, reveal: f64 };

/// Frame interval of the animations while something moves (about 60 Hz).
pub const frame_ms: u64 = 16;

/// Real time in milliseconds, on a clock that only goes forward.
fn realMs(wm: *const WindowManager) u64 {
    const ts = std.Io.Clock.awake.now(wm.io);
    return @intCast(@max(0, ts.toMilliseconds()));
}

/// Feed the animation clock; once per manage / render sequence, before the
/// windows are looked at (all animations of a sequence see the same moment).
pub fn tickClock(wm: *WindowManager) void {
    wm.clock.setSlowdown(wm.cfg.anim_slowdown);
    wm.clock.advance(realMs(wm));
    if (tracing(wm)) anim_log.debug("tick real={d} clock={d:.1} active={}", .{ realMs(wm), wm.clock.now(), wm.anim_active });
}

/// Diagnostics: from the moment a window starts to open until 1.5 s later,
/// the animation code says at info level what it does (ticks, frame requests,
/// clip boxes), with real time stamps, so a log shows where a frame is lost.
var trace_until: u64 = 0;

fn tracing(wm: *const WindowManager) bool {
    return realMs(wm) < trace_until;
}

/// How long the event loop may sleep before the next frame of a running
/// animation is due. null: nothing moves.
pub fn animWaitMs(wm: *const WindowManager) ?i32 {
    if (!wm.anim_active) return null;
    return frameWait(wm.anim_frame_at, realMs(wm));
}

fn frameWait(due: u64, now: u64) i32 {
    return @intCast(@min(due -| now, frame_ms));
}

/// When the frame after the one asked for at `now` is due, `prev` being the
/// deadline of the one asked for. Counted from `prev`, not from `now`, so a
/// frame that came a few ms late does not push every later one back (the
/// cadence used to drift from 16 towards 20 ms); a frame more than half a
/// frame late starts the grid again from `now`.
pub fn nextFrameAt(prev: u64, now: u64) u64 {
    const grid = prev + frame_ms;
    return if (grid >= now + frame_ms / 2) grid else now + frame_ms;
}

/// Called by the event loop after every wake-up: when something still moves
/// and the next frame is due, ask for a manage sequence (it draws the frame
/// and sets `anim_active` again if the movement goes on).
pub fn animTimer(wm: *WindowManager) void {
    if (!wm.anim_active) {
        if (tracing(wm)) anim_log.debug("timer: nothing is active (real={d})", .{realMs(wm)});
        return;
    }
    const now = realMs(wm);
    if (now < wm.anim_frame_at) return;
    wm.anim_active = false;
    wm.anim_frame_at = nextFrameAt(wm.anim_frame_at, now);
    anim_log.debug("timer asks for a frame (manage_dirty) real={d}", .{now});
    wm.obj.manageDirty();
}

/// Forget everything about how the window moved (it is hidden, or river
/// owns its geometry): the next time it is shown it appears where it belongs.
fn stopAnimations(win: *Window) void {
    win.anim_x = null;
    win.anim_y = null;
    win.open_anim = null;
    win.has_shown = false;
}

/// A pointer drag is going on that must not be smoothed: the window being
/// dragged follows the pointer, and while a column is resized by hand its
/// neighbours follow the edge.
fn dragBlocks(wm: *WindowManager, win: *const Window) bool {
    var it = wm.seats.first();
    while (it) |s| : (it = types.nextSeat(s, wm)) {
        if (s.op_state == .idle) continue;
        if (s.op_window == win or s.op == .resize) return true;
    }
    return false;
}

/// One axis: restart towards `want` when the destination changed (from where
/// the window is now), and give the position for this moment.
fn axis(spec: animation.Spec, anim: *?animation.Animation, shown: i32, goal: *i32, want: i32, now: f64) i32 {
    if (want != goal.*) {
        goal.* = want;
        anim.* = animation.Animation.init(spec, @floatFromInt(shown), @floatFromInt(want), 0, now);
        anim_log.debug("movement {d} -> {d} (clock {d:.1})", .{ shown, want, now });
    }
    if (anim.*) |a| {
        if (!a.isDone(now)) return @intFromFloat(@round(a.valueAt(now)));
        anim.* = null;
        anim_log.debug("movement arrived at {d}", .{want});
    }
    return want;
}

/// Where `win` is drawn at this moment, and how much of it is uncovered.
/// Also keeps `wm.anim_active` up to date.
pub fn visualState(wm: *WindowManager, win: *Window) Visual {
    const cfg = &wm.cfg;
    const now = wm.clock.now();
    var vis: Visual = .{ .x = win.target.x, .y = win.target.y, .reveal = 1.0 };

    // ---- movement
    const travels = cfg.animations and !cfg.anim_window_movement.isOff() and
        win.mode == .tiled and win.has_shown and win.anim_ws == win.workspace and !dragBlocks(wm, win);
    if (travels) {
        vis.x = axis(cfg.anim_window_movement, &win.anim_x, win.shown_x, &win.goal_x, win.target.x, now);
        vis.y = axis(cfg.anim_window_movement, &win.anim_y, win.shown_y, &win.goal_y, win.target.y, now);
    } else {
        win.anim_x = null;
        win.anim_y = null;
        win.goal_x = win.target.x;
        win.goal_y = win.target.y;
    }
    win.shown_x = vis.x;
    win.shown_y = vis.y;
    win.has_shown = true;
    win.anim_ws = win.workspace;

    // ---- open: wait for the first content, so the animation is not spent
    // on a window that has nothing to show yet.
    if (!win.opened and win.ready) {
        win.opened = true;
        if (cfg.animations and wm.obj_version >= 2) {
            win.open_anim = animation.Animation.init(cfg.anim_window_open, 0.0, 1.0, 0.0, now);
            if (win.open_anim != null) {
                trace_until = realMs(wm) + 1500;
                anim_log.debug("window `{s}` opens ({d}x{d}) real={d} clock={d:.1}", .{ win.app_id orelse "?", win.target.w, win.target.h, realMs(wm), now });
            }
        }
    }
    if (win.open_anim) |a| {
        if (a.isDone(now) or !cfg.animations) {
            win.open_anim = null;
            anim_log.debug("open animation finished real={d} clock={d:.1}", .{ realMs(wm), now });
        } else {
            vis.reveal = std.math.clamp(a.valueAt(now), 0.0, 1.0);
            anim_log.debug("open frame reveal={d:.3} clock={d:.1} real={d}", .{ vis.reveal, now, realMs(wm) });
        }
    }

    if (win.anim_x != null or win.anim_y != null or win.open_anim != null) wm.anim_active = true;
    return vis;
}

/// The part of the window to show, relative to its top left corner: the
/// work area cuts what scrolled under the Dock (null: nothing to cut), and
/// while a window opens only the middle `reveal` (0..1) of its frame is
/// uncovered (content plus `bw` of border). Never a 0 size: that would turn
/// clipping off.
pub fn visibleBox(vis: types.Rect, bw: i32, work: ?types.Rect, reveal: f64) ?types.Rect {
    const cut: ?types.Rect = if (work) |w| clipBox(vis, bw, w) else null;
    if (reveal >= 1.0) return cut;

    const p = std.math.clamp(reveal, 0.0, 1.0);
    const fw = vis.w + 2 * bw;
    const fh = vis.h + 2 * bw;
    const rw: i32 = @max(1, @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(fw)) * p))));
    const rh: i32 = @max(1, @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(fh)) * p))));
    var box: types.Rect = .{
        .x = -bw + @divTrunc(fw - rw, 2),
        .y = -bw + @divTrunc(fh - rh, 2),
        .w = rw,
        .h = rh,
    };

    if (cut) |c| {
        const x0 = @max(box.x, c.x);
        const y0 = @max(box.y, c.y);
        const x1 = @min(box.x + box.w, c.x + c.w);
        const y1 = @min(box.y + box.h, c.y + c.h);
        if (x1 <= x0 or y1 <= y0) return .{ .x = vis.w + bw + 16, .y = vis.h + bw + 16, .w = 1, .h = 1 };
        box = .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
    }
    return box;
}

/// Clip a tiled window to the work area, so a column scrolled sideways
/// slides *under the edge of the work area* (next to the Dock) instead of
/// under the Dock. Floating windows are not clipped. river_window_v1
/// set_clip_box needs version 2; without it nothing is clipped.
fn applyClip(wm: *WindowManager, win: *Window, vis: types.Rect, reveal: f64) void {
    if (wm.obj_version < 2) return;
    const ws = win.workspace orelse return;

    const work: ?types.Rect = if (win.mode == .tiled) ws.output.workArea() else null;
    const want = visibleBox(vis, win.borderWidth(&wm.cfg), work, reveal);

    if (std.meta.eql(want, win.sent_clip)) return;
    if (want) |b| {
        anim_log.debug("set_clip_box {d},{d} {d}x{d} reveal={d:.3}", .{ b.x, b.y, b.w, b.h, reveal });
    } else {
        anim_log.debug("set_clip_box off (reveal={d:.3})", .{reveal});
    }
    if (want) |b| {
        win.obj.setClipBox(b.x, b.y, b.w, b.h);
    } else {
        win.obj.setClipBox(0, 0, 0, 0); // size 0 = no clipping
    }
    win.sent_clip = want;
}

/// The part of a window (content `target` plus `bw` of border on each side)
/// that lies inside `work`, relative to the window's top left corner.
/// null = it lies completely inside, nothing to clip. A window completely
/// outside gets a 1x1 box that does not touch it (a 0 size would turn
/// clipping off).
pub fn clipBox(target: types.Rect, bw: i32, work: types.Rect) ?types.Rect {
    const x0 = @max(target.x - bw, work.x);
    const y0 = @max(target.y - bw, work.y);
    const x1 = @min(target.right() + bw, work.right());
    const y1 = @min(target.bottom() + bw, work.bottom());
    if (x1 <= x0 or y1 <= y0) {
        return .{ .x = target.w + bw + 16, .y = target.h + bw + 16, .w = 1, .h = 1 };
    }
    if (x0 == target.x - bw and y0 == target.y - bw and x1 == target.right() + bw and y1 == target.bottom() + bw) {
        return null;
    }
    return .{ .x = x0 - target.x, .y = y0 - target.y, .w = x1 - x0, .h = y1 - y0 };
}

test "clipBox: inside = no clip, scrolled under the Dock = cut at the edge, outside = nothing" {
    const work: types.Rect = .{ .x = 64, .y = 0, .w = 936, .h = 800 };
    try std.testing.expectEqual(@as(?types.Rect, null), clipBox(.{ .x = 100, .y = 10, .w = 400, .h = 300 }, 2, work));
    // Starts 36px left of the work area (x = 28): the left 36px are cut.
    const c = clipBox(.{ .x = 28, .y = 10, .w = 400, .h = 300 }, 0, work).?;
    try std.testing.expectEqual(@as(i32, 36), c.x);
    try std.testing.expectEqual(@as(i32, 364), c.w);
    try std.testing.expectEqual(@as(i32, 300), c.h);
    // Completely under the Dock strip.
    const o = clipBox(.{ .x = -400, .y = 10, .w = 400, .h = 300 }, 0, work).?;
    try std.testing.expectEqual(@as(i32, 1), o.w);
    try std.testing.expect(o.x >= 400);
}

/// river takes 32-bit RGBA per channel, premultiplied; 0xffffffff = 100 %.
fn channel(byte: u32) u32 {
    return byte * 0x01010101;
}

fn setBorders(win: *Window, kind: types.BorderKind, cfg: *const config.Config) void {
    const rgb: u32 = switch (kind) {
        .focused => cfg.border_focused,
        .unfocused => cfg.border_unfocused,
        .floating => cfg.border_floating,
        .none => {
            win.obj.setBorders(.{}, 0, 0, 0, 0, 0);
            return;
        },
    };
    win.obj.setBorders(
        .{ .top = true, .bottom = true, .left = true, .right = true },
        win.borderWidth(cfg),
        channel((rgb >> 16) & 0xff),
        channel((rgb >> 8) & 0xff),
        channel(rgb & 0xff),
        0xffffffff,
    );
}

test "channel scales 8 bit to 32 bit" {
    try std.testing.expectEqual(@as(u32, 0xffffffff), channel(0xff));
    try std.testing.expectEqual(@as(u32, 0), channel(0));
    try std.testing.expectEqual(@as(u32, 0x80808080), channel(0x80));
}

test "axis: a new destination starts from where the window is, arrives exactly" {
    const spec = animation.Spec.default_movement;
    var anim: ?animation.Animation = null;
    var goal: i32 = 0;

    // Same destination as before: no animation.
    try std.testing.expectEqual(@as(i32, 0), axis(spec, &anim, 0, &goal, 0, 0));
    try std.testing.expect(anim == null);

    // A column makes room: the window is to go to x = 400.
    try std.testing.expectEqual(@as(i32, 0), axis(spec, &anim, 0, &goal, 400, 1000));
    try std.testing.expect(anim != null);
    const mid = axis(spec, &anim, 0, &goal, 400, 1100);
    try std.testing.expect(mid > 0 and mid < 400);

    // The destination changes in mid-flight: it goes on from `mid`, no jump.
    const turned = axis(spec, &anim, mid, &goal, 100, 1100);
    try std.testing.expectEqual(mid, turned);
    try std.testing.expectEqual(@as(i32, 100), goal);

    // Long after: there, and nothing is running any more.
    try std.testing.expectEqual(@as(i32, 100), axis(spec, &anim, turned, &goal, 100, 5000));
    try std.testing.expect(anim == null);

    // "off": the destination is taken at once.
    var none: ?animation.Animation = null;
    var g2: i32 = 0;
    try std.testing.expectEqual(@as(i32, 300), axis(.off, &none, 0, &g2, 300, 0));
    try std.testing.expect(none == null);
}

test "visibleBox: fully open = the work area cut only; opening = a growing middle" {
    const work: types.Rect = .{ .x = 0, .y = 0, .w = 1000, .h = 800 };
    const win: types.Rect = .{ .x = 100, .y = 100, .w = 400, .h = 200 };

    // Fully open and inside the work area: nothing to clip.
    try std.testing.expectEqual(@as(?types.Rect, null), visibleBox(win, 2, work, 1.0));
    // No work area (a floating window): same.
    try std.testing.expectEqual(@as(?types.Rect, null), visibleBox(win, 2, null, 1.0));

    // Half open: half the frame (404 x 204 with the border), in the middle.
    const half = visibleBox(win, 2, null, 0.5).?;
    try std.testing.expectEqual(@as(i32, 202), half.w);
    try std.testing.expectEqual(@as(i32, 102), half.h);
    try std.testing.expectEqual(@as(i32, -2 + 101), half.x);
    try std.testing.expectEqual(@as(i32, -2 + 51), half.y);

    // Never 0 x 0 (that would switch clipping off).
    const first = visibleBox(win, 2, null, 0.0).?;
    try std.testing.expect(first.w >= 1 and first.h >= 1);

    // Opening AND scrolled under the Dock: the intersection of both.
    const dock_work: types.Rect = .{ .x = 150, .y = 0, .w = 850, .h = 800 };
    const both = visibleBox(win, 2, dock_work, 0.5).?;
    try std.testing.expect(both.x >= 150 - win.x);
    try std.testing.expect(both.w >= 1 and both.h >= 1);

    // Opening completely outside the work area: the harmless 1 x 1 box.
    const out = visibleBox(.{ .x = 2000, .y = 0, .w = 100, .h = 100 }, 0, work, 0.5).?;
    try std.testing.expectEqual(@as(i32, 1), out.w);
}

test "nextFrameAt: on a 16 ms grid, small delays do not accumulate" {
    // The first frame (nothing was asked for before): from now.
    try std.testing.expectEqual(@as(u64, 123_472), nextFrameAt(0, 123_456));
    // On time or a few ms late: the next one stays on the grid.
    try std.testing.expectEqual(@as(u64, 1016), nextFrameAt(1000, 1000));
    try std.testing.expectEqual(@as(u64, 1016), nextFrameAt(1000, 1003));
    try std.testing.expectEqual(@as(u64, 1016), nextFrameAt(1000, 1008));
    // More than half a frame late: a new grid, never two frames back to back.
    try std.testing.expectEqual(@as(u64, 1026), nextFrameAt(1000, 1010));
    try std.testing.expectEqual(@as(u64, 1516), nextFrameAt(1000, 1500));

    // Every wake-up 3 ms late for a second: 62 frames, not the 50 of "now + 16"
    // with a 4 ms round trip, and the grid does not move.
    var due: u64 = 1000;
    var frames: u32 = 0;
    while (due < 2000) : (frames += 1) {
        const now = due + 3;
        const next = nextFrameAt(due, now);
        try std.testing.expectEqual(due + frame_ms, next);
        due = next;
    }
    try std.testing.expect(frames >= 62);
}

test "frameWait: never longer than one frame, 0 when due" {
    try std.testing.expectEqual(@as(i32, 0), frameWait(100, 100));
    try std.testing.expectEqual(@as(i32, 0), frameWait(100, 500));
    try std.testing.expectEqual(@as(i32, 7), frameWait(107, 100));
    try std.testing.expectEqual(@as(i32, frame_ms), frameWait(10_000, 100));
}

test "a window arrives only while the clock runs: frames advance it to its target" {
    const spec = animation.Spec.default_movement;
    var clock: animation.Clock = .{};
    var anim: ?animation.Animation = null;
    var goal: i32 = 0;
    var shown: i32 = 0;

    clock.advance(5000);
    shown = axis(spec, &anim, shown, &goal, 400, clock.now());
    try std.testing.expectEqual(@as(i32, 0), shown);

    // A stopped clock (the old bug: tickClock never ran) never gets there.
    shown = axis(spec, &anim, shown, &goal, 400, clock.now());
    try std.testing.expect(anim != null and shown == 0);

    // 16 ms frames: monotonic, and exactly at the target in the end.
    var t: u64 = 5000;
    var prev: i32 = shown;
    var frames: u32 = 0;
    while (anim != null and frames < 1000) : (frames += 1) {
        t += frame_ms;
        clock.advance(t);
        shown = axis(spec, &anim, shown, &goal, 400, clock.now());
        try std.testing.expect(shown >= prev and shown <= 400);
        prev = shown;
    }
    try std.testing.expectEqual(@as(i32, 400), shown);
    try std.testing.expect(frames < 100);
}

test "opening: 16 ms frames uncover the window, and no clip box is left at the end" {
    const work: types.Rect = .{ .x = 64, .y = 0, .w = 936, .h = 800 };
    const win: types.Rect = .{ .x = 100, .y = 50, .w = 400, .h = 300 };
    var clock: animation.Clock = .{};
    clock.advance(1000);
    const a = animation.Animation.init(animation.Spec.default_open, 0.0, 1.0, 0.0, clock.now()).?;

    // First frame, same moment as the start: nothing uncovered yet, but the
    // box is never 0 x 0 (that would switch clipping off and show it all).
    var reveal = std.math.clamp(a.valueAt(clock.now()), 0.0, 1.0);
    try std.testing.expectEqual(@as(f64, 0), reveal);
    const first = visibleBox(win, 2, work, reveal).?;
    try std.testing.expect(first.w >= 1 and first.h >= 1);

    var t: u64 = 1000;
    var prev: f64 = 0;
    var frames: u32 = 0;
    while (frames < 100) : (frames += 1) {
        t += frame_ms;
        clock.advance(t);
        if (a.isDone(clock.now())) break;
        reveal = std.math.clamp(a.valueAt(clock.now()), 0.0, 1.0);
        try std.testing.expect(reveal >= prev);
        prev = reveal;
        const box = visibleBox(win, 2, work, reveal).?;
        try std.testing.expect(box.w >= 1 and box.h >= 1);
        try std.testing.expect(box.w <= win.w + 4 and box.h <= win.h + 4);
    }
    // 250 ms at 16 ms per frame: about sixteen frames, certainly fewer than 24.
    try std.testing.expect(frames < 24);
    try std.testing.expect(a.isDone(clock.now()));
    // Done: reveal is 1 and the window is not clipped at all.
    try std.testing.expectEqual(@as(?types.Rect, null), visibleBox(win, 2, work, 1.0));
}

test "opening: a stopped clock never uncovers the window, a late frame does at once" {
    var clock: animation.Clock = .{};
    clock.advance(1000);
    const a = animation.Animation.init(animation.Spec.default_open, 0.0, 1.0, 0.0, clock.now()).?;

    // The clock is only read by `tickClock`; without it nothing ever moves.
    try std.testing.expect(!a.isDone(clock.now()));
    try std.testing.expectEqual(@as(f64, 0), a.valueAt(clock.now()));
    clock.advance(1000);
    try std.testing.expectEqual(@as(f64, 0), a.valueAt(clock.now()));

    // One late frame (the machine was busy for 6 s) and it is all there.
    clock.advance(7000);
    try std.testing.expect(a.isDone(clock.now()));
    try std.testing.expectEqual(@as(f64, 1), a.valueAt(clock.now()));
}

test "opening: \"off\" has no animation, so the window is shown at once" {
    try std.testing.expect(animation.Animation.init(.off, 0.0, 1.0, 0.0, 0.0) == null);
}

test "visibleBox: while opening, the box always lies inside the window frame" {
    const win: types.Rect = .{ .x = 100, .y = 100, .w = 333, .h = 777 };
    const bw: i32 = 3;
    var step: u32 = 0;
    while (step < 20) : (step += 1) {
        const p: f64 = @as(f64, @floatFromInt(step)) / 20.0;
        const b = visibleBox(win, bw, null, p).?;
        try std.testing.expect(b.w >= 1 and b.h >= 1);
        try std.testing.expect(b.x >= -bw and b.y >= -bw);
        try std.testing.expect(b.x + b.w <= win.w + bw);
        try std.testing.expect(b.y + b.h <= win.h + bw);
    }
}
