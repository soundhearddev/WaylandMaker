// SPDX-License-Identifier: GPL-3.0
//
// ext-session-lock: the screen locker (swaylock, gtklock, hyprlock).
//
// While locked, the compositor shows only what the locker draws, and only the
// locker gets keys and pointer. The lock holds even when the locker dies: the
// screen stays covered until another locker comes and unlocks it (that is the
// point of the protocol). The cover is one black rectangle larger than any
// desk, so an output plugged in while locked is covered too, and the lock
// surfaces lie in a tree above everything else.
//
// What is shut off while locked, in the files that would otherwise act:
// binds (keyboard.zig; only the VT switch stays), the Dock and mouse binds
// (cursor.zig) and any keyboard focus but the locker's (`Server.enterKeyboard`).
//
// Compositor side (imports wlroots).

const std = @import("std");
const log = std.log.scoped(.lock);

const wayland = @import("wayland");
const wl = wayland.server.wl;
const wlr = @import("wlroots");

const Server = @import("server.zig").Server;

/// Bigger than any desk: the cover needs no update when outputs come and go.
const cover_size: c_int = 1 << 17;
const cover_origin: c_int = -(1 << 16);

/// One lock surface (the locker draws one per output).
const LockSurface = struct {
    lock: *Lock,
    surface: *wlr.SessionLockSurfaceV1,
    tree: *wlr.SceneTree,
    link: wl.list.Link = undefined,
    destroy: wl.Listener(void) = .init(onDestroy),
    map: wl.Listener(void) = .init(onMap),

    fn onMap(listener: *wl.Listener(void)) void {
        const s: *LockSurface = @fieldParentPtr("map", listener);
        s.lock.focus();
        s.lock.checkCovered();
    }

    fn onDestroy(listener: *wl.Listener(void)) void {
        const s: *LockSurface = @fieldParentPtr("destroy", listener);
        const l = s.lock;
        s.destroy.link.remove();
        s.map.link.remove();
        s.link.remove();
        l.server.gpa.destroy(s);
        l.focus();
    }
};

pub const Lock = struct {
    server: *Server,
    manager: *wlr.SessionLockManagerV1,
    /// Above every other tree; enabled only while locked.
    tree: *wlr.SceneTree,
    /// True from the request until an unlock, also when the locker died.
    locked: bool = false,
    /// `locked` was sent to the locker (every output is covered by its surface).
    locked_sent: bool = false,
    /// The locker that is connected (null: none, or it left without unlocking).
    current: ?*wlr.SessionLockV1 = null,
    surfaces: wl.list.Head(LockSurface, .link) = undefined,

    new_lock: wl.Listener(*wlr.SessionLockV1) = .init(onNewLock),
    new_surface: wl.Listener(*wlr.SessionLockSurfaceV1) = .init(onNewSurface),
    unlock: wl.Listener(void) = .init(onUnlock),
    lock_destroy: wl.Listener(void) = .init(onLockDestroy),

    pub fn create(server: *Server) !*Lock {
        const l = try server.gpa.create(Lock);
        errdefer server.gpa.destroy(l);
        const tree = try server.scene.tree.createSceneTree();
        errdefer tree.node.destroy();
        const cover = try tree.createSceneRect(cover_size, cover_size, &.{ 0, 0, 0, 1 });
        cover.node.setPosition(cover_origin, cover_origin);
        tree.node.setEnabled(false);
        l.* = .{
            .server = server,
            .manager = try wlr.SessionLockManagerV1.create(server.wl_server),
            .tree = tree,
        };
        l.surfaces.init();
        l.manager.events.new_lock.add(&l.new_lock);
        return l;
    }

    pub fn destroy(l: *Lock) void {
        l.new_lock.link.remove();
        if (l.current != null) {
            l.new_surface.link.remove();
            l.unlock.link.remove();
            l.lock_destroy.link.remove();
        }
        l.server.gpa.destroy(l);
    }

    fn onNewLock(listener: *wl.Listener(*wlr.SessionLockV1), lock: *wlr.SessionLockV1) void {
        const l: *Lock = @fieldParentPtr("new_lock", listener);
        // One locker at a time; a second one is told it is finished.
        if (l.current != null) {
            lock.destroy();
            return;
        }
        log.info("screen locked", .{});
        l.current = lock;
        l.locked = true;
        l.locked_sent = false;
        lock.events.new_surface.add(&l.new_surface);
        lock.events.unlock.add(&l.unlock);
        lock.events.destroy.add(&l.lock_destroy);

        l.tree.node.setEnabled(true);
        l.tree.node.raiseToTop();
        // Nothing below keeps the keyboard or the pointer.
        l.server.seat.keyboardNotifyClearFocus();
        l.server.seat.pointerNotifyClearFocus();
        l.server.cursor.refresh();
        l.checkCovered();
    }

    fn onNewSurface(listener: *wl.Listener(*wlr.SessionLockSurfaceV1), ls: *wlr.SessionLockSurfaceV1) void {
        const l: *Lock = @fieldParentPtr("new_surface", listener);
        const tree = l.tree.createSceneSubsurfaceTree(ls.surface) catch {
            log.err("out of memory: a lock surface is not shown", .{});
            return;
        };
        const s = l.server.gpa.create(LockSurface) catch {
            tree.node.destroy();
            log.err("out of memory: a lock surface is not shown", .{});
            return;
        };
        s.* = .{ .lock = l, .surface = ls, .tree = tree };
        l.surfaces.append(s);
        ls.events.destroy.add(&s.destroy);
        ls.surface.events.map.add(&s.map);
        l.place(s);
    }

    /// The locker's surface covers its output: position and configure.
    fn place(l: *Lock, s: *LockSurface) void {
        var box: wlr.Box = undefined;
        l.server.output_layout.getBox(s.surface.output, &box);
        s.tree.node.setPosition(box.x, box.y);
        _ = s.surface.configure(@intCast(@max(box.width, 0)), @intCast(@max(box.height, 0)));
    }

    /// The desk changed while locked: the surfaces follow their outputs.
    pub fn layoutChanged(l: *Lock) void {
        if (!l.locked) return;
        var it = l.surfaces.iterator(.forward);
        while (it.next()) |s| l.place(s);
        l.checkCovered();
    }

    /// Tell the locker it holds the screen once every output shows a surface
    /// of it: only then is it certain nothing of the session is visible.
    fn checkCovered(l: *Lock) void {
        const lock = l.current orelse return;
        if (l.locked_sent) return;
        var mit = l.server.monitors.iterator(.forward);
        while (mit.next()) |m| {
            if (m.gone or !m.in_layout) continue;
            var covered = false;
            var it = l.surfaces.iterator(.forward);
            while (it.next()) |s| {
                if (s.surface.output == m.wlr_output and s.surface.surface.mapped) covered = true;
            }
            if (!covered) return;
        }
        l.locked_sent = true;
        lock.sendLocked();
        log.info("lock shown on every output", .{});
    }

    /// The keyboard goes to a lock surface (the first one shown).
    pub fn focus(l: *Lock) void {
        if (!l.locked) return;
        const kb = l.server.seat.getKeyboard() orelse return;
        var it = l.surfaces.iterator(.forward);
        while (it.next()) |s| {
            if (!s.surface.surface.mapped) continue;
            if (l.server.seat.keyboard_state.focused_surface == s.surface.surface) return;
            l.server.seat.keyboardNotifyEnter(s.surface.surface, kb.keycodes[0..kb.num_keycodes], &kb.modifiers);
            return;
        }
        l.server.seat.keyboardNotifyClearFocus();
    }

    fn onUnlock(listener: *wl.Listener(void)) void {
        const l: *Lock = @fieldParentPtr("unlock", listener);
        log.info("screen unlocked", .{});
        l.locked = false;
        l.tree.node.setEnabled(false);
        l.server.restoreKeyboardFocus();
        l.server.cursor.refresh();
        l.server.requestFrames();
        l.server.scheduleManage();
    }

    /// The locker is gone. After an unlock that is the end of it; without one
    /// the screen stays locked and covered until a new locker unlocks it.
    fn onLockDestroy(listener: *wl.Listener(void)) void {
        const l: *Lock = @fieldParentPtr("lock_destroy", listener);
        l.new_surface.link.remove();
        l.unlock.link.remove();
        l.lock_destroy.link.remove();
        l.current = null;
        if (l.locked) log.warn("the locker left without unlocking: the screen stays locked", .{});
    }
};
