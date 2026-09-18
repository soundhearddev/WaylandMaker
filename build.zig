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

    // 1. River-Dependency laden
    const river_dep = b.dependency("river", .{
        .target = target,
        .optimize = optimize,
        .llvm = use_llvm,
        .xwayland = false,
    });

    // 2. Wayland-Scanner initialisieren
    const scanner = Scanner.create(b, .{});

    // Custom Protocol von River hinzufügen
    scanner.addCustomProtocol(
        b.path("protocol/river-window-management-v1.xml"),
    );

    // Protocol-Code generieren
    scanner.generate(
        "river_window_manager_v1",
        4,
    );

    const wayland_module = b.createModule(.{
        .root_source_file = scanner.result,
        .target = target,
        .optimize = optimize,
    });

    // Imports zusammenstellen
    var imports_list = std.ArrayList(std.Build.Module.Import).empty;
    try imports_list.append(b.allocator, .{
        .name = "wayland",
        .module = wayland_module,
    });

    if (river_dep.builder.modules.get("river-layout-toolkit")) |river_layout| {
        try imports_list.append(b.allocator, .{
            .name = "river-layout-toolkit",
            .module = river_layout,
        });
    }

    // 3. Executable (wmaker-wl) konfigurieren
    const exe = b.addExecutable(.{
        .name = "wmaker-wl",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = imports_list.items,
            .link_libc = true, // In Zig 0.16 wird libc direkt im Modul aktiviert
        }),
        .use_llvm = use_llvm,
        .use_lld = use_llvm,
    });

    // System-Library an das Root-Modul binden
    exe.root_module.addSystemIncludePath(.{ .cwd_relative = "/usr/include" });
    exe.root_module.linkSystemLibrary("wayland-client", .{});

    b.installArtifact(exe);

    // River Executable installieren
    const river_exe = river_dep.artifact("river");
    b.installArtifact(river_exe);

    // 4. Run-Step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run wmaker-wl");
    run_step.dependOn(&run_cmd.step);
}
