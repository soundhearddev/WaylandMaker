const std = @import("std");
const Scanner = @import("wayland").Scanner;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const use_llvm = b.option(bool, "llvm", "Use LLVM backend + lld linker") orelse true;

    // ---- protocol bindings ----------------------------------------------

    const scanner = Scanner.create(b, .{});

    scanner.addCustomProtocol(
        b.path("protocol/river-window-management-v1.xml"),
    );
    scanner.addCustomProtocol(
        b.path("protocol/river-xkb-bindings-v1.xml"),
    );
    scanner.addCustomProtocol(
        b.path("protocol/river-layer-shell-v1.xml"),
    );
    scanner.addSystemProtocol("staging/cursor-shape/cursor-shape-v1.xml");
    // wp_cursor_shape_manager_v1.get_tablet_tool_v2 references
    // zwp_tablet_tool_v2; the scanner needs its definition even though we
    // never call that request (we only use get_pointer).
    scanner.addSystemProtocol("stable/tablet/tablet-v2.xml");

    scanner.generate("wl_compositor", 6);
    scanner.generate("wl_shm", 1);
    scanner.generate("wl_seat", 7);
    scanner.generate("wl_output", 4);
    scanner.generate("wl_subcompositor", 1);
    scanner.generate("wp_cursor_shape_manager_v1", 2);

    scanner.generate("river_window_manager_v1", 6);
    scanner.generate("river_xkb_bindings_v1", 3);
    scanner.generate("river_layer_shell_v1", 1);

    const wayland_module = b.createModule(.{
        .root_source_file = scanner.result,
        .target = target,
        .optimize = optimize,
    });

    // ---- dependencies ---------------------------------------------------

    const xkbcommon_module =
        b.dependency("xkbcommon", .{}).module("xkbcommon");

    // ---- helper: link graphics libs with include paths -------------------

    const fn_link_graphics = struct {
        fn call(bld: *std.Build, module: *std.Build.Module) void {
            module.linkSystemLibrary("wayland-client", .{});
            module.linkSystemLibrary("xkbcommon", .{});
            module.linkSystemLibrary("cairo", .{});
            module.linkSystemLibrary("pango-1.0", .{});
            module.linkSystemLibrary("pangocairo-1.0", .{});
            module.linkSystemLibrary("gobject-2.0", .{});
            module.linkSystemLibrary("glib-2.0", .{});

            module.addIncludePath(bld.path("src"));

            module.addIncludePath(.{ .cwd_relative = "/usr/include/glib-2.0" });
            module.addIncludePath(.{ .cwd_relative = "/usr/lib/glib-2.0/include" });
            module.addIncludePath(.{ .cwd_relative = "/usr/include/cairo" });
            module.addIncludePath(.{ .cwd_relative = "/usr/include/pango-1.0" });
            module.addIncludePath(.{ .cwd_relative = "/usr/include/harfbuzz" });
        }
    }.call;

    // ---- project root module --------------------------------------------

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    root_module.addImport("wayland", wayland_module);
    root_module.addImport("xkbcommon", xkbcommon_module);

    fn_link_graphics(b, root_module);

    root_module.addCSourceFile(.{
        .file = b.path("src/wm_text.c"),
        .flags = &.{},
    });
    // ---- imports available to every project module ----------------------

    const imports: []const std.Build.Module.Import = &.{
        .{
            .name = "wmaker",
            .module = root_module,
        },
        .{
            .name = "wayland",
            .module = wayland_module,
        },
        .{
            .name = "xkbcommon",
            .module = xkbcommon_module,
        },
    };

    // ---- executable -----------------------------------------------------

    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = imports,
    });

    fn_link_graphics(b, exe_module);

    const exe = b.addExecutable(.{
        .name = "wmaker-wl",
        .root_module = exe_module,
        .use_llvm = use_llvm,
        .use_lld = use_llvm,
    });

    b.installArtifact(exe);

    // ---- run -------------------------------------------------------------

    const run_cmd = b.addSystemCommand(
        &.{ "river", "-c", "zig-out/bin/wmaker-wl" },
    );

    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step(
        "run",
        "Run river with wmaker-wl as window manager",
    );

    run_step.dependOn(&run_cmd.step);

    // ---- tests -----------------------------------------------------------

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = imports,
    });

    fn_link_graphics(b, test_module);

    const tests = b.addTest(.{
        .root_module = test_module,
        .use_llvm = use_llvm,
        .use_lld = use_llvm,
    });

    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
