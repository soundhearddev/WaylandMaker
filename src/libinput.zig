// SPDX-License-Identifier: GPL-3.0
//
// Settings of pointing devices that libinput owns (touchpads, mice).
//
// libinput's own defaults are conservative: a touchpad does not turn a tap
// into a click, so on a laptop "the pointer works but I cannot click" was the
// normal state of a fresh session. config.lua: `tap_to_click`,
// `natural_scroll`, `disable_while_typing`.
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
    log.info("pointer {?s}: tap {}, natural scroll {}", .{ device.name, cfg.tap_to_click, cfg.natural_scroll });
}
