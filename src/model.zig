// SPDX-License-Identifier: GPL-3.0
//
// The backend-independent part of wmaker-wl: data model, layout, workspace
// operations, commands, config. Nothing in here may name river or wlroots;
// compositor handles come from the `backend` module (see backend_river.zig).
//
// Used as the root of the `model` module by `zig build wlr-model-check`.
// The river build keeps using root.zig.

pub const types = @import("types.zig");
pub const layout = @import("layout.zig");
pub const workspace = @import("workspace.zig");
pub const action = @import("action.zig");
pub const config = @import("config.zig");
pub const animation = @import("animation.zig");
pub const monitors = @import("monitors.zig");
pub const dockapp = @import("dockapp.zig");
pub const wm_attr = @import("wm_attr.zig");
pub const wm_menu = @import("wm_menu.zig");
pub const plist = @import("plist.zig");
pub const proc = @import("process.zig");
pub const wm_files = @import("wm_files.zig");
pub const log = @import("log.zig");
pub const trace = @import("trace.zig");
pub const version = @import("version.zig");
