// SPDX-License-Identifier: MIT
//
// Build configuration for wmaker-wl (Wayland window manager).
// Generates Wayland protocol bindings from XML, compiles Zig source.

const std = @import("std");
const Scanner = @import("wayland").Scanner;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Initialize the Wayland protocol scanner.
    const scanner = Scanner.create(b, .{});

    // Add the custom river window management protocol.
    scanner.addCustomProtocol(
        b.path("protocol/river-window-management-v1.xml"),
    );

    // Generate bindings for river_window_manager_v1 protocol version 4.
    scanner.generate("river_window_manager_v1", 4);

    // Create module for generated Wayland bindings.
    const wayland = b.createModule(.{
        .root_source_file = scanner.result,
        .target = target,
        .optimize = optimize,
    });

    // Create the main executable.
    const exe = b.addExecutable(.{
        .name = "wmaker-wl",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{
                    .name = "wayland",
                    .module = wayland,
                },
            },
        }),
        // Zig 0.16.0 + current Arch GCC/glibc:
        // use LLVM instead of the Zig linker to handle
        // R_X86_64_PC64 relocations in crt1.o/.sframe.
        .use_llvm = true,
    });

    // Link libwayland-client.
    exe.root_module.linkSystemLibrary("wayland-client", .{});

    // Install executable.
    b.installArtifact(exe);

    // `zig build run`
    const run_step = b.step("run", "Run wmaker-wl");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
}
