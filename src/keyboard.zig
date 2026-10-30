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
const sysmap = @import("sysmap.zig");

const Server = @import("server.zig").Server;

extern fn xkb_keysym_get_name(keysym: u32, buffer: [*]u8, size: usize) c_int;

// Auto-repeat, as clients see it, comes from `repeat_rate` and `repeat_delay`
// of config.lua (default: after 600 ms, 25 keys per second).

pub const Keyboard = struct {
    server: *Server,
    link: wl.list.Link = undefined,
    device: *wlr.InputDevice,
    /// evdev keycodes of the presses a bind took. Their release is taken as
    /// well, so a client never sees half a key.
    consumed: [32]u32 = undefined,
    n_consumed: usize = 0,
    /// Scratch space for the debug messages (no allocation on a key press).
    dbg_mods: [48]u8 = undefined,
    dbg_syms: [160]u8 = undefined,
    /// Held key of a bind that repeats (keys.repeats): the bind, the key, and
    /// the timer that fires it again.
    repeat_timer: ?*wl.EventSource = null,
    repeat_index: usize = 0,
    repeat_key: u32 = 0,

    modifiers: wl.Listener(*wlr.Keyboard) = .init(onModifiers),
    key: wl.Listener(*wlr.Keyboard.event.Key) = .init(onKey),
    destroy: wl.Listener(*wlr.InputDevice) = .init(onDestroy),

    pub fn create(server: *Server, device: *wlr.InputDevice) !void {
        const kb = try server.gpa.create(Keyboard);
        errdefer server.gpa.destroy(kb);
        kb.* = .{ .server = server, .device = device };

        const context = xkb.Context.new(.no_flags) orelse return error.XkbContext;
        defer context.unref();
        const keymap = try buildKeymap(context, &server.wm.cfg);
        defer keymap.unref();

        const wlr_kb = device.toKeyboard();
        if (!wlr_kb.setKeymap(keymap)) return error.SetKeymap;
        kb.applyRepeatInfo();
        wlr_kb.events.modifiers.add(&kb.modifiers);
        wlr_kb.events.key.add(&kb.key);
        device.events.destroy.add(&kb.destroy);

        server.seat.setKeyboard(wlr_kb);
        server.keyboards.append(kb);
        log.info("keyboard {?s}: {d} layout(s), repeat {d}/s after {d} ms, {d} binds", .{
            device.name,
            keymap.numLayouts(),
            server.wm.cfg.repeat_rate,
            server.wm.cfg.repeat_delay,
            server.wm.cfg.binds.len,
        });
        if (server.wm.cfg.binds.len != server.wm.commands.len) {
            // The binds of the config were not turned into commands: nothing
            // would happen on a key press. That is a start-up bug, say so.
            log.err("{d} binds in the config but {d} commands: key binds do nothing", .{ server.wm.cfg.binds.len, server.wm.commands.len });
        }

        // The focus was decided before there was a keyboard.
        if (server.layer_focus) |l| {
            server.enterKeyboard(l.surface.surface);
        } else if (server.focused) |v| if (v.toplevel) |t| server.enterKeyboard(t.base.surface);
    }

    /// config.lua (`keyboard_layout` & co) first, then XKB_DEFAULT_* (which
    /// xkbcommon reads itself when a name is empty), then the system's own
    /// setting, so a German session is German without any setup. If a layout
    /// does not exist, the next source is tried: a typo must not leave the
    /// session without a keyboard.
    fn buildKeymap(context: *xkb.Context, cfg: *const model.config.Config) !*xkb.Keymap {
        const sys = sysmap.read();

        const from_cfg = cfg.keyboard_layout.len > 0 or cfg.keyboard_variant.len > 0 or
            cfg.keyboard_model.len > 0 or cfg.keyboard_options.len > 0;
        if (from_cfg) {
            const names: xkb.RuleNames = .{
                .rules = null,
                .model = nonEmpty(cfg.keyboard_model),
                .layout = nonEmpty(cfg.keyboard_layout),
                .variant = nonEmpty(cfg.keyboard_variant),
                .options = nonEmpty(cfg.keyboard_options),
            };
            if (xkb.Keymap.newFromNames(context, &names, .no_flags)) |km| {
                log.info("keymap from config.lua: layout `{s}` variant `{s}` options `{s}`", .{ cfg.keyboard_layout, cfg.keyboard_variant, cfg.keyboard_options });
                return km;
            }
            log.warn("config.lua: keyboard_layout `{s}` / variant `{s}` is not a keymap, trying the next source", .{ cfg.keyboard_layout, cfg.keyboard_variant });
        }

        if (std.c.getenv("XKB_DEFAULT_LAYOUT") != null or std.c.getenv("XKB_DEFAULT_VARIANT") != null or
            std.c.getenv("XKB_DEFAULT_OPTIONS") != null or std.c.getenv("XKB_DEFAULT_MODEL") != null)
        {
            if (xkb.Keymap.newFromNames(context, null, .no_flags)) |km| {
                log.info("keymap from XKB_DEFAULT_*", .{});
                return km;
            }
            log.warn("XKB_DEFAULT_* does not name a keymap, trying the next source", .{});
        }

        if (sys.layout[0] != 0) {
            const names: xkb.RuleNames = .{
                .rules = null,
                .model = null,
                .layout = cstr(&sys.layout),
                .variant = if (sys.variant[0] != 0) cstr(&sys.variant) else null,
                .options = if (sys.options[0] != 0) cstr(&sys.options) else null,
            };
            if (xkb.Keymap.newFromNames(context, &names, .no_flags)) |km| {
                log.info("keymap from the system: layout `{s}` variant `{s}`", .{ std.mem.sliceTo(&sys.layout, 0), std.mem.sliceTo(&sys.variant, 0) });
                return km;
            }
            log.warn("the system's keyboard layout `{s}` is not a keymap, using the default", .{std.mem.sliceTo(&sys.layout, 0)});
        }

        // Explicit `us`, not "the environment": a broken XKB_DEFAULT_* would
        // fail here again and leave the session without a keyboard.
        log.info("keymap: us; set keyboard_layout = \"de\" in config.lua", .{});
        const fallback: xkb.RuleNames = .{ .rules = null, .model = null, .layout = "us", .variant = null, .options = null };
        return xkb.Keymap.newFromNames(context, &fallback, .no_flags) orelse error.XkbKeymap;
    }

    fn cstr(buf: *const [sysmap.max_name + 1]u8) [*:0]const u8 {
        return @ptrCast(buf);
    }

    fn nonEmpty(s: [:0]const u8) ?[*:0]const u8 {
        return if (s.len == 0) null else s.ptr;
    }

    /// What clients get as `wl_keyboard.repeat_info`: `repeat_rate` and
    /// `repeat_delay` of config.lua (a rate of 0 switches the repeat off).
    /// Called when the keyboard appears and after every config reload.
    pub fn applyRepeatInfo(kb: *Keyboard) void {
        const cfg = &kb.server.wm.cfg;
        const rate: i32 = @intCast(@min(cfg.repeat_rate, 1000));
        const delay: i32 = @intCast(@min(cfg.repeat_delay, 10_000));
        kb.device.toKeyboard().setRepeatInfo(rate, delay);
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
            .released => blk: {
                if (kb.repeat_key == event.keycode) kb.stopRepeat();
                break :blk kb.releaseConsumed(event.keycode);
            },
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

        // Any new press ends the repeat of the key held before.
        kb.stopRepeat();

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
        const index = keys.find(server.wm.cfg.binds, mods, syms.slice()) orelse {
            // `WMAKER_LOG=info,keyboard=debug` shows what a press that does
            // nothing looked like: which modifiers and which keysyms the
            // compositor saw, to compare with the bind in config.lua.
            if (keys.normalize(mods) != 0) log.debug("no bind: key {d}, mods {s}, keysyms {s}", .{ evdev, modsText(&kb.dbg_mods, mods), symsText(&kb.dbg_syms, syms.slice()) });
            return false;
        };
        log.debug("bind {d} `{s}`: key {d}, mods {s}", .{ index, server.wm.cfg.binds[index].command, evdev, modsText(&kb.dbg_mods, mods) });
        manage.queueBind(server.wm, index);
        const cfg = &server.wm.cfg;
        if (cfg.repeat_binds and cfg.repeat_rate > 0 and index < server.wm.commands.len and
            keys.repeats(server.wm.commands[index], syms.slice()))
        {
            kb.startRepeat(index, evdev);
        }
        return kb.consume(evdev);
    }

    // ---- text for the log -------------------------------------------------------------

    fn modsText(buf: []u8, mods: u32) []const u8 {
        const names = [_]struct { bit: u32, name: []const u8 }{
            .{ .bit = 1 << 6, .name = "Super+" }, .{ .bit = 1 << 0, .name = "Shift+" },
            .{ .bit = 1 << 2, .name = "Ctrl+" },  .{ .bit = 1 << 3, .name = "Alt+" },
            .{ .bit = 1 << 5, .name = "Mod3+" },  .{ .bit = 1 << 7, .name = "Mod5+" },
        };
        var w: std.Io.Writer = .fixed(buf);
        for (names) |n| if (mods & n.bit != 0) w.writeAll(n.name) catch break;
        return if (w.end == 0) "none" else buf[0 .. w.end - 1]; // without the last `+`
    }

    fn symsText(buf: []u8, syms: []const u32) []const u8 {
        var w: std.Io.Writer = .fixed(buf);
        for (syms, 0..) |sym, i| {
            if (i > 0) w.writeAll(", ") catch break;
            var name: [48]u8 = undefined;
            const n = xkb_keysym_get_name(sym, &name, name.len);
            if (n > 0) w.writeAll(name[0..@intCast(n)]) catch break else w.print("0x{x}", .{sym}) catch break;
        }
        return buf[0..w.end];
    }

    /// Fire the bind of the held key again after `repeat_delay`, then every
    /// 1000 / `repeat_rate` ms until the key is released.
    fn startRepeat(kb: *Keyboard, index: usize, evdev: u32) void {
        const server = kb.server;
        const timer = kb.repeat_timer orelse blk: {
            const t = server.loop.addTimer(*Keyboard, onRepeat, kb) catch {
                log.warn("out of memory: no repeat for this bind", .{});
                return;
            };
            kb.repeat_timer = t;
            break :blk t;
        };
        kb.repeat_index = index;
        kb.repeat_key = evdev;
        timer.timerUpdate(@intCast(@max(server.wm.cfg.repeat_delay, 1))) catch |err| {
            log.warn("repeat timer: {t}", .{err});
            kb.repeat_key = 0;
        };
    }

    fn stopRepeat(kb: *Keyboard) void {
        kb.repeat_key = 0;
        if (kb.repeat_timer) |t| t.timerUpdate(0) catch {};
    }

    fn onRepeat(kb: *Keyboard) c_int {
        const wm = kb.server.wm;
        if (kb.repeat_key == 0 or wm.cfg.repeat_rate == 0 or kb.repeat_index >= wm.commands.len) {
            kb.stopRepeat();
            return 0;
        }
        manage.queueBind(wm, kb.repeat_index);
        // A program per repeat (volume, brightness) is started at most ten
        // times a second; moving around runs as fast as the keyboard repeats.
        const floor: i32 = switch (wm.commands[kb.repeat_index]) {
            .spawn, .shell, .lua => 100,
            else => 1,
        };
        const period: i32 = @max(@as(i32, @intCast(1000 / wm.cfg.repeat_rate)), floor);
        if (kb.repeat_timer) |t| t.timerUpdate(@intCast(period)) catch {};
        return 0;
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
        if (kb.repeat_timer) |t| t.remove();
        kb.repeat_timer = null;
        kb.link.remove();
        kb.modifiers.link.remove();
        kb.key.link.remove();
        kb.destroy.link.remove();
        const server = kb.server;
        server.gpa.destroy(kb);
        server.seat.setCapabilities(.{ .pointer = true, .keyboard = server.keyboards.length() > 0 });
    }
};
