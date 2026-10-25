// SPDX-License-Identifier: GPL-3.0
//
// A keyboard. Key presses are first matched against the binds of config.lua
// (keys.zig), then given to the focused client.

const std = @import("std");
const log = std.log.scoped(.keyboard);

const wayland = @import("wayland");
const wl = wayland.server.wl;
const wlr = @import("wlroots");
const xkb = @import("xkbcommon");

const model = @import("model.zig");
const manage = @import("manage.zig");
const keys = @import("keys.zig");

const Server = @import("server.zig").Server;

/// Auto-repeat, as clients see it: after 600 ms, 25 keys per second.
const repeat_rate = 25;
const repeat_delay = 600;

pub const Keyboard = struct {
    server: *Server,
    link: wl.list.Link = undefined,
    device: *wlr.InputDevice,
    /// evdev keycodes of the presses a bind took. Their release is taken as
    /// well, so a client never sees half a key.
    consumed: [32]u32 = undefined,
    n_consumed: usize = 0,

    modifiers: wl.Listener(*wlr.Keyboard) = .init(onModifiers),
    key: wl.Listener(*wlr.Keyboard.event.Key) = .init(onKey),
    destroy: wl.Listener(*wlr.InputDevice) = .init(onDestroy),

    pub fn create(server: *Server, device: *wlr.InputDevice) !void {
        const kb = try server.gpa.create(Keyboard);
        errdefer server.gpa.destroy(kb);
        kb.* = .{ .server = server, .device = device };

        // The layout comes from XKB_DEFAULT_LAYOUT & co, like in any wlroots
        // compositor.
        const context = xkb.Context.new(.no_flags) orelse return error.XkbContext;
        defer context.unref();
        const keymap = xkb.Keymap.newFromNames(context, null, .no_flags) orelse return error.XkbKeymap;
        defer keymap.unref();

        const wlr_kb = device.toKeyboard();
        if (!wlr_kb.setKeymap(keymap)) return error.SetKeymap;
        wlr_kb.setRepeatInfo(repeat_rate, repeat_delay);

        wlr_kb.events.modifiers.add(&kb.modifiers);
        wlr_kb.events.key.add(&kb.key);
        device.events.destroy.add(&kb.destroy);

        server.seat.setKeyboard(wlr_kb);
        server.keyboards.append(kb);

        // The focus was decided before there was a keyboard.
        if (server.focused) |v| if (v.toplevel) |t| server.enterKeyboard(t.base.surface);
    }

    fn onModifiers(listener: *wl.Listener(*wlr.Keyboard), wlr_kb: *wlr.Keyboard) void {
        const kb: *Keyboard = @fieldParentPtr("modifiers", listener);
        kb.server.seat.setKeyboard(wlr_kb);
        kb.server.seat.keyboardNotifyModifiers(&wlr_kb.modifiers);
    }

    fn onKey(listener: *wl.Listener(*wlr.Keyboard.event.Key), event: *wlr.Keyboard.event.Key) void {
        const kb: *Keyboard = @fieldParentPtr("key", listener);
        const server = kb.server;
        const wlr_kb = kb.device.toKeyboard();

        const handled = switch (event.state) {
            .pressed => kb.press(wlr_kb, event.keycode),
            .released => kb.releaseConsumed(event.keycode),
            else => false,
        };
        if (handled) return;

        server.seat.setKeyboard(wlr_kb);
        server.seat.keyboardNotifyKey(event.time_msec, event.keycode, event.state);
    }

    /// Does a bind (or a VT switch) take this press?
    fn press(kb: *Keyboard, wlr_kb: *wlr.Keyboard, evdev: u32) bool {
        const server = kb.server;
        const keymap = wlr_kb.keymap orelse return false;
        const state = wlr_kb.xkb_state orelse return false;

        const syms = keys.candidates(keymap, state, server.wm.cfg.bind_layout, evdev + 8);

        // Switching terminals is the session's job and works whatever the
        // binds say, even with a client holding the keyboard.
        for (syms.slice()) |sym| {
            const vt = keys.vtOf(sym) orelse continue;
            if (server.session) |session| {
                log.info("switching to vt {d}", .{vt});
                session.changeVt(vt) catch |err| log.warn("vt switch failed: {t}", .{err});
            }
            return kb.consume(evdev);
        }

        const mods: u32 = @bitCast(wlr_kb.getModifiers());
        const index = keys.find(server.wm.cfg.binds, mods, syms.slice()) orelse return false;
        manage.queueBind(server.wm, index);
        return kb.consume(evdev);
    }

    fn consume(kb: *Keyboard, evdev: u32) bool {
        if (kb.n_consumed < kb.consumed.len) {
            kb.consumed[kb.n_consumed] = evdev;
            kb.n_consumed += 1;
        }
        return true;
    }

    fn releaseConsumed(kb: *Keyboard, evdev: u32) bool {
        for (kb.consumed[0..kb.n_consumed], 0..) |code, i| {
            if (code != evdev) continue;
            kb.n_consumed -= 1;
            kb.consumed[i] = kb.consumed[kb.n_consumed];
            return true;
        }
        return false;
    }

    fn onDestroy(listener: *wl.Listener(*wlr.InputDevice), _: *wlr.InputDevice) void {
        const kb: *Keyboard = @fieldParentPtr("destroy", listener);
        kb.link.remove();
        kb.modifiers.link.remove();
        kb.key.link.remove();
        kb.destroy.link.remove();
        kb.server.gpa.destroy(kb);
    }
};
