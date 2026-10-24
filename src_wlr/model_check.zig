// SPDX-License-Identifier: GPL-3.0
//
// Compile gate: the model must build with the wlroots backend, i.e. without
// any river type. `zig build wlr-model-check`.

const std = @import("std");
const model = @import("model");

test "model compiles without river" {
    std.testing.refAllDecls(model.types);
    std.testing.refAllDecls(model.layout);
    std.testing.refAllDecls(model.workspace);
    std.testing.refAllDecls(model.action);
    std.testing.refAllDecls(model.config);
}
