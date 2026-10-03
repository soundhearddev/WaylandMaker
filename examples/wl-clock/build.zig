const std = @import("std");
const Scanner = @import("wayland").Scanner;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ---- protocol bindings ------------------------------------------------
    const scanner = Scanner.create(b, .{});
    scanner.addSystemProtocol("stable/xdg-shell/xdg-shell.xml");

    // Optional at run time: lets the clock ask for the normal arrow cursor
    // when the pointer is over it, like wmaker-wl's own menus do.
    scanner.addSystemProtocol("staging/cursor-shape/cursor-shape-v1.xml");
    // wp_cursor_shape_manager_v1.get_tablet_tool_v2 mentions
    // zwp_tablet_tool_v2; the scanner needs its definition even though only
    // get_pointer is used.
    scanner.addSystemProtocol("stable/tablet/tablet-v2.xml");

    scanner.generate("wl_compositor", 4);
    scanner.generate("wl_shm", 1);
    scanner.generate("wl_seat", 5);
    scanner.generate("xdg_wm_base", 3);
    scanner.generate("wp_cursor_shape_manager_v1", 1);

    const wayland_module = b.createModule(.{
        .root_source_file = scanner.result,
        .target = target,
        .optimize = optimize,
    });

    // ---- executable ---------------------------------------------------
    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true, // localtime_r, poll, setenv
    });
    exe_module.addImport("wayland", wayland_module);
    exe_module.linkSystemLibrary("wayland-client", .{});

    const exe = b.addExecutable(.{
        .name = "wl-clock",
        .root_module = exe_module,
        .use_llvm = true, // avoids the self-hosted backend's SEGV / GCC 16 linker errors
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the clock (inside a Wayland session; extra arguments go to wl-clock)");
    run_step.dependOn(&run_cmd.step);

    // ---- tests ----------------------------------------------------------
    const tests = b.addTest(.{
        .root_module = exe_module,
        .use_llvm = true,
    });
    const test_step = b.step("test", "Run the unit tests (no compositor needed)");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
