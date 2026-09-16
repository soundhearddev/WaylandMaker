// SPDX-License-Identifier: 0BSD
//
// Build script for our scrollable-tiling / Window Maker style river window
// manager client.
//
// This mirrors tinyrwm's build.zig almost exactly (protocol scanning,
// xkbcommon dependency, event-codes header), since it is the reference
// implementation of a river-window-management-v1 client. We just renamed
// the executable and kept the module wiring the same, so this should
// build with the same `zig build` invocation tinyrwm uses.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const scanner = @import("wayland").Scanner.create(b, .{});
    scanner.addCustomProtocol(b.path("protocol/river-window-management-v1.xml"));
    scanner.addCustomProtocol(b.path("protocol/river-xkb-bindings-v1.xml"));
    scanner.generate("river_window_manager_v1", 4);
    scanner.generate("river_xkb_bindings_v1", 3);
    const wayland = b.createModule(.{ .root_source_file = scanner.result });

    const xkbcommon = b.dependency("xkbcommon", .{}).module("xkbcommon");

    const files = b.addWriteFiles();
    const headers = files.add("headers.h",
        \\#include <linux/input-event-codes.h>
    );
    const input_event_codes = b.addTranslateC(.{
        .root_source_file = headers,
        .optimize = optimize,
        .target = target,
        .link_libc = true,
    });

    const exe = b.addExecutable(.{
        .name = "wmaker-wl",
        .use_llvm = true,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "wayland", .module = wayland },
                .{ .name = "xkbcommon", .module = xkbcommon },
                .{ .name = "event-codes", .module = input_event_codes.createModule() },
            },
        }),
    });

    exe.use_llvm = true;
    exe.use_lld = true;

    exe.entry = .disabled;

    exe.root_module.linkSystemLibrary("wayland-client", .{});
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the window manager");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
}
