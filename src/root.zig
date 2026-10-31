// SPDX-License-Identifier: GPL-3.0
//
// The test root of `zig build test`: everything of wmaker-wl that needs no
// compositor library (wlroots) and no display.
//
// THE place where test files are registered. `zig build test` runs the tests
// of a file only if it is named here, and a plain `@import` elsewhere does
// not count. A new file with `test` blocks gets one line below.

pub const model = @import("model.zig");

test {
    _ = @import("action.zig");
    _ = @import("appicon.zig");
    _ = @import("animation.zig");
    _ = @import("bench.zig");
    _ = @import("cli.zig");
    _ = @import("config.zig");
    _ = @import("dockapp.zig");
    _ = @import("diag.zig");
    _ = @import("diag_test.zig");
    _ = @import("dump.zig");
    _ = @import("fileutil.zig");
    _ = @import("fuzz_test.zig");
    _ = @import("gfx.zig");
    _ = @import("invariants.zig");
    _ = @import("keys.zig");
    _ = @import("layout.zig");
    _ = @import("log.zig");
    _ = @import("lua.zig");
    _ = @import("manage.zig");
    _ = @import("model_test.zig");
    _ = @import("monitors.zig");
    _ = @import("motion.zig");
    _ = @import("outputs.zig");
    _ = @import("dock_draw.zig");
    _ = @import("dock_icons.zig");
    _ = @import("dock_input.zig");
    _ = @import("dock_model.zig");
    _ = @import("dock_sync.zig");
    _ = @import("dockhost.zig");
    _ = @import("dock_view.zig");
    _ = @import("perf.zig");
    _ = @import("process.zig");
    _ = @import("plist.zig");
    _ = @import("pointer_op.zig");
    _ = @import("scale.zig");
    _ = @import("session.zig");
    _ = @import("style.zig");
    _ = @import("sysmap.zig");
    _ = @import("svg.zig");
    _ = @import("trace.zig");
    _ = @import("wm_attr.zig");
    _ = @import("wm_dock.zig");
    _ = @import("wm_files.zig");
    _ = @import("xpm.zig");
    _ = @import("wm_menu.zig");
    _ = @import("workspace.zig");
}
