pub const workspace = @import("workspace.zig");
pub const animation = @import("animation.zig");
pub const action = @import("action.zig");
pub const compatibility = @import("compatibility.zig");
pub const dockapp = @import("dockapp.zig");
pub const dockhost = @import("dockhost.zig");
pub const dock = @import("dock.zig");
pub const config = @import("config.zig");
pub const gfx = @import("gfx.zig");
pub const scale = @import("scale.zig");
pub const main = @import("main.zig");
pub const output = @import("output.zig");
pub const types = @import("types.zig");
pub const layout = @import("layout.zig");
pub const window = @import("window.zig");
pub const seat_mod = @import("seat.zig");
pub const wm_files = @import("wm_files.zig");
pub const proc = @import("process.zig");
pub const ui = @import("ui.zig");
pub const plist = @import("plist.zig");
pub const version = @import("version.zig");
pub const monitors = @import("monitors.zig");
pub const invariants = @import("invariants.zig");
pub const dump = @import("dump.zig");
pub const perf = @import("perf.zig");
pub const trace = @import("trace.zig");

// ---- tests ---------------------------------------------------------------
//
// THE place where test files are registered. `zig build test` runs the tests
// of a file only if it is named here, and a `pub const x = @import(..)` above
// does not count. A new file with `test` blocks gets one line:
//
//     _ = @import("name.zig");
//
// (main.zig is the test root, so its own tests run without a line.)
test {
    _ = @import("action.zig");
    _ = @import("anim.zig");
    _ = @import("animation.zig");
    _ = @import("appicon.zig");
    _ = @import("bench.zig");
    _ = @import("compatibility.zig");
    _ = @import("config.zig");
    _ = @import("diag_test.zig");
    _ = @import("dock.zig");
    _ = @import("dockapp.zig");
    _ = @import("dockhost.zig");
    _ = @import("dump.zig");
    _ = @import("fileutil.zig");
    _ = @import("fsmenu.zig");
    _ = @import("fuzz_test.zig");
    _ = @import("gfx.zig");
    _ = @import("invariants.zig");
    _ = @import("layout.zig");
    _ = @import("log.zig");
    _ = @import("lua.zig");
    _ = @import("miniwin.zig");
    _ = @import("model_test.zig");
    _ = @import("monitors.zig");
    _ = @import("output.zig");
    _ = @import("perf.zig");
    _ = @import("plist.zig");
    _ = @import("scale.zig");
    _ = @import("seat.zig");
    _ = @import("shm.zig");
    _ = @import("svg.zig");
    _ = @import("trace.zig");
    _ = @import("ui.zig");
    _ = @import("window.zig");
    _ = @import("wm_attr.zig");
    _ = @import("wm_dock.zig");
    _ = @import("wm_files.zig");
    _ = @import("wm_menu.zig");
    _ = @import("workspace.zig");
    _ = @import("xpm.zig");
}
