// SPDX-License-Identifier: 0BSD
//
// Build script for wmaker-wl: a scrollable-tiling / Window Maker flavoured
// window manager client for river (river-window-management-v1).

const std = @import("std");
const Scanner = @import("wayland").Scanner;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const use_llvm = b.option(bool, "llvm", "Use LLVM backend + lld linker") orelse true;

    // ---- protocol bindings ----------------------------------------------
    // river_xkb_bindings_v1 and river_layer_shell_v1 are separate protocol
    // files; without them no key can be bound and layer surfaces are
    // refused.
    const scanner = Scanner.create(b, .{});
    scanner.addCustomProtocol(b.path("protocol/river-window-management-v1.xml"));
    scanner.addCustomProtocol(b.path("protocol/river-xkb-bindings-v1.xml"));
    scanner.addCustomProtocol(b.path("protocol/river-layer-shell-v1.xml"));

    scanner.generate("wl_compositor", 6);
    scanner.generate("wl_shm", 1);
    scanner.generate("wl_seat", 7);
    scanner.generate("wl_output", 4);
    scanner.generate("wl_subcompositor", 1);

    scanner.generate("river_window_manager_v1", 6);
    scanner.generate("river_xkb_bindings_v1", 3);
    scanner.generate("river_layer_shell_v1", 1);

    const wayland_module = b.createModule(.{
        .root_source_file = scanner.result,
        .target = target,
        .optimize = optimize,
    });

    // xkbcommon resolves key *names* ("Return", "h") to keysyms.
    const xkbcommon_module = b.dependency("xkbcommon", .{}).module("xkbcommon");

    const imports: []const std.Build.Module.Import = &.{
        .{ .name = "wayland", .module = wayland_module },
        .{ .name = "xkbcommon", .module = xkbcommon_module },
    };

    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = imports,
    });
    exe_module.linkSystemLibrary("wayland-client", .{});
    exe_module.linkSystemLibrary("xkbcommon", .{});
    exe_module.linkSystemLibrary("cairo", .{});
    exe_module.linkSystemLibrary("pango", .{});
    exe_module.linkSystemLibrary("pangocairo", .{});
    exe_module.linkSystemLibrary("glib-2.0", .{});

    const exe = b.addExecutable(.{
        .name = "wmaker-wl",
        .root_module = exe_module,
        .use_llvm = use_llvm,
        .use_lld = use_llvm,
    });
    b.installArtifact(exe);

    // ---- run --------------------------------------------------------------
    const run_cmd = b.addSystemCommand(&.{ "river", "-c", "zig-out/bin/wmaker-wl" });
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run river with wmaker-wl as window manager");
    run_step.dependOn(&run_cmd.step);

    // ---- tests --------------------------------------------------------------
    // Same root as the executable, so every `test` block in every file
    // reachable from main.zig runs.
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = imports,
    });
    test_module.linkSystemLibrary("wayland-client", .{});
    test_module.linkSystemLibrary("xkbcommon", .{});
    test_module.linkSystemLibrary("cairo", .{});
    test_module.linkSystemLibrary("pango", .{});
    test_module.linkSystemLibrary("pangocairo", .{});
    test_module.linkSystemLibrary("glib-2.0", .{});

    const tests = b.addTest(.{
        .root_module = test_module,
        .use_llvm = use_llvm,
        .use_lld = use_llvm,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
