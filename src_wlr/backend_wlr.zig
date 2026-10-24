// SPDX-License-Identifier: GPL-3.0
//
// Backend handles: wlroots.
//
// Same names as src/backend_river.zig, so the model (types, layout, workspace,
// action, config, ...) compiles without river. This file must not import
// wlroots: `zig build wlr-model-check` builds the model against it with no
// compositor library at all.
//
// The handles are opaque to the model. The compositor in this directory puts
// its own objects behind them and turns them back with `from`:
//
//   types.Window.obj      -> view.View
//   types.Output.obj      -> output.Monitor
//   types.Seat.obj        -> cursor.Cursor's seat (server.Server)
//   types.WindowManager.obj -> server.Server
//
// The few calls the model makes into the compositor (`manageDirty`,
// `closeWindow`) go through `hooks`, which the compositor fills at start-up.
// Until then they do nothing, which is also what the model tests want.

pub const Window = opaque {};
pub const Node = opaque {};
pub const Output = opaque {};
pub const LayerShellOutput = opaque {};
pub const WlOutput = opaque {};
pub const XkbBinding = opaque {};
pub const PointerBinding = opaque {};
pub const Seat = opaque {};
pub const WindowManager = opaque {};
pub const XkbBindings = opaque {};
pub const LayerShell = opaque {};

/// Same bit values as river's `modifiers` and wlroots' `wlr_keyboard_modifier`
/// (both follow the X11 mask), so `config.modsBits` and saved bindings stay
/// identical in every backend.
pub const Modifiers = packed struct(u32) {
    shift: bool = false,
    _caps: bool = false,
    ctrl: bool = false,
    mod1: bool = false,
    _num: bool = false,
    mod3: bool = false,
    mod4: bool = false,
    mod5: bool = false,
    _padding: u24 = 0,
};

// ---- handle <-> object ------------------------------------------------------

/// Hand an object of the compositor to the model as an opaque handle.
pub fn handle(comptime H: type, object: anytype) *H {
    return @ptrCast(object);
}

/// Get the compositor's object back from a handle the model kept.
pub fn from(comptime T: type, h: anytype) *T {
    return @ptrCast(@alignCast(h));
}

// ---- calls the model makes into the compositor --------------------------------

pub const Hooks = struct {
    manage_dirty: *const fn (wm: *WindowManager) void = noManageDirty,
    close_window: *const fn (w: *Window) void = noCloseWindow,
};

fn noManageDirty(_: *WindowManager) void {}
fn noCloseWindow(_: *Window) void {}

/// Set once by the compositor before the first event is handled.
pub var hooks: Hooks = .{};

/// Ask for a manage pass (state changed outside one). Cheap and idempotent:
/// the compositor runs at most one pass per turn of its event loop.
pub fn manageDirty(wm: *WindowManager) void {
    hooks.manage_dirty(wm);
}

/// Ask the client to close its window.
pub fn closeWindow(w: *Window) void {
    hooks.close_window(w);
}
