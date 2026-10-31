// SPDX-License-Identifier: GPL-3.0
//
// dockhost: how DockApps live in the compositor. The one place that decides
// anything about them. Model only: no wlroots, no drawing.
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
//   * `Window.role = .dockapp`, decided once, when the tag is seen (`adopt`),
//     however late that is. The window moves from `wm.windows` to
//     `wm.dock_windows`, so every loop over the windows -- layout, focus,
//     cycling, close, hide, kill, the window menu -- never sees it. There is
//     no flag to check and none to forget.
//   * The compositor, not the client, decides where it is and how big it is:
//     what it asked for, at most one tile, centred in the Dock tile of its
//     name, on every workspace, without borders. It cannot be moved, resized,
//     fullscreened, focused or closed by a key.
//   * A DockApp without a tile gets a temporary one for as long as it runs
//     (`Model.attach`); a tile made permanent ("Keep Icon") starts it again
//     (AutoLaunch, or a click).
//
// Per manage pass (manage.run):
//
//   `adopt`   every window that carries the tag becomes a DockApp
//   `update`  builds the Dock model when the config changed, lays it out on
//             the primary output, gives the tiles to the programs, and says
//             how much room the Dock takes (`Output.reserved`)
//   `apply`   tells the compositor where every DockApp goes
//
// The Dock itself (its surface, drawing and clicks) is the compositor's; it
// reads `wm.dock` and the `Host` that `update` returns.

const std = @import("std");
const log = std.log.scoped(.dockhost);

const types = @import("types.zig");
const config = @import("config.zig");
const dockapp = @import("dockapp.zig");
const dock_model = @import("dock_model.zig");
const workspace = @import("workspace.zig");
const backend = @import("backend.zig");
const manage = @import("manage.zig");
const action = @import("action.zig");

const Window = types.Window;
const Output = types.Output;
const WindowManager = types.WindowManager;

/// How long a tile stays `launching` when its program never shows a window.
pub const launch_timeout_ms: u32 = 8000;

/// Does this app_id declare a DockApp?
pub fn isDockApp(app_id: ?[]const u8) bool {
    return dockapp.isSelfDeclared(app_id);
}

// ----------------------------------------------------------------------------
// Role
// ----------------------------------------------------------------------------

/// Make `win` a DockApp: out of every strip, off the focus requests, out of
/// the window list. Safe at any time: for a window that was just created, for
/// one that was already placed (the tag arrived late) and for one that is a
/// DockApp already. Model changes only; the caller (manage) has already made
/// the seats forget the window.
pub fn adopt(wm: *WindowManager, win: *Window) void {
    if (win.role == .dockapp) return;

    workspace.unplace(wm, win);
    if (wm.focus_request == win) wm.focus_request = null;
    if (wm.pending_fullscreen) |pf| if (pf.win == win) {
        wm.pending_fullscreen = null;
    };

    types.unlink(&win.link);
    wm.dock_windows.append(win);

    win.role = .dockapp;
    log.debug("`{s}` is a DockApp: an icon in the Dock, not a window", .{win.app_id orelse "?"});
    win.new = false;
    win.minimized = false;
    win.sticky = false;
    win.mode = .floating;
    // Whatever was sent for a normal window says nothing about this one:
    // send size and position again.
    win.sent_tiled = null;
    win.sent_border = null;
    win.sent_w = -1;
    win.sent_h = -1;
    win.sent_x = std.math.minInt(i32);
    win.sent_y = std.math.minInt(i32);
    win.visible = null;
}

// ----------------------------------------------------------------------------
// Geometry (pure)
// ----------------------------------------------------------------------------

pub const Size = struct { w: i32, h: i32 };

/// The size a DockApp is given: what it asked for, never more than a tile.
/// No hint means a whole tile. (A minimum above a tile cannot be honoured
/// inside the tile; the window then overflows it rather than being cut.)
pub fn hostedSize(min_w: i32, min_h: i32, max_w: i32, max_h: i32) Size {
    const tile = dock_model.tile;
    const w = if (max_w > 0) @min(max_w, tile) else tile;
    const h = if (max_h > 0) @min(max_h, tile) else tile;
    return .{ .w = @max(w, min_w), .h = @max(h, min_h) };
}

/// Global rectangle of a `w` x `h` window centred in the tile whose top-left
/// is the output-local (tx, ty) of the output at `out`.
pub fn tileRect(out: types.Rect, tx: i32, ty: i32, w: i32, h: i32) types.Rect {
    const tile = dock_model.tile;
    return .{
        .x = out.x + tx + @divTrunc(tile - w, 2),
        .y = out.y + ty + @divTrunc(tile - h, 2),
        .w = w,
        .h = h,
    };
}

/// `s` cut to at most `max` bytes, never inside a UTF-8 character.
fn cutUtf8(s: []const u8, max: usize) []const u8 {
    var end = @min(s.len, max);
    while (end > 0 and end < s.len and (s[end] & 0xC0) == 0x80) end -= 1;
    return s[0..end];
}

// ----------------------------------------------------------------------------
// Tiles follow the programs
// ----------------------------------------------------------------------------

/// The last minimized window whose tile could not be made, so the warning
/// comes once per window and not with every sync.
var warned_order: u64 = 0;

/// Give every DockApp a tile and keep the tiles in step with the programs:
///   * a DockApp without an entry gets a temporary tile;
///   * every minimized window gets a temporary tile of its own (`mini_dock`),
///     showing its program's icon, and loses it when it is restored;
///   * a tile is `running` while a window of its application exists (a
///     DockApp's too: the tile shows no "not running" dots then);
///   * a temporary tile goes with its program.
/// True if the model changed.
pub fn syncModel(wm: *WindowManager, m: *dock_model.Model) bool {
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

    // Who is running. This is the expensive part of the pass -- every tile
    // against every window, `DockApp.matches` doing several case-insensitive
    // compares each -- and it ran on EVERY manage pass, so on every frame of
    // an animation, although it only has to run when a window came, went or
    // changed its app_id, or a tile changed. The fingerprint covers exactly
    // what it reads; the results are a pure function of that.
    const sig_before = runningSignature(wm, m);
    if (sig_before == m.running_sig) return changed;

    var ids: std.ArrayList([]const u8) = .empty;
    defer ids.deinit(wm.gpa);
    var ids_complete = true;
    var nit = wm.windows.first();
    while (nit) |w| : (nit = types.nextWindow(w, wm)) {
        if (w.closed) continue;
        const id = w.app_id orelse continue;
        ids.append(wm.gpa, id) catch {
            ids_complete = false;
            break;
        };
    }
    dit = wm.dock_windows.first();
    while (ids_complete and dit != null) : (dit = types.nextDockWindow(dit.?, wm)) {
        const w = dit.?;
        if (w.closed) continue;
        const id = w.app_id orelse continue;
        ids.append(wm.gpa, id) catch {
            ids_complete = false;
        };
    }
    // Without the complete list a tile would be marked "not running" (and a
    // temporary one pruned) while its program is still there.
    if (!ids_complete) return changed;
    if (m.setRunning(ids.items)) changed = true;
    if (m.pruneAttached()) changed = true;
    // Taken after the update, which changed flags and maybe removed tiles:
    // the next pass with nothing new then matches it.
    m.running_sig = runningSignature(wm, m);
    return changed;
}

fn fnv(h: u64, bytes: []const u8) u64 {
    var x = h;
    for (bytes) |b| {
        x ^= b;
        x *%= 0x100000001b3;
    }
    // The length too, so that ("ab", "c") and ("a", "bc") differ.
    x ^= @as(u64, bytes.len);
    x *%= 0x100000001b3;
    return x;
}

fn fnvInt(h: u64, v: u64) u64 {
    var x = v;
    return fnv(h, std.mem.asBytes(&x));
}

/// A fingerprint of the inputs of `setRunning` and `pruneAttached`: the
/// app_id of every open window and DockApp, and per tile everything
/// `DockApp.matches` looks at plus the flags those two functions read or write.
fn runningSignature(wm: *WindowManager, m: *const dock_model.Model) u64 {
    var h: u64 = 0xcbf29ce484222325;
    var it = wm.windows.first();
    while (it) |w| : (it = types.nextWindow(w, wm)) {
        if (w.closed) continue;
        h = fnv(h, w.app_id orelse continue);
    }
    h = fnvInt(h, 1); // windows end, DockApps begin
    var dit = wm.dock_windows.first();
    while (dit) |w| : (dit = types.nextDockWindow(w, wm)) {
        if (w.closed) continue;
        h = fnv(h, w.app_id orelse continue);
    }
    h = fnvInt(h, 2);
    for (m.slots.items) |s| {
        var flags: u64 = 0;
        if (s.alive) flags |= 1;
        if (s.running) flags |= 2;
        if (s.launching) flags |= 4;
        if (s.app.attached) flags |= 8;
        if (s.app.mini_window != 0) flags |= 16;
        if (s.app.app_id != null) flags |= 32;
        h = fnvInt(h, flags);
        h = fnv(h, s.app.name);
        h = fnv(h, s.app.app_id orelse "");
        h = fnvInt(h, @as(u64, s.app.command.len));
        for (s.app.command) |arg| h = fnv(h, arg);
    }
    return h;
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
        if (app.matches(id)) backend.closeWindow(w.obj);
    }
}

/// Session end: ask every DockApp to close.
pub fn closeAll(wm: *WindowManager) void {
    var it = wm.dock_windows.first();
    while (it) |w| : (it = types.nextDockWindow(w, wm)) {
        if (!w.closed) backend.closeWindow(w.obj);
    }
}

// ----------------------------------------------------------------------------
// The pass
// ----------------------------------------------------------------------------

/// What `update` tells the rest of the pass about the Dock.
pub const Host = struct {
    /// The tiles. null: there is no Dock model.
    model: ?*dock_model.Model = null,
    /// The output the Dock is shown on; null while it is not shown
    /// (`dock_enabled = false`, no output).
    out: ?*Output = null,
    /// The Dock is above the normal windows (then so are its DockApps).
    raised: bool = false,
    /// The tiles changed in this pass: the Dock has to be drawn again.
    changed: bool = false,
};

/// (Re)build the Dock model when a config load asked for it. The model is a
/// deep copy of `wm.dockapps`, so it must not outlive the config it came from
/// without a rebuild: every load bumps `dock_gen`.
fn ensureModel(wm: *WindowManager) ?*dock_model.Model {
    if (wm.dock) |m| if (wm.dock_built == wm.dock_gen) return m;
    if (wm.dock) |m| {
        m.deinit();
        wm.gpa.destroy(m);
        wm.dock = null;
    }
    wm.dock_built = wm.dock_gen;

    dock_model.setSize(wm.cfg.dock_size);
    const m = wm.gpa.create(dock_model.Model) catch {
        log.err("out of memory: cannot build the Dock", .{});
        return null;
    };
    m.* = dock_model.Model.init(wm.gpa, wm.dockapps, wm.cfg.workspace_names, config.max_workspaces) catch |err| {
        log.err("cannot build the Dock model: {t}", .{err});
        wm.gpa.destroy(m);
        return null;
    };
    wm.dock = m;
    return m;
}

/// Drop the model (session end, tests).
pub fn deinit(wm: *WindowManager) void {
    if (wm.dock) |m| {
        m.deinit();
        wm.gpa.destroy(m);
    }
    wm.dock = null;
    wm.dock_built = null;
}

/// Once per manage pass, before the layout: the Dock model follows the config
/// and the programs, sits on the primary output, and reserves its column there
/// (so tiled windows are laid out next to it). `now_ms` is the pass's clock.
pub fn update(wm: *WindowManager, now_ms: u64) Host {
    const cfg = &wm.cfg;
    var host: Host = .{};

    const model = ensureModel(wm);
    const out = types.primaryOutput(wm);

    // What the Dock reserves only ever applies to the output it is on.
    var oit = wm.outputs.first();
    while (oit) |o| : (oit = types.nextOutput(o, wm)) {
        if (o != out) o.reserved = .{};
    }
    const primary = out orelse return host;
    primary.reserved = .{};
    const m = model orelse return host;

    // The rows of the screen must be known before tiles are added to the
    // Dock (a new tile has to lie on the screen); `layout` sets them.
    const w = primary.rect.w;
    const h = primary.rect.h;
    m.layout(w, h, cfg.dock_edge == .right, cfg.dock_offset, cfg.clip_corner);
    host.changed = syncModel(wm, m);
    if (m.expireLaunching(@truncate(now_ms), launch_timeout_ms)) host.changed = true;

    // Where everything is on this output; the Clip follows the workspace.
    // Again, because new tiles move the rows the Dock may be placed in.
    m.layout(w, h, cfg.dock_edge == .right, cfg.dock_offset, cfg.clip_corner);
    const clip_before = m.currentClip();
    m.setWorkspace(primary.active);
    if (m.currentClip() != clip_before) host.changed = true;

    host.model = m;
    host.raised = dock_model.levelFor(cfg.dock_on_top, cfg.dock_auto_raise) == .top;
    if (!cfg.dock_enabled) return host;
    host.out = primary;

    // The Dock's column is taken out of the work area whatever its level
    // (top / auto / lowered), once the compositor shows it. A fullscreen window does not change this: it
    // covers the whole output on its own, and the other windows keep their
    // places for when it ends.
    if (cfg.dock_reserve_space and wm.dock_shown) switch (cfg.dock_edge) {
        .left => primary.reserved.left = dock_model.tile,
        .right => primary.reserved.right = dock_model.tile,
    };
    return host;
}

// ----------------------------------------------------------------------------
// What a click on a tile asks for
// ----------------------------------------------------------------------------

/// The window a click on `app`'s tile shows: for a minimized window's tile,
/// that window; for an application's, the first of its windows that is
/// visible, else the first one (a minimized one is then restored). Null: the
/// application has no window.
pub fn windowFor(wm: *WindowManager, app: *const dockapp.DockApp) ?*Window {
    var first: ?*Window = null;
    var it = wm.windows.first();
    while (it) |w| : (it = types.nextWindow(w, wm)) {
        if (w.closed) continue;
        if (app.mini_window != 0) {
            if (w.minimized and w.min_order == app.mini_window) return w;
            continue;
        }
        const id = w.app_id orelse continue;
        if (!app.matches(id)) continue;
        if (!w.minimized) return w;
        if (first == null) first = w;
    }
    return first;
}

/// Ask for `win` to be shown (executed by `runRequests` in the next pass).
pub fn requestActivate(wm: *WindowManager, win: *Window) void {
    wm.dock_activate = win;
    backend.manageDirty(wm.obj);
}

/// Once per pass, after the queued commands: show the window a Dock tile
/// asked for. A minimized window comes back on the active workspace of the
/// output it was last on; any other is made the focus, and the pass that
/// follows brings its workspace into view.
pub fn runRequests(wm: *WindowManager) void {
    const win = wm.dock_activate orelse return;
    wm.dock_activate = null;
    if (win.closed or win.role == .dockapp) return;
    if (win.minimized) {
        const out = types.workingOutput(wm) orelse return;
        action.restoreWindow(wm, win, out);
        return;
    }
    action.requestFocus(wm, win);
}

/// How long the event loop may sleep before a `launching` tile times out;
/// null when no tile is launching.
pub fn launchWaitMs(wm: *const WindowManager, now_ms: u64) ?u32 {
    const m = wm.dock orelse return null;
    return m.nextLaunchExpiry(@truncate(now_ms), launch_timeout_ms);
}

/// Hidden (not placed) because `why`: logged once per change, so a DockApp
/// that does not show up says why.
fn hide(sink: manage.Sink, win: *Window, why: []const u8) void {
    if (win.visible != false) {
        log.warn("DockApp `{s}` is not shown: {s}", .{ win.app_id orelse "?", why });
        win.visible = false;
        sink.place(win, .{ .visible = false });
    }
}

/// How many DockApps are tracked for the "one per tile" rule; further ones
/// are simply not checked.
const max_hosted = 64;

/// Tell the compositor where every DockApp goes: size, position, visibility.
/// Idempotent and cheap: size is sent only when it changed, like for a
/// normal window.
pub fn apply(wm: *WindowManager, host: Host, sink: manage.Sink) void {
    // The tiles that already have a DockApp in them this pass: a second
    // instance (same app_id) would be drawn right on top of the first, so
    // only the oldest is shown until it goes away.
    var used: [max_hosted]usize = undefined;
    var n_used: usize = 0;
    var it = wm.dock_windows.first();
    while (it) |w| : (it = types.nextDockWindow(w, wm)) {
        if (w.closed) continue;
        applyOne(w, host, sink, &used, &n_used);
    }
}

fn applyOne(win: *Window, host: Host, sink: manage.Sink, used: *[max_hosted]usize, n_used: *usize) void {
    const out = host.out orelse return hide(sink, win, "there is no Dock on an output (dock_enabled = false?)");
    const m = host.model orelse return hide(sink, win, "the Dock has no model");
    const id = win.app_id orelse return hide(sink, win, "no app_id");
    const idx = m.dockSlotFor(id) orelse return hide(sink, win, "no Dock tile for it (invalid name, or the Dock is full)");
    const gi = m.slots.items[idx].gi;
    for (used[0..n_used.*]) |u| {
        if (u == idx) return hide(sink, win, "another DockApp with the same name already sits in its tile");
    }
    if (n_used.* < used.len) {
        used[n_used.*] = idx;
        n_used.* += 1;
    }

    // The client draws everything itself and has one size.
    var c: manage.Configure = .{};
    if (win.sent_tiled == null) {
        c.tiled = false;
        win.sent_tiled = false;
    }
    const size = hostedSize(win.min_w, win.min_h, win.max_w, win.max_h);
    if (size.w != win.sent_w or size.h != win.sent_h) {
        c.size = .{ .w = size.w, .h = size.h };
        win.sent_w = size.w;
        win.sent_h = size.h;
    }
    if (c.size != null or c.tiled != null) sink.configure(win, c);

    // Centred by the size it really has, in case it did not take ours.
    const w_now = if (win.actual_w > 0) win.actual_w else size.w;
    const h_now = if (win.actual_h > 0) win.actual_h else size.h;
    const r = tileRect(out.rect, gi.x_pos, gi.y_pos, w_now, h_now);
    win.target = r;
    win.visible = true;
    sink.place(win, .{
        .visible = true,
        .rect = r,
        .border = .none,
        .border_width = 0,
        .mode = .floating,
        .raise = host.raised,
    });
}

// ----------------------------------------------------------------------------
// Tests: the pure parts. What a pass does with DockApps is tested in
// manage.zig (it has the fake compositor).
// ----------------------------------------------------------------------------

test "isDockApp: the tag is the app_id and nothing else" {
    try std.testing.expect(isDockApp("dockapp:clock"));
    try std.testing.expect(isDockApp("dockapp-clock"));
    try std.testing.expect(!isDockApp("clock"));
    try std.testing.expect(!isDockApp("Dockapp:clock"));
    try std.testing.expect(!isDockApp(null));
}

test "hostedSize: what it asked for, at most a tile, a whole tile without a hint" {
    dock_model.setSize(64);
    defer dock_model.setSize(dock_model.default_tile);
    try std.testing.expectEqual(Size{ .w = 48, .h = 48 }, hostedSize(48, 48, 48, 48));
    try std.testing.expectEqual(Size{ .w = 64, .h = 64 }, hostedSize(0, 0, 0, 0));
    try std.testing.expectEqual(Size{ .w = 64, .h = 64 }, hostedSize(10, 10, 300, 300));
    try std.testing.expectEqual(Size{ .w = 32, .h = 64 }, hostedSize(0, 0, 32, 0));
    // A minimum above a tile is kept: the window overflows rather than breaks.
    try std.testing.expectEqual(Size{ .w = 100, .h = 64 }, hostedSize(100, 0, 100, 0));
}

test "tileRect centres the window in the tile of the output" {
    dock_model.setSize(64);
    defer dock_model.setSize(dock_model.default_tile);
    const out: types.Rect = .{ .x = 1920, .y = 0, .w = 1920, .h = 1080 };
    const r = tileRect(out, 1856, 128, 48, 48);
    try std.testing.expectEqual(@as(i32, 1920 + 1856 + 8), r.x);
    try std.testing.expectEqual(@as(i32, 128 + 8), r.y);
    try std.testing.expectEqual(@as(i32, 48), r.w);
    const full = tileRect(out, 0, 0, dock_model.tile, dock_model.tile);
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
