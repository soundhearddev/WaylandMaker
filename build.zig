// SPDX-License-Identifier: 0BSD
//
// Build script for our scrollable-tiling / Window Maker style river window
// manager client.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const scanner = @import("wayland").Scanner.create(b, .{});
    scanner.addCustomProtocol(b.path("protocol/river-window-management-v1.xml"));
    scanner.addCustomProtocol(b.path("protocol/river-xkb-bindings-v1.xml"));
    scanner.generate("river_window_manager_v1", 6);
    scanner.generate("river_xkb_bindings_v1", 1);
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

    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "wayland", .module = wayland },
            .{ .name = "xkbcommon", .module = xkbcommon },
            .{ .name = "event-codes", .module = input_event_codes.createModule() },
        },
    });
    exe_module.linkSystemLibrary("wayland-client", .{});
    exe_module.linkSystemLibrary("xkbcommon", .{});

    const exe = b.addExecutable(.{
        .name = "wmaker-wl",
        .root_module = exe_module,
    });

    exe.use_llvm = true;

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the window manager");
    const run_cmd = b.addSystemCommand(&.{
        "sh", "-c",
        \\river -c "zig-out/bin/wmaker-wl"
    });

    run_cmd.step.dependOn(b.getInstallStep());
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
}
