// SPDX-License-Identifier: 0BSD
//
// Build script for wmaker-wl: a scrollable-tiling / Window Maker flavoured
// window manager client for river (river-window-management-v1).

const std = @import("std");
const Scanner = @import("wayland").Scanner;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Optional: allow -Dllvm=false to try the self-hosted backend.
    const use_llvm = b.option(bool, "llvm", "Use LLVM backend + lld linker") orelse true;

    // ------------------------------------------------------------------
    // Wayland protocol bindings. BOTH river protocols must be scanned:
    // river_xkb_bindings_v1 is a *separate* protocol file, and without it
    // no keybinding can ever be registered (this was the reason Mod+Return
    // did nothing).
    // ------------------------------------------------------------------
    const scanner = Scanner.create(b, .{});
    scanner.addCustomProtocol(b.path("protocol/river-window-management-v1.xml"));
    scanner.addCustomProtocol(b.path("protocol/river-xkb-bindings-v1.xml"));
    scanner.addCustomProtocol(b.path("protocol/river-layer-shell-v1.xml"));

    scanner.generate("river_window_manager_v1", 6);
    scanner.generate("river_xkb_bindings_v1", 1);
    scanner.generate("river_layer_shell_v1", 1);

    const wayland_module = b.createModule(.{
        .root_source_file = scanner.result,
        .target = target,
        .optimize = optimize,
    });

    // xkbcommon: used to resolve keysym *names* ("Return", "h", ...) to
    // real keysyms instead of hand-maintained numeric tables.
    const xkbcommon_module = b.dependency("xkbcommon", .{}).module("xkbcommon");

    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "wayland", .module = wayland_module },
            .{ .name = "xkbcommon", .module = xkbcommon_module },
        },
    });
    exe_module.linkSystemLibrary("wayland-client", .{});
    exe_module.linkSystemLibrary("xkbcommon", .{});

    const exe = b.addExecutable(.{
        .name = "wmaker-wl",
        .root_module = exe_module,
        .use_llvm = use_llvm,
        .use_lld = use_llvm,
    });
    b.installArtifact(exe);

    // `zig build run` starts river with us as its window manager.
    const run_cmd = b.addSystemCommand(&.{ "river", "-c", "zig-out/bin/wmaker-wl" });
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run river with wmaker-wl as window manager");
    run_step.dependOn(&run_cmd.step);
}
