
const std = @import("std");
const Scanner = @import("wayland").Scanner;

/// The system libraries every wmaker-wl / wlprefs module draws with.
fn linkGraphics(module: *std.Build.Module, src_dir: std.Build.LazyPath) void {
    const libs = [_][]const u8{
        "wayland-client",
        "xkbcommon",
        "cairo",
        "pango",
        "pangocairo",
        "gobject-2.0",
        "glib-2.0",
    };

    for (libs) |name| {
        module.linkSystemLibrary(name, .{ .use_pkg_config = .force });
    }

    module.addIncludePath(src_dir);
}

/// Cairo and Pango for the Dock's drawing and tests.
fn linkCairo(b: *std.Build, module: *std.Build.Module) void {
    const libs = [_][]const u8{
        "cairo",
        "pango",
        "pangocairo",
        "gobject-2.0",
        "glib-2.0",
    };

    for (libs) |name| {
        module.linkSystemLibrary(name, .{ .use_pkg_config = .force });
    }

    module.addIncludePath(b.path("src"));
    module.addCSourceFile(.{
        .file = b.path("src/wm_text.c"),
        .flags = &.{},
    });
}

/// Build wlprefs as part of the root project.
pub const Wlprefs = struct {
    exe: *std.Build.Step.Compile,
    mod: *std.Build.Module,
    settings: *std.Build.Module,
    actions: *std.Build.Module,
};

pub fn buildWlprefs(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    use_llvm: bool,
) Wlprefs {
    const projectPath = struct {
        fn get(
            bld: *std.Build,
            comptime p: []const u8,
        ) std.Build.LazyPath {
            return bld.path(bld.fmt("wlprefs/{s}", .{p}));
        }
    }.get;

    // ---- protocol bindings ----------------------------------------------

    const scanner = Scanner.create(b, .{});

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

    // ---- dependencies ---------------------------------------------------

    const xkbcommon_module =
        b.dependency("xkbcommon", .{}).module("xkbcommon");

    // ---- library module -------------------------------------------------

    const mod = b.addModule("wlprefs", .{
        .root_source_file = projectPath(b, "src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    mod.addImport("wayland", wayland_module);
    mod.addImport("xkbcommon", xkbcommon_module);

    mod.addAnonymousImport("default_config.lua", .{
        .root_source_file = b.path("src/share/default_config.lua"),
    });

    linkGraphics(mod, projectPath(b, "src"));

    mod.addCSourceFile(.{
        .file = projectPath(b, "src/wm_text.c"),
        .flags = &.{},
    });

    // ---- executable -----------------------------------------------------

    const exe_module = b.createModule(.{
        .root_source_file = projectPath(b, "src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "wlprefs", .module = mod },
            .{ .name = "wayland", .module = wayland_module },
            .{ .name = "xkbcommon", .module = xkbcommon_module },
        },
    });

    linkGraphics(exe_module, projectPath(b, "src"));

    const exe = b.addExecutable(.{
        .name = "wlprefs",
        .root_module = exe_module,
        .use_llvm = use_llvm,
        .use_lld = use_llvm,
    });

    const settings_mod = b.createModule(.{
        .root_source_file = projectPath(b, "src/settings.zig"),
        .target = target,
        .optimize = optimize,
    });

    settings_mod.addAnonymousImport("default_config.lua", .{
        .root_source_file = b.path("src/share/default_config.lua"),
    });

    const actions_mod = b.createModule(.{
        .root_source_file = projectPath(b, "src/actions.zig"),
        .target = target,
        .optimize = optimize,
    });

    return .{
        .exe = exe,
        .mod = mod,
        .settings = settings_mod,
        .actions = actions_mod,
    };
}

// -------------------------------------------------------------------------
// wmaker-wl -- also builds wlprefs
// -------------------------------------------------------------------------

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const use_llvm = b.option(
        bool,
        "llvm",
        "Use LLVM backend + lld linker",
    ) orelse true;

    // ---- dependencies ---------------------------------------------------

    const xkbcommon_module =
        b.dependency("xkbcommon", .{}).module("xkbcommon");

    const zlua_dep = b.dependency("zlua", .{
        .target = target,
        .optimize = optimize,
        .lang = .lua54,
    });

    const zlua_module = zlua_dep.module("zlua");
    const pixman_module = b.dependency("pixman", .{}).module("pixman");

    // ---- Wayland protocols ---------------------------------------------

    const scanner = Scanner.create(b, .{});

    scanner.addSystemProtocol("stable/xdg-shell/xdg-shell.xml");
    scanner.addSystemProtocol("stable/tablet/tablet-v2.xml");
    scanner.addSystemProtocol("staging/color-management/color-management-v1.xml");
    scanner.addSystemProtocol("staging/cursor-shape/cursor-shape-v1.xml");
    scanner.addSystemProtocol("unstable/xdg-decoration/xdg-decoration-unstable-v1.xml");
    scanner.addSystemProtocol("unstable/primary-selection/primary-selection-unstable-v1.xml");
    scanner.addSystemProtocol("unstable/xdg-output/xdg-output-unstable-v1.xml");
    scanner.addSystemProtocol("stable/linux-dmabuf/linux-dmabuf-v1.xml");
    scanner.addSystemProtocol("stable/viewporter/viewporter.xml");
    scanner.addSystemProtocol("staging/single-pixel-buffer/single-pixel-buffer-v1.xml");

    scanner.generate("wl_compositor", 6);
    scanner.generate("wl_subcompositor", 1);
    scanner.generate("wl_shm", 1);
    scanner.generate("wl_output", 4);
    scanner.generate("wl_seat", 7);
    scanner.generate("wl_data_device_manager", 3);
    scanner.generate("xdg_wm_base", 6);
    scanner.generate("zxdg_decoration_manager_v1", 1);
    scanner.generate("zwp_primary_selection_device_manager_v1", 1);
    scanner.generate("zxdg_output_manager_v1", 3);
    scanner.generate("zwp_linux_dmabuf_v1", 4);
    scanner.generate("wp_viewporter", 1);
    scanner.generate("wp_single_pixel_buffer_manager_v1", 1);
    scanner.generate("zwp_tablet_manager_v2", 1);

    scanner.generate(
        "wp_color_manager_v1",
        b.option(
            u32,
            "color-manager-version",
            "wp_color_manager_v1 version to generate (2 needs wayland-protocols >= 1.44; default 2)",
        ) orelse 2,
    );

    scanner.generate("wp_cursor_shape_manager_v1", 2);

    const wayland_module = b.createModule(.{
        .root_source_file = scanner.result,
        .target = target,
        .optimize = optimize,
    });

    // ---- wlroots module -------------------------------------------------

    const wlroots_module = b.dependency("wlroots", .{}).module("wlroots");

    wlroots_module.addImport("wayland", wayland_module);
    wlroots_module.addImport("xkbcommon", xkbcommon_module);
    wlroots_module.addImport("pixman", pixman_module);
    wlroots_module.resolved_target = target;

    wlroots_module.linkSystemLibrary(
        "wlroots-0.20",
        .{ .use_pkg_config = .force },
    );

    const imports: []const std.Build.Module.Import = &.{
        .{ .name = "wayland", .module = wayland_module },
        .{ .name = "xkbcommon", .module = xkbcommon_module },
        .{ .name = "zlua", .module = zlua_module },
        .{ .name = "wlroots", .module = wlroots_module },
        .{ .name = "pixman", .module = pixman_module },
    };

    // ---- compositor and probe ------------------------------------------

    const exe = addCompositor(
        b,
        imports,
        target,
        optimize,
        use_llvm,
        "wmaker-wl",
        "src/main.zig",
    );

    b.installArtifact(exe);

    const probe = addCompositor(
        b,
        imports,
        target,
        optimize,
        use_llvm,
        "wlr-probe",
        "src/probe.zig",
    );

    const probe_step = b.step(
        "probe",
        "Build wlr-probe: can wlroots be used on this machine at all?",
    );

    probe_step.dependOn(&b.addInstallArtifact(probe, .{}).step);

    // ---- run ------------------------------------------------------------

    const run_cmd = b.addRunArtifact(exe);

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step(
        "run",
        "Run wmaker-wl (nested when a session is already up)",
    );

    run_step.dependOn(&run_cmd.step);

    // ---- wlprefs --------------------------------------------------------

    const wlprefs = buildWlprefs(b, target, optimize, use_llvm);
    b.installArtifact(wlprefs.exe);

    const wlprefs_tests = b.addTest(.{
        .root_module = wlprefs.mod,
        .use_llvm = use_llvm,
        .use_lld = use_llvm,
    });

    const wlprefs_test_step = b.step(
        "test-wlprefs",
        "Run the unit tests of wlprefs",
    );

    wlprefs_test_step.dependOn(&b.addRunArtifact(wlprefs_tests).step);

    // ---- tests ----------------------------------------------------------

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = imports[0..3],
    });

    test_module.linkSystemLibrary(
        "xkbcommon",
        .{ .use_pkg_config = .force },
    );

    linkCairo(b, test_module);
    test_module.addImport("wlprefs_settings", wlprefs.settings);
    test_module.addImport("wlprefs_actions", wlprefs.actions);

    const tests = b.addTest(.{
        .root_module = test_module,
        .use_llvm = use_llvm,
        .use_lld = use_llvm,
    });

    const run_tests = b.addRunArtifact(tests);

    // ---- benchmark ------------------------------------------------------

    const bench_module = b.createModule(.{
        .root_source_file = b.path("src/bench.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = imports[0..3],
    });

    bench_module.linkSystemLibrary(
        "xkbcommon",
        .{ .use_pkg_config = .force },
    );

    linkCairo(b, bench_module);
    bench_module.addImport("wlprefs_settings", wlprefs.settings);
    bench_module.addImport("wlprefs_actions", wlprefs.actions);

    const bench_exe = b.addExecutable(.{
        .name = "wmaker-bench",
        .root_module = bench_module,
        .use_llvm = use_llvm,
        .use_lld = use_llvm,
    });

    const run_bench = b.addRunArtifact(bench_exe);

    if (b.args) |args| {
        run_bench.addArgs(args);
    }

    const bench_step = b.step(
        "bench",
        "Time the window model on synthetic loads (use -Doptimize=ReleaseFast)",
    );

    bench_step.dependOn(&run_bench.step);

    // ---- example DockApps -----------------------------------------------

    const examples_step = b.step(
        "test-examples",
        "Run the unit tests of the example DockApps (wl-battery, wl-clock)",
    );

    inline for (.{ "wl-battery", "wl-clock" }) |name| {
        const run_example = b.addSystemCommand(&.{ "zig", "build", "test" });
        run_example.setCwd(b.path("examples/" ++ name));
        examples_step.dependOn(&run_example.step);
    }

    const test_step = b.step(
        "test",
        "Run all unit tests: wmaker-wl and wlprefs",
    );

    test_step.dependOn(&run_tests.step);
    test_step.dependOn(wlprefs_test_step);

    const test_all_step = b.step(
        "test-all",
        "Run `test` and the tests of the examples",
    );

    test_all_step.dependOn(test_step);
    test_all_step.dependOn(examples_step);
}

/// Build a compositor executable and link its required system libraries.
fn addCompositor(
    b: *std.Build,
    imports: []const std.Build.Module.Import,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    use_llvm: bool,
    name: []const u8,
    root: []const u8,
) *std.Build.Step.Compile {
    const module = b.createModule(.{
        .root_source_file = b.path(root),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = imports,
    });

    module.linkSystemLibrary(
        "wayland-server",
        .{ .use_pkg_config = .force },
    );

    module.linkSystemLibrary(
        "xkbcommon",
        .{ .use_pkg_config = .force },
    );

    module.linkSystemLibrary(
        "pixman-1",
        .{ .use_pkg_config = .force },
    );

    linkCairo(b, module);

    module.linkSystemLibrary(
        "wlroots-0.20",
        .{ .use_pkg_config = .force },
    );

    // wm_pixbuf.c defines WLR_USE_UNSTABLE itself; don't define it twice.
    module.addCSourceFile(.{
        .file = b.path("src/wm_pixbuf.c"),
        .flags = &.{},
    });

    return b.addExecutable(.{
        .name = name,
        .root_module = module,
        .use_llvm = use_llvm,
        .use_lld = use_llvm,
    });
}

