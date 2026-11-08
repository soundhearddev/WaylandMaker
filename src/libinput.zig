// SPDX-License-Identifier: GPL-3.0
//
// Settings of pointing devices that libinput owns (touchpads, mice).
//
// libinput's own defaults are conservative: a touchpad does not turn a tap
// into a click, so on a laptop "the pointer works but I cannot click" was the
// normal state of a fresh session. config.lua: `tap_to_click`,
// `natural_scroll`, `disable_while_typing`, `accel_speed`, `accel_profile`,
// `click_method`, `left_handed`. The settings are global: every device gets the
// same ones (per device is still open, docs/TODO.md).
//
// Applied when a device appears and again after every config reload
// (`Pointer`, `reconfigure`).

const std = @import("std");
const log = std.log.scoped(.libinput);

const wayland = @import("wayland");
const wl = wayland.server.wl;
const wlr = @import("wlroots");

const model = @import("model.zig");
const config = model.config;

extern "c" fn wlr_input_device_is_libinput(dev: *wlr.InputDevice) bool;
extern "c" fn wlr_libinput_get_device_handle(dev: *wlr.InputDevice) ?*anyopaque;

extern "c" fn libinput_device_config_tap_get_finger_count(dev: *anyopaque) c_int;
extern "c" fn libinput_device_config_tap_set_enabled(dev: *anyopaque, enable: c_int) c_int;
extern "c" fn libinput_device_config_tap_set_drag_enabled(dev: *anyopaque, enable: c_int) c_int;
extern "c" fn libinput_device_config_scroll_has_natural_scroll(dev: *anyopaque) c_int;
extern "c" fn libinput_device_config_scroll_set_natural_scroll_enabled(dev: *anyopaque, enable: c_int) c_int;
extern "c" fn libinput_device_config_dwt_is_available(dev: *anyopaque) c_int;
extern "c" fn libinput_device_config_dwt_set_enabled(dev: *anyopaque, enable: c_int) c_int;

extern "c" fn libinput_device_config_accel_is_available(dev: *anyopaque) c_int;
extern "c" fn libinput_device_config_accel_set_speed(dev: *anyopaque, speed: f64) c_int;
extern "c" fn libinput_device_config_accel_get_profiles(dev: *anyopaque) u32;
extern "c" fn libinput_device_config_accel_set_profile(dev: *anyopaque, profile: u32) c_int;
extern "c" fn libinput_device_config_accel_get_default_profile(dev: *anyopaque) u32;
extern "c" fn libinput_device_config_click_get_default_method(dev: *anyopaque) u32;
extern "c" fn libinput_device_config_left_handed_get_default(dev: *anyopaque) c_int;
extern "c" fn libinput_device_config_click_get_methods(dev: *anyopaque) u32;
extern "c" fn libinput_device_config_click_set_method(dev: *anyopaque, method: u32) c_int;
extern "c" fn libinput_device_config_left_handed_is_available(dev: *anyopaque) c_int;
extern "c" fn libinput_device_config_left_handed_set(dev: *anyopaque, left_handed: c_int) c_int;

// libinput_config_accel_profile / libinput_config_click_method (bit masks).
const accel_profile_flat: u32 = 1 << 0;
const accel_profile_adaptive: u32 = 1 << 1;
const click_method_button_areas: u32 = 1 << 0;
const click_method_clickfinger: u32 = 1 << 1;

pub fn configure(cfg: *const config.Config, device: *wlr.InputDevice) void {
    if (!wlr_input_device_is_libinput(device)) return;
    const handle = wlr_libinput_get_device_handle(device) orelse return;

    // A device with tap fingers is a touchpad.
    if (libinput_device_config_tap_get_finger_count(handle) > 0) {
        _ = libinput_device_config_tap_set_enabled(handle, @intFromBool(cfg.tap_to_click));
        _ = libinput_device_config_tap_set_drag_enabled(handle, @intFromBool(cfg.tap_to_click));
    }
    if (libinput_device_config_scroll_has_natural_scroll(handle) != 0) {
        _ = libinput_device_config_scroll_set_natural_scroll_enabled(handle, @intFromBool(cfg.natural_scroll));
    }
    if (libinput_device_config_dwt_is_available(handle) != 0) {
        _ = libinput_device_config_dwt_set_enabled(handle, @intFromBool(cfg.disable_while_typing));
    }
    if (libinput_device_config_accel_is_available(handle) != 0) {
        // -100 .. 100 percent -> libinput's -1.0 .. 1.0.
        _ = libinput_device_config_accel_set_speed(handle, @as(f64, @floatFromInt(cfg.accel_speed)) / 100.0);
        // `default` goes back to the device's own profile, so a reload that
        // removes `accel_profile` undoes an earlier `flat`.
        const want: u32 = switch (cfg.accel_profile) {
            .default => libinput_device_config_accel_get_default_profile(handle),
            .flat => accel_profile_flat,
            .adaptive => accel_profile_adaptive,
        };
        // Only a profile the device offers; the rest keeps libinput's choice.
        if (want != 0 and (libinput_device_config_accel_get_profiles(handle) & want) != 0) {
            _ = libinput_device_config_accel_set_profile(handle, want);
        }
    }
    {
        const want: u32 = switch (cfg.click_method) {
            .default => libinput_device_config_click_get_default_method(handle),
            .button_areas => click_method_button_areas,
            .clickfinger => click_method_clickfinger,
        };
        if (want != 0 and (libinput_device_config_click_get_methods(handle) & want) != 0) {
            _ = libinput_device_config_click_set_method(handle, want);
        }
    }
    // Not set means the device's own default, not "off": a device may come
    // with its own left-handed setting.
    if (libinput_device_config_left_handed_is_available(handle) != 0) {
        const value: c_int = if (cfg.left_handed) 1 else libinput_device_config_left_handed_get_default(handle);
        _ = libinput_device_config_left_handed_set(handle, value);
    }
    log.info("pointer {?s}: tap {}, natural scroll {}, speed {}, profile {s}, click {s}, left-handed {}", .{
        device.name,         cfg.tap_to_click,                 cfg.natural_scroll, cfg.accel_speed,
        @tagName(cfg.accel_profile), @tagName(cfg.click_method), cfg.left_handed,
    });
}

/// A pointing device the compositor has seen, kept so a config reload can
/// reach it again. It lives until the device is destroyed.
pub const Pointer = struct {
    gpa: std.mem.Allocator,
    device: *wlr.InputDevice,
    link: wl.list.Link = undefined,
    destroy: wl.Listener(*wlr.InputDevice) = .init(onDestroy),

    pub const List = wl.list.Head(Pointer, .link);

    /// Apply the settings now and remember the device for later reloads.
    pub fn track(gpa: std.mem.Allocator, list: *List, cfg: *const config.Config, device: *wlr.InputDevice) !void {
        configure(cfg, device);
        const p = try gpa.create(Pointer);
        p.* = .{ .gpa = gpa, .device = device };
        list.append(p);
        device.events.destroy.add(&p.destroy);
    }

    fn onDestroy(listener: *wl.Listener(*wlr.InputDevice), _: *wlr.InputDevice) void {
        const p: *Pointer = @fieldParentPtr("destroy", listener);
        p.link.remove();
        p.destroy.link.remove();
        p.gpa.destroy(p);
    }
};

/// A config reload: every pointing device gets the new settings.
pub fn reconfigure(list: *Pointer.List, cfg: *const config.Config) void {
    var it = list.iterator(.forward);
    while (it.next()) |p| configure(cfg, p.device);
}
