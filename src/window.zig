// SPDX-License-Identifier: 0BSD
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
const wayland = @import("wayland");
const river = wayland.client.river;

const types = @import("types.zig");
const config = @import("config.zig");
const workspace = @import("workspace.zig");
const layout = @import("layout.zig");
const seatmod = @import("seat.zig");
const dockapp = @import("dockapp.zig");

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
    return win;
}

fn find(wm: *WindowManager, obj: *river.WindowV1) ?*Window {
    var it = wm.windows.first();
    while (it) |w| : (it = types.nextWindow(w, wm)) {
        if (w.obj == obj) return w;
    }
    return null;
}

fn setString(wm: *WindowManager, dst: *?[]u8, src: ?[*:0]const u8) void {
    if (dst.*) |old| wm.gpa.free(old);
    dst.* = if (src) |s| wm.gpa.dupe(u8, std.mem.span(s)) catch null else null;
}

fn listener(obj: *river.WindowV1, event: river.WindowV1.Event, wm: *WindowManager) void {
    const win = find(wm, obj) orelse return;
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
            // Decoration attributes follow the real app_id; where the window
            // lives was decided when it was placed. A self-declared DockApp
            // (app_id "dockapp:..."/"dockapp-...", see dockapp.zig) gets
            // sensible tile defaults with NO config file needed; an explicit
            // attributes.conf rule for this app_id still wins per option
            // (Table.lookup already applies most-specific-first, and
            // withDefaults only fills what the file left unset).
            win.attrs = wm.attrs.lookup(win.app_id);
            if (dockapp.isSelfDeclared(win.app_id)) {
                win.attrs = win.attrs.withDefaults(dockapp.defaultAttrs());
            }
            // The app_id is very often the FIRST thing that reveals a
            // DockApp; if it shows up after first placement already
            // tiled it, float it now instead of leaving it stuck with a
            // full border for the rest of its life. See recheckFloating.
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

        const attrs_looked_up = wm.attrs.lookup(win.app_id);
        const attrs = if (dockapp.isSelfDeclared(win.app_id))
            attrs_looked_up.withDefaults(dockapp.defaultAttrs())
        else
            attrs_looked_up;
        win.attrs = attrs;

        var ws = out.ws();
        if (attrs.start_workspace) |sw| switch (sw) {
            .index => |i| {
                if (i < out.workspace_count) {
                    ws = &out.workspaces[i];
                } else {
                    std.log.warn("StartWorkspace {d} for `{s}`: only {d} workspaces exist", .{ i + 1, win.app_id orelse "?", out.workspace_count });
                }
            },
            .name => |n| std.log.warn("StartWorkspace `{s}`: workspace names are not supported yet, use a number", .{n}),
        };

        win.new = false;
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
                std.log.err("cannot place window: {t}", .{err});
                win.new = true;
                continue;
            };
            if (attrs.is("start_maximized")) {
                if (win.column) |col| workspace.toggleMaximized(wm, col);
            }
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
}

fn destroy(wm: *WindowManager, win: *Window) void {
    const ws = win.workspace;
    const was_focus_target = if (ws) |w| w.output.ws() == w else false;

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
    if (win.sent_tiled == null) win.obj.useSsd();

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

    if (!isVisible(win)) {
        if (win.visible != false) {
            win.obj.hide();
            win.visible = false;
        }
        return;
    }
    if (win.visible != true) {
        win.obj.show();
        win.visible = true;
    }

    if (win.mode == .fullscreen) {
        // river positions it. Borders are not drawn in fullscreen.
        if (focused) win.node.placeTop();
        return;
    }

    // Position. Sent only on change; a tiled window's position changes on
    // every scroll step, a floating one on every drag step.
    if (win.target.x != win.sent_x or win.target.y != win.sent_y) {
        win.node.setPosition(win.target.x, win.target.y);
        win.sent_x = win.target.x;
        win.sent_y = win.target.y;
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

    if (focused) win.node.placeTop();
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
