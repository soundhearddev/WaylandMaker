// SPDX-License-Identifier: GPL-3.0
//
// dockhost: how DockApps live in the compositor. The one place that decides
// anything about them.
//
// A DockApp is not a window in the sense of this compositor. It is an icon:
// Window Maker keeps it out of the window list, the layout, the focus and the
// keyboard, and shows it only inside its tile. The same holds here, and the
// DockApp does not have to hope for it, because it is declared by a tag:
//
//     the app_id is `dockapp:<name>`  (dockapp.isSelfDeclared)
//
// That tag is the whole protocol. What it brings with it:
//
//   * `Window.role = .dockapp`, decided once, when the tag arrives (`adopt`),
//     however late that is. The window moves from `wm.windows` to
//     `wm.dock_windows`, so every loop over the windows -- layout, focus,
//     cycling, close, hide, kill, the window menu -- never sees it. There is
//     no flag to check and none to forget.
//   * The compositor, not the client, decides where it is and how big it is:
//     what it asked for, at most one tile, centred in the Dock tile of its
//     name, above the Dock, on every workspace, without borders. It cannot
//     be moved, resized, fullscreened, focused or closed by a key.
//   * A DockApp without a tile gets a temporary one for as long as it runs
//     (Model.attach); a tile made permanent ("Keep Icon") starts it again
//     (AutoLaunch, or a click).
//
// Everything that sends a request for such a window is in `apply`. ui.zig
// only says where the Dock is (`Host`) and what the tiles are (the Model).

const std = @import("std");
const log = std.log.scoped(.dockhost);
const wayland = @import("wayland");
const river = wayland.client.river;

const types = @import("types.zig");
const dockapp = @import("dockapp.zig");
const dock_mod = @import("dock.zig");
const workspace = @import("workspace.zig");
const seatmod = @import("seat.zig");

const Window = types.Window;
const WindowManager = types.WindowManager;

/// Does this app_id declare a DockApp?
pub fn isDockApp(app_id: ?[]const u8) bool {
    return dockapp.isSelfDeclared(app_id);
}

// ----------------------------------------------------------------------------
// Role
// ----------------------------------------------------------------------------

/// Make `win` a DockApp: out of every strip, off the focus, out of the
/// window list. Safe at any time: for a window that was just created, for
/// one that was already placed (the tag arrived late) and for one that is a
/// DockApp already. Model changes only; no request is sent here.
pub fn adopt(wm: *WindowManager, win: *Window) void {
    if (win.role == .dockapp) return;

    workspace.unplace(wm, win);
    seatmod.forgetWindow(wm, win);
    if (wm.focus_request == win) wm.focus_request = null;
    if (wm.pending_fullscreen) |pf| if (pf.win == win) {
        wm.pending_fullscreen = null;
    };
    if (wm.pending_ui) |req| switch (req) {
        .focus => |w| if (w == win) {
            wm.pending_ui = null;
        },
        else => {},
    };
    if (wm.ui) |u| u.forgetWindow(win);

    types.unlink(&win.link);
    wm.dock_windows.append(win);

    win.role = .dockapp;
    log.debug("`{s}` is a DockApp: an icon in the Dock, not a window", .{win.app_id orelse "?"});
    win.new = false;
    win.minimized = false;
    win.sticky = false;
    win.mode = .floating;
    // Whatever was sent to river for a normal window says nothing about
    // this one: send position, size and decoration again.
    win.sent_tiled = null;
    win.sent_border = null;
    win.sent_w = -1;
    win.sent_h = -1;
    win.sent_x = std.math.minInt(i32);
    win.sent_y = std.math.minInt(i32);
}

// ----------------------------------------------------------------------------
// Geometry (pure)
// ----------------------------------------------------------------------------

pub const Size = struct { w: i32, h: i32 };

/// The size a DockApp is given: what it asked for, never more than a tile.
/// No hint means a whole tile. (A minimum above a tile cannot be honoured
/// inside the tile; the window then overflows it rather than being cut.)
pub fn hostedSize(min_w: i32, min_h: i32, max_w: i32, max_h: i32) Size {
    const w = if (max_w > 0) @min(max_w, dock_mod.tile) else dock_mod.tile;
    const h = if (max_h > 0) @min(max_h, dock_mod.tile) else dock_mod.tile;
    return .{ .w = @max(w, min_w), .h = @max(h, min_h) };
}

/// Global rectangle of a `w` x `h` window centred in the tile whose top-left
/// is the output-local (tx, ty) of the output at `out`.
pub fn tileRect(out: types.Rect, tx: i32, ty: i32, w: i32, h: i32) types.Rect {
    return .{
        .x = out.x + tx + @divTrunc(dock_mod.tile - w, 2),
        .y = out.y + ty + @divTrunc(dock_mod.tile - h, 2),
        .w = w,
        .h = h,
    };
}

// ----------------------------------------------------------------------------
// The Dock's side of it
// ----------------------------------------------------------------------------

/// What ui.zig tells the host each pass about the Dock.
pub const Host = struct {
    /// The tiles. null: there is no Dock.
    model: ?*dock_mod.Model = null,
    /// The output the Dock is shown on; null while it is not shown.
    out: ?*types.Output = null,
    /// The Dock's surface node: DockApps are stacked right above it.
    panel: ?*river.NodeV1 = null,
    /// The Dock is above the normal windows (then so are its DockApps).
    raised: bool = false,
};

/// The last minimized window whose tile could not be made, so the warning
/// comes once per window and not with every sync.
var warned_order: u64 = 0;

/// `s` cut to at most `max` bytes, never inside a UTF-8 character.
fn cutUtf8(s: []const u8, max: usize) []const u8 {
    var end = @min(s.len, max);
    while (end > 0 and end < s.len and (s[end] & 0xC0) == 0x80) end -= 1;
    return s[0..end];
}

/// Give every DockApp a tile and keep the tiles in step with the programs:
///   * a DockApp without an entry gets a temporary tile;
///   * every minimized window gets a temporary tile of its own (`mini_dock`),
///     showing its program's icon, and loses it when it is restored;
///   * a tile is `running` while a window of its application exists (a
///     DockApp's too: the tile shows no "not running" dots then);
///   * a temporary tile goes with its program.
/// True if the model changed.
pub fn syncModel(wm: *WindowManager, m: *dock_mod.Model) bool {
    var changed = false;

    var dit = wm.dock_windows.first();
    while (dit) |w| : (dit = types.nextDockWindow(w, wm)) {
        if (w.closed) continue;
        const id = w.app_id orelse continue;
        const name = dockapp.declaredName(id) orelse continue;
        if (!dockapp.validAppId(name) or m.dockSlotFor(id) != null) continue;
        if (m.attach(name)) |_| {
            log.debug("temporary Dock tile for `{s}`", .{name});
            changed = true;
        } else |err| log.warn("dockapp `{s}` gets no tile: {t}", .{ name, err });
    }

    // Minimized windows: one tile each, in the order they were minimized.
    var live: std.ArrayList(u64) = .empty;
    defer live.deinit(wm.gpa);
    // False when `live` could not be filled completely (out of memory): the
    // tiles are then not pruned against a list that is missing windows, which
    // would drop the tiles of windows that are still minimized.
    var live_complete = true;
    if (wm.cfg.mini_dock) {
        var mit = wm.windows.first();
        while (mit) |w| : (mit = types.nextWindow(w, wm)) {
            if (!w.minimized or w.closed or w.min_order == 0) continue;
            live.append(wm.gpa, w.min_order) catch {
                live_complete = false;
                break;
            };
            if (m.miniSlotFor(w.min_order) != null) continue;
            const raw: []const u8 = w.app_id orelse w.title orelse "window";
            const name = cutUtf8(raw, 64);
            if (m.attachWindow(name, w.app_id, w.min_order)) |idx| {
                changed = true;
                log.debug("Dock tile for the minimized window `{s}` (row {d})", .{ name, m.slots.items[idx].gi.yindex });
            } else |err| {
                if (warned_order != w.min_order) {
                    warned_order = w.min_order;
                    log.warn("the minimized window `{s}` gets no Dock tile: {t} (is the Dock full for this screen height?)", .{ name, err });
                }
            }
        }
    }
    if (live_complete and m.pruneMinimized(live.items)) changed = true;

    var ids: std.ArrayList([]const u8) = .empty;
    defer ids.deinit(wm.gpa);
    var nit = wm.windows.first();
    while (nit) |w| : (nit = types.nextWindow(w, wm)) {
        if (w.closed) continue;
        const id = w.app_id orelse continue;
        ids.append(wm.gpa, id) catch return changed;
    }
    dit = wm.dock_windows.first();
    while (dit) |w| : (dit = types.nextDockWindow(w, wm)) {
        if (w.closed) continue;
        const id = w.app_id orelse continue;
        ids.append(wm.gpa, id) catch return changed;
    }
    if (m.setRunning(ids.items)) changed = true;
    if (m.pruneAttached()) changed = true;
    return changed;
}

/// The DockApp window that belongs to `app`'s tile, if one is running.
pub fn hostFor(wm: *WindowManager, app: *const dockapp.DockApp) ?*Window {
    var it = wm.dock_windows.first();
    while (it) |w| : (it = types.nextDockWindow(w, wm)) {
        if (w.closed) continue;
        const id = w.app_id orelse continue;
        if (app.matches(id)) return w;
    }
    return null;
}

/// "Kill" on a tile: ask its DockApp to close. (The only way to end one
/// from the compositor's side.)
pub fn closeFor(wm: *WindowManager, app: *const dockapp.DockApp) void {
    var it = wm.dock_windows.first();
    while (it) |w| : (it = types.nextDockWindow(w, wm)) {
        if (w.closed) continue;
        const id = w.app_id orelse continue;
        if (app.matches(id)) w.obj.close();
    }
}

/// Session end: ask every DockApp to close.
pub fn closeAll(wm: *WindowManager) void {
    var it = wm.dock_windows.first();
    while (it) |w| : (it = types.nextDockWindow(w, wm)) {
        if (!w.closed) w.obj.close();
    }
}

/// Hidden (not placed) because `why`: logged once per change, so a DockApp
/// that does not show up says why.
fn hide(win: *Window, why: []const u8) void {
    if (win.visible != false) {
        log.warn("DockApp `{s}` is not shown: {s}", .{ win.app_id orelse "?", why });
        win.obj.hide();
        win.visible = false;
    }
}

/// Send everything river needs to know about the DockApps: decoration, size,
/// position, visibility, stacking. Idempotent and cheap; called in the
/// manage and the render sequence, like the normal windows are.
pub fn apply(wm: *WindowManager, host: Host) void {
    // The tiles that already have a DockApp in them this pass: a second
    // instance (same app_id) would be drawn right on top of the first, so
    // only the oldest is shown until it goes away.
    var used: [max_hosted]usize = undefined;
    var n_used: usize = 0;
    var it = wm.dock_windows.first();
    while (it) |w| : (it = types.nextDockWindow(w, wm)) {
        if (w.closed) continue;
        applyOne(w, host, &used, &n_used);
    }
}

/// How many DockApps are tracked for the "one per tile" rule; further ones
/// are simply not checked.
const max_hosted = 64;

fn applyOne(win: *Window, host: Host, used: *[max_hosted]usize, n_used: *usize) void {
    const out = host.out orelse return hide(win, "there is no Dock on an output (dock_enabled = false?)");
    const m = host.model orelse return hide(win, "the Dock has no model");
    const id = win.app_id orelse return hide(win, "no app_id");
    const idx = m.dockSlotFor(id) orelse return hide(win, "no Dock tile for it (invalid name, or the Dock is full)");
    const gi = m.slots.items[idx].gi;
    for (used[0..n_used.*]) |u| {
        if (u == idx) return hide(win, "another DockApp with the same name already sits in its tile");
    }
    if (n_used.* < used.len) {
        used[n_used.*] = idx;
        n_used.* += 1;
    }

    // The client draws everything itself and has one size.
    if (win.sent_tiled == null) {
        win.obj.useCsd();
        win.sent_tiled = false;
    }
    const size = hostedSize(win.min_w, win.min_h, win.max_w, win.max_h);
    if (size.w != win.sent_w or size.h != win.sent_h) {
        win.obj.proposeDimensions(size.w, size.h);
        win.sent_w = size.w;
        win.sent_h = size.h;
    }
    if (win.sent_border == null) {
        win.obj.setBorders(.{}, 0, 0, 0, 0, 0);
        win.sent_border = .none;
    }

    // Centred by the size it really has, in case it did not take ours.
    const w_now = if (win.actual_w > 0) win.actual_w else size.w;
    const h_now = if (win.actual_h > 0) win.actual_h else size.h;
    const r = tileRect(out.rect, gi.x_pos, gi.y_pos, w_now, h_now);
    if (r.x != win.sent_x or r.y != win.sent_y) {
        win.node.setPosition(r.x, r.y);
        win.sent_x = r.x;
        win.sent_y = r.y;
    }
    win.target = r;

    if (win.visible != true) {
        win.obj.show();
        win.visible = true;
    }
    if (host.raised) {
        win.node.placeTop();
    } else if (host.panel) |p| {
        win.node.placeAbove(p);
    }
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

test "isDockApp: the tag is the app_id and nothing else" {
    try std.testing.expect(isDockApp("dockapp:clock"));
    try std.testing.expect(isDockApp("dockapp-clock"));
    try std.testing.expect(!isDockApp("clock"));
    try std.testing.expect(!isDockApp("Dockapp:clock"));
    try std.testing.expect(!isDockApp(null));
}

test "hostedSize: what it asked for, at most a tile, a whole tile without a hint" {
    try std.testing.expectEqual(Size{ .w = 48, .h = 48 }, hostedSize(48, 48, 48, 48));
    try std.testing.expectEqual(Size{ .w = 64, .h = 64 }, hostedSize(0, 0, 0, 0));
    try std.testing.expectEqual(Size{ .w = 64, .h = 64 }, hostedSize(10, 10, 300, 300));
    try std.testing.expectEqual(Size{ .w = 32, .h = 64 }, hostedSize(0, 0, 32, 0));
    // A minimum above a tile is kept: the window overflows rather than breaks.
    try std.testing.expectEqual(Size{ .w = 100, .h = 64 }, hostedSize(100, 0, 100, 0));
}

test "tileRect centres the window in the tile of the output" {
    const out: types.Rect = .{ .x = 1920, .y = 0, .w = 1920, .h = 1080 };
    const r = tileRect(out, 1856, 128, 48, 48);
    try std.testing.expectEqual(@as(i32, 1920 + 1856 + 8), r.x);
    try std.testing.expectEqual(@as(i32, 128 + 8), r.y);
    try std.testing.expectEqual(@as(i32, 48), r.w);
    const full = tileRect(out, 0, 0, dock_mod.tile, dock_mod.tile);
    try std.testing.expectEqual(@as(i32, 1920), full.x);
    // Larger than the tile: it overflows evenly.
    const big = tileRect(out, 100, 100, 100, 64);
    try std.testing.expectEqual(@as(i32, 1920 + 100 - 18), big.x);
}

test "cutUtf8 never cuts inside a character" {
    try std.testing.expectEqualStrings("abc", cutUtf8("abcdef", 3));
    try std.testing.expectEqualStrings("abc", cutUtf8("abc", 10));
    try std.testing.expectEqualStrings("a", cutUtf8("aä", 2)); // ä is two bytes
    try std.testing.expectEqualStrings("aä", cutUtf8("aä", 3));
    try std.testing.expectEqualStrings("", cutUtf8("", 4));
}
