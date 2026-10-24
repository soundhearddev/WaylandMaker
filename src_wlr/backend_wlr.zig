// SPDX-License-Identifier: GPL-3.0
//
// Backend handles: wlroots (placeholder).
//
// Same names as src/backend_river.zig, so the model compiles without river.
// The handles are opaque for now; they become real structs (wlr_scene_tree,
// xdg toplevel, wlr_output, ...) when the wlroots backend is written. Until
// then the calls below do nothing, except `closeWindow`, which calls the hook
// `close_fn` that probe.zig sets.

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

/// Same bit values as river's `modifiers` (and wlroots' WLR_MODIFIER_*, minus
/// the locked ones), so `config.modsBits` and saved bindings stay identical.
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

pub fn manageDirty(wm: *WindowManager) void {
    _ = wm;
}

/// Set by the compositor: how to ask a window to close.
pub var close_fn: ?*const fn (*Window) void = null;

pub fn closeWindow(w: *Window) void {
    if (close_fn) |f| f(w);
}
