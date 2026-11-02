// SPDX-License-Identifier: GPL-3.0
//
// Settings of pointing devices that libinput owns (touchpads, mice).
//
// libinput's own defaults are conservative: a touchpad does not turn a tap
// into a click, so on a laptop "the pointer works but I cannot click" was the
// normal state of a fresh session. config.lua: `tap_to_click`,
// `natural_scroll`, `disable_while_typing`, `accel_speed`, `accel_profile`,
// `click_method`, `left_handed`. The settings are global: every device gets the
// same ones (per device is still open, docs/TODO wlroots.md).
//
// Applied when a device appears (a config reload does not touch devices that
// are already there).

const std = @import("std");
const log = std.log.scoped(.libinput);

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
        const want: u32 = switch (cfg.accel_profile) {
            .default => 0,
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
            .default => 0,
            .button_areas => click_method_button_areas,
            .clickfinger => click_method_clickfinger,
        };
        if (want != 0 and (libinput_device_config_click_get_methods(handle) & want) != 0) {
            _ = libinput_device_config_click_set_method(handle, want);
        }
    }
    // Only when asked for: a device may come with its own left-handed default.
    if (cfg.left_handed and libinput_device_config_left_handed_is_available(handle) != 0) {
        _ = libinput_device_config_left_handed_set(handle, 1);
    }
    log.info("pointer {?s}: tap {}, natural scroll {}, speed {}, profile {s}, click {s}, left-handed {}", .{
        device.name,         cfg.tap_to_click,                 cfg.natural_scroll, cfg.accel_speed,
        @tagName(cfg.accel_profile), @tagName(cfg.click_method), cfg.left_handed,
    });
}
