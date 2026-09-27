const std = @import("std");
const Scanner = @import("wayland").Scanner;

// wlprefs: standalone settings-window skeleton for wmaker-wl.
//
// This is a plain Wayland client (xdg-shell), not a river-window-management
// client like wmaker-wl itself. That means the running window manager just
// sees it as an ordinary toplevel window and tiles/floats it like any other
// app -- no special-casing needed on the wmaker-wl side beyond a menu entry
// that launches the binary (see ../src/share/RootMenu).
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ---- protocol bindings ------------------------------------------------

    const scanner = Scanner.create(b, .{});

    // xdg-shell ships with libwayland-protocols and is fetched by the
    // scanner itself ("addSystemProtocol"); no local copy needed.
    scanner.addSystemProtocol("stable/xdg-shell/xdg-shell.xml");

    scanner.generate("wl_compositor", 6);
    scanner.generate("wl_shm", 1);
    scanner.generate("wl_seat", 7);
    scanner.generate("xdg_wm_base", 3);

    const wayland_module = b.createModule(.{
        .root_source_file = scanner.result,
        .target = target,
        .optimize = optimize,
    });

    // ---- dependencies -------------------------------------------------------

    const xkbcommon_module = b.dependency("xkbcommon", .{}).module("xkbcommon");

    // ---- helper: link graphics libs with include paths ---------------------
    //
    // Same set wmaker-wl links against, so the two binaries behave the same
    // on any system that can already build wmaker-wl.

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

    // ---- library module (protocol glue, window, config-path helpers) -------

    const mod = b.addModule("wlprefs", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    mod.addImport("wayland", wayland_module);
    mod.addImport("xkbcommon", xkbcommon_module);
    fn_link_graphics(b, mod);

    mod.addCSourceFile(.{
        .file = b.path("src/wm_text.c"),
        .flags = &.{},
    });

    // ---- executable ---------------------------------------------------------

    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "wlprefs", .module = mod },
            .{ .name = "wayland", .module = wayland_module },
            .{ .name = "xkbcommon", .module = xkbcommon_module },
        },
    });

    fn_link_graphics(b, exe_module);

    const exe = b.addExecutable(.{
        .name = "wlprefs",
        .root_module = exe_module,
        .use_llvm = true,
        .use_lld = true,
    });

    b.installArtifact(exe);

    // ---- run ------------------------------------------------------------

    const run_step = b.step("run", "Run wlprefs");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);

    // ---- tests ------------------------------------------------------------

    const mod_tests = b.addTest(.{
        .root_module = mod,
        .use_llvm = true,
        .use_lld = true,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
}
