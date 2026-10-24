const std = @import("std");
const Scanner = @import("wayland").Scanner;

/// The system libraries every wmaker-wl / wlprefs module draws with, and the
/// include directories their headers (and wm_text.h) are found in.
fn linkGraphics(module: *std.Build.Module, src_dir: std.Build.LazyPath) void {
    const libs = [_][]const u8{
        "wayland-client",
        "xkbcommon",
        "cairo",
        "pango-1.0",
        "pangocairo-1.0",
        "gobject-2.0",
        "glib-2.0",
    };
    for (libs) |name| module.linkSystemLibrary(name, .{});

    module.addIncludePath(src_dir);

    // Fallback include paths for systems where pkg-config does not already
    // provide them (harmless where it does, e.g. on Guix).
    const includes = [_][]const u8{
        "/usr/include/glib-2.0",
        "/usr/lib/glib-2.0/include",
        "/usr/include/cairo",
        "/usr/include/pango-1.0",
        "/usr/include/harfbuzz",
    };
    for (includes) |path| module.addIncludePath(.{ .cwd_relative = path });
}

/// Build wlprefs as part of another Build.
///
/// `prefix` is empty when this build.zig is used standalone,
/// and "wlprefs" when it is imported by the root project.
///
/// This allows both:
///
///     cd wlprefs && zig build
///
/// and:
///
///     cd .. && zig build
///
/// to build the same project.
pub const Wlprefs = struct {
    exe: *std.Build.Step.Compile,
    /// The library module (everything but main.zig); its tests are the
    /// `test-wlprefs` step.
    mod: *std.Build.Module,
    /// settings.zig on its own (no Wayland, no cairo). The compositor's own
    /// tests import it, to check that what wlprefs writes is what
    /// config.zig reads.
    settings: *std.Build.Module,
    /// actions.zig on its own: the compositor's tests check it against
    /// types.Command.
    actions: *std.Build.Module,
};

pub fn buildWlprefs(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    use_llvm: bool,
) Wlprefs {

    // Helper for paths belonging to this subproject.
    const projectPath = struct {
        fn get(
            bld: *std.Build,
            comptime p: []const u8,
        ) std.Build.LazyPath {
            return bld.path(
                bld.fmt("wlprefs/{s}", .{p}),
            );
        }
    }.get;

    // ---- protocol bindings ----------------------------------------------

    const scanner = Scanner.create(b, .{});

    scanner.addSystemProtocol(
        "stable/xdg-shell/xdg-shell.xml",
    );

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

    // wmaker-wl's own default config. wlprefs takes its defaults from it,
    // so "differs from the default" means the same in both programs.
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
// wmaker-wl (root project) -- also builds wlprefs via buildWlprefs() above
// -------------------------------------------------------------------------

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const use_llvm = b.option(
        bool,
        "llvm",
        "Use LLVM backend + lld linker",
    ) orelse true;

    // ---- protocol bindings ----------------------------------------------

    const scanner = Scanner.create(b, .{});

    scanner.addCustomProtocol(b.path("protocol/river-window-management-v1.xml"));
    scanner.addCustomProtocol(b.path("protocol/river-xkb-bindings-v1.xml"));
    scanner.addCustomProtocol(b.path("protocol/river-layer-shell-v1.xml"));

    scanner.addSystemProtocol("staging/cursor-shape/cursor-shape-v1.xml");

    // wp_cursor_shape_manager_v1.get_tablet_tool_v2 references
    // zwp_tablet_tool_v2; the scanner needs its definition even though
    // we only use get_pointer.
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

    // ---- Lua (ziglua 0.7.0, Zig 0.16) -----------------------------------
    //
    // Lua 5.4 is compiled from source and linked in statically: no system
    // Lua needed. The config (src/config.zig) is a Lua script, src/lua.zig
    // is the thin layer on top of the `zlua` module.

    const zlua_dep = b.dependency("zlua", .{
        .target = target,
        .optimize = optimize,
        .lang = .lua54,
    });
    const zlua_module = zlua_dep.module("zlua");

    // ---- backend handles (river) ----------------------------------------
    //
    // types.zig & co. get their compositor handle types from the module
    // `backend`. For this build it is src/backend_river.zig; the wlroots
    // build uses src_wlr/backend_wlr.zig (see wlr-model-check below).

    const backend_module = b.createModule(.{
        .root_source_file = b.path("src/backend_river.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "wayland", .module = wayland_module },
        },
    });

    // ---- wmaker-wl root module ------------------------------------------

    const root_module = b.addModule("wmaker", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    root_module.addImport("wayland", wayland_module);
    root_module.addImport("xkbcommon", xkbcommon_module);
    root_module.addImport("zlua", zlua_module);
    root_module.addImport("backend", backend_module);

    linkGraphics(root_module, b.path("src"));

    root_module.addCSourceFile(.{
        .file = b.path("src/wm_text.c"),
        .flags = &.{},
    });

    // ---- imports available to the wmaker-wl executable and its tests ----
    //
    // zlua must be listed here too: main.zig (and anything it imports by
    // file path, such as src/lua.zig) is compiled as its own module and
    // only sees the imports declared for it.
    //
    // NOTE: a source file may belong to only ONE module. If src/lua.zig is
    // imported both from main.zig and from root.zig, Zig reports "file
    // exists in multiple modules". In that case import it only via
    // root.zig and use it from main.zig through @import("wmaker").

    const imports: []const std.Build.Module.Import = &.{
        .{ .name = "wmaker", .module = root_module },
        .{ .name = "wayland", .module = wayland_module },
        .{ .name = "xkbcommon", .module = xkbcommon_module },
        .{ .name = "zlua", .module = zlua_module },
        .{ .name = "backend", .module = backend_module },
    };

    // ---- wmaker-wl executable -------------------------------------------

    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = imports,
    });

    linkGraphics(exe_module, b.path("src"));

    const exe = b.addExecutable(.{
        .name = "wmaker-wl",
        .root_module = exe_module,
        .use_llvm = use_llvm,
        .use_lld = use_llvm,
    });

    b.installArtifact(exe);

    // ---- wlprefs --------------------------------------------------------

    const wlprefs = buildWlprefs(
        b,
        target,
        optimize,
        use_llvm,
    );

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

    // ---- wlroots backend (src_wlr) ----------------------------------------
    //
    // wmaker-wl as its own compositor (docs/TODO wlroots.md). Not part of the
    // default install while the river backend is the one in use:
    //
    //   zig build wlr               wmaker-wlr  -> zig-out/bin
    //   zig build wlr-probe         wlr-probe (can wlroots be used at all?)
    //   zig build wlr-model-check   model + keys + manage pass, no wlroots needed
    //   zig build run-wlr           run it (nested, if a session is already up)
    //
    // Needs wlroots 0.20 (pkg-config: wlroots-0.20).

    const wlr = wlrModules(b, target, optimize, xkbcommon_module, zlua_module);

    const wlr_exe = addWlrExecutable(b, wlr, target, optimize, use_llvm, "wmaker-wlr", "src_wlr/main.zig");
    const wlr_step = b.step("wlr", "Build the wlroots compositor (wmaker-wlr) into zig-out/bin");
    wlr_step.dependOn(&b.addInstallArtifact(wlr_exe, .{}).step);

    const wlr_probe = addWlrExecutable(b, wlr, target, optimize, use_llvm, "wlr-probe", "src_wlr/probe.zig");
    const wlr_probe_step = b.step("wlr-probe", "Build the wlroots probe into zig-out/bin");
    wlr_probe_step.dependOn(&b.addInstallArtifact(wlr_probe, .{}).step);

    const run_wlr = b.addRunArtifact(wlr_exe);
    if (b.args) |args| run_wlr.addArgs(args);
    const run_wlr_step = b.step("run-wlr", "Run wmaker-wlr (nested when WAYLAND_DISPLAY or DISPLAY is set)");
    run_wlr_step.dependOn(&run_wlr.step);

    // The model against the wlroots handles, and the parts of the backend
    // that need no compositor library. Runs anywhere.
    const wlr_check_step = b.step(
        "wlr-model-check",
        "Compile the data model with the wlroots backend (no river types) and run its tests",
    );
    wlr_check_step.dependOn(addWlrModelCheck(b, wlr, target, optimize, use_llvm));

    // ---- run ------------------------------------------------------------

    const run_cmd = b.addSystemCommand(&.{
        "river",
        "-c",
        "zig-out/bin/wmaker-wl",
    });

    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step(
        "run",
        "Run river with wmaker-wl as window manager",
    );

    run_step.dependOn(&run_cmd.step);

    // ---- tests ----------------------------------------------------------

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = imports,
    });

    linkGraphics(test_module, b.path("src"));
    test_module.addImport("wlprefs_settings", wlprefs.settings);
    test_module.addImport("wlprefs_actions", wlprefs.actions);

    const tests = b.addTest(.{
        .root_module = test_module,
        .use_llvm = use_llvm,
        .use_lld = use_llvm,
    });

    const run_tests = b.addRunArtifact(tests);

    // ---- benchmark -------------------------------------------------------
    const bench_module = b.createModule(.{
        .root_source_file = b.path("src/bench.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = imports,
    });
    linkGraphics(bench_module, b.path("src"));
    bench_module.addImport("wlprefs_settings", wlprefs.settings);
    bench_module.addImport("wlprefs_actions", wlprefs.actions);
    const bench_exe = b.addExecutable(.{
        .name = "wmaker-bench",
        .root_module = bench_module,
        .use_llvm = use_llvm,
        .use_lld = use_llvm,
    });
    const run_bench = b.addRunArtifact(bench_exe);
    if (b.args) |args| run_bench.addArgs(args);
    const bench_step = b.step("bench", "Time the window model on synthetic loads (use -Doptimize=ReleaseFast)");
    bench_step.dependOn(&run_bench.step);

    // ---- examples -------------------------------------------------------
    const examples_step = b.step(
        "test-examples",
        "Run the unit tests of the example DockApps (wl-battery, wl-clock)",
    );
    inline for (.{ "wl-battery", "wl-clock" }) |name| {
        const run_example = b.addSystemCommand(&.{ "zig", "build", "test" });
        run_example.setCwd(b.path("examples/" ++ name));
        examples_step.dependOn(&run_example.step);
    }

    // ---- test / test-all ------------------------------------------------

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

// ---- wlroots backend ---------------------------------------------------------
//
// One `wayland` module (one scanner) for everything the compositor is made of:
// the data model needs only its `wl.list` types, wlroots needs the server
// protocols (xdg-shell, ...), and the compositor both. A module can exist only
// once per compilation, so they must share it. It is separate from the river
// build's module, which carries the river client protocols.

const WlrModules = struct {
    wayland: *std.Build.Module,
    xkbcommon: *std.Build.Module,
    wlroots: *std.Build.Module,
    pixman: *std.Build.Module,
    /// src_wlr/backend_wlr.zig: the handle types the model is built with.
    backend: *std.Build.Module,
    /// src/model.zig: the data model, no river and no wlroots.
    model: *std.Build.Module,
};

fn wlrModules(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    xkbcommon: *std.Build.Module,
    zlua: *std.Build.Module,
) WlrModules {
    const scanner = Scanner.create(b, .{});
    scanner.addSystemProtocol("stable/xdg-shell/xdg-shell.xml");
    scanner.addSystemProtocol("stable/tablet/tablet-v2.xml");
    scanner.addSystemProtocol("staging/color-management/color-management-v1.xml");
    scanner.addSystemProtocol("staging/cursor-shape/cursor-shape-v1.xml");
    scanner.addSystemProtocol("unstable/xdg-decoration/xdg-decoration-unstable-v1.xml");
    scanner.addSystemProtocol("unstable/primary-selection/primary-selection-unstable-v1.xml");

    // These versions only control Zig code generation. Too old a version can
    // only make a compile fail, never a client misbehave.
    scanner.generate("wl_compositor", 6);
    scanner.generate("wl_subcompositor", 1);
    scanner.generate("wl_shm", 1);
    scanner.generate("wl_output", 4);
    scanner.generate("wl_seat", 7);
    scanner.generate("wl_data_device_manager", 3);
    scanner.generate("xdg_wm_base", 6);
    scanner.generate("zxdg_decoration_manager_v1", 1);
    scanner.generate("zwp_primary_selection_device_manager_v1", 1);
    scanner.generate("zwp_tablet_manager_v2", 1);
    scanner.generate("wp_color_manager_v1", b.option(
        u32,
        "color-manager-version",
        "wp_color_manager_v1 version to generate (2 needs wayland-protocols >= 1.44; default 2)",
    ) orelse 2);
    scanner.generate("wp_cursor_shape_manager_v1", 2);

    const wayland = b.createModule(.{
        .root_source_file = scanner.result,
        .target = target,
        .optimize = optimize,
    });

    const pixman = b.dependency("pixman", .{}).module("pixman");
    const wlroots = b.dependency("wlroots", .{}).module("wlroots");
    wlroots.addImport("wayland", wayland);
    wlroots.addImport("xkbcommon", xkbcommon);
    wlroots.addImport("pixman", pixman);

    // The dependency module is created without a target. Without this line
    // linkSystemLibrary panics ("requires the Module to be created with a
    // known 'target' field"), and @cImport would not see the include path
    // pkg-config reports for wlroots.
    wlroots.resolved_target = target;
    wlroots.linkSystemLibrary("wlroots-0.20", .{});

    const backend = b.createModule(.{
        .root_source_file = b.path("src_wlr/backend_wlr.zig"),
        .target = target,
        .optimize = optimize,
    });

    const model = b.createModule(.{
        .root_source_file = b.path("src/model.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "wayland", .module = wayland },
            .{ .name = "xkbcommon", .module = xkbcommon },
            .{ .name = "zlua", .module = zlua },
            .{ .name = "backend", .module = backend },
        },
    });
    // config.zig calls xkb_keysym_from_name / xkb_utf32_to_keysym.
    model.linkSystemLibrary("xkbcommon", .{});

    return .{
        .wayland = wayland,
        .xkbcommon = xkbcommon,
        .wlroots = wlroots,
        .pixman = pixman,
        .backend = backend,
        .model = model,
    };
}

fn addWlrExecutable(
    b: *std.Build,
    wlr: WlrModules,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    use_llvm: bool,
    name: []const u8,
    root: []const u8,
) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(root),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "model", .module = wlr.model },
                .{ .name = "backend", .module = wlr.backend },
                .{ .name = "wayland", .module = wlr.wayland },
                .{ .name = "xkbcommon", .module = wlr.xkbcommon },
                .{ .name = "wlroots", .module = wlr.wlroots },
            },
        }),
        .use_llvm = use_llvm,
        .use_lld = use_llvm,
    });
    exe.root_module.linkSystemLibrary("wayland-server", .{});
    exe.root_module.linkSystemLibrary("xkbcommon", .{});
    exe.root_module.linkSystemLibrary("pixman-1", .{});
    return exe;
}

// The tests of the backend's pure parts (key matching, manage pass) with the
// model they run on. Needs the scanner's `wl.list` types and libxkbcommon,
// but no wlroots and no display.

fn addWlrModelCheck(
    b: *std.Build,
    wlr: WlrModules,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    use_llvm: bool,
) *std.Build.Step {
    const check = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src_wlr/model_check.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "model", .module = wlr.model },
                .{ .name = "backend", .module = wlr.backend },
                .{ .name = "xkbcommon", .module = wlr.xkbcommon },
            },
        }),
        .use_llvm = use_llvm,
        .use_lld = use_llvm,
    });
    check.root_module.linkSystemLibrary("xkbcommon", .{});
    return &b.addRunArtifact(check).step;
}
