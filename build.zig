const std = @import("std");
const Scanner = @import("wayland").Scanner;

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const use_llvm = b.option(
        bool,
        "llvm",
        "Use LLVM linker",
    ) orelse true;

    // Build River using its own build.zig.
    const river = b.dependency("river", .{
        .target = target,
        .optimize = optimize,
        .llvm = use_llvm,
        .xwayland = false,
    });

    // River's build.zig installs the "river" artifact.
    b.installArtifact(river.artifact("river"));

    // Build wmaker-wl.
    const scanner = Scanner.create(b, .{});

    scanner.addCustomProtocol(
        b.path("protocol/river-window-management-v1.xml"),
    );

    scanner.generate(
        "river_window_manager_v1",
        4,
    );

    const wayland = b.createModule(.{
        .root_source_file = scanner.result,
        .target = target,
        .optimize = optimize,
    });

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
        .use_llvm = use_llvm,
        .use_lld = use_llvm,
    });

    exe.root_module.linkSystemLibrary(
        "wayland-client",
        .{},
    );

    b.installArtifact(exe);
}
