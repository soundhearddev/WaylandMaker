// SPDX-License-Identifier: GPL-3.0
//
// Backend handles: river.
//
// The data model (types.zig and everything that only uses it) must not name
// a compositor protocol. What it stores about the compositor connection,
// and the few calls it makes into it, come from the module `backend`.
// For the river build that module is this file, so nothing changes at run
// time: every handle is the generated river type itself.
//
// The wlroots build provides the same names from src_wlr/backend_wlr.zig.

const wayland = @import("wayland");
const river = wayland.client.river;
const wl = wayland.client.wl;

pub const Window = river.WindowV1;
pub const Node = river.NodeV1;
pub const Output = river.OutputV1;
pub const LayerShellOutput = river.LayerShellOutputV1;
/// A bound `wl_output` (monitor name, make, model).
pub const WlOutput = wl.Output;
pub const XkbBinding = river.XkbBindingV1;
pub const PointerBinding = river.PointerBindingV1;
pub const Seat = river.SeatV1;
pub const WindowManager = river.WindowManagerV1;
pub const XkbBindings = river.XkbBindingsV1;
pub const LayerShell = river.LayerShellV1;

pub const Modifiers = river.SeatV1.Modifiers;

// ---- calls the model makes into the compositor -----------------------------

/// Ask for a manage sequence (state changed outside one).
pub fn manageDirty(wm: *WindowManager) void {
    wm.manageDirty();
}

/// Ask the client to close its window.
pub fn closeWindow(w: *Window) void {
    w.close();
}
