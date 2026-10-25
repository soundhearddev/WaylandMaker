// SPDX-License-Identifier: GPL-3.0
//
// `zig build wlr-model-check`: the model builds against the wlroots backend
// handles (no river type anywhere), and everything of the wlroots backend
// that needs no compositor library works: key matching and the manage pass.
// Runs without a display and without wlroots installed.

const std = @import("std");
const model = @import("model");

test "model compiles without river" {
    std.testing.refAllDecls(model.types);
    std.testing.refAllDecls(model.layout);
    std.testing.refAllDecls(model.workspace);
    std.testing.refAllDecls(model.action);
    std.testing.refAllDecls(model.config);
    std.testing.refAllDecls(model.wm_files);
    std.testing.refAllDecls(model.monitors);
    std.testing.refAllDecls(model.wm_attr);
}

test {
    _ = @import("keys.zig");
    _ = @import("manage.zig");
    _ = @import("cli.zig");
    _ = @import("pointer_op.zig");
    std.testing.refAllDecls(model.motion);
    _ = model.motion;
}
