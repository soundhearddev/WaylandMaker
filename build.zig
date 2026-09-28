const std = @import("std");
const Scanner = @import("wayland").Scanner;

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
pub fn buildWlprefs(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    use_llvm: bool,
) *std.Build.Step.Compile {

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

    // ---- helper: link graphics libs -------------------------------------

    const fn_link_graphics = struct {
        fn call(
            bld: *std.Build,
            module: *std.Build.Module,
        ) void {
            module.linkSystemLibrary("wayland-client", .{});
            module.linkSystemLibrary("xkbcommon", .{});
            module.linkSystemLibrary("cairo", .{});
            module.linkSystemLibrary("pango-1.0", .{});
            module.linkSystemLibrary("pangocairo-1.0", .{});
            module.linkSystemLibrary("gobject-2.0", .{});
            module.linkSystemLibrary("glib-2.0", .{});

            module.addIncludePath(
                projectPath(bld, "src"),
            );

            module.addIncludePath(.{
                .cwd_relative = "/usr/include/glib-2.0",
            });
            module.addIncludePath(.{
                .cwd_relative = "/usr/lib/glib-2.0/include",
            });
            module.addIncludePath(.{
                .cwd_relative = "/usr/include/cairo",
            });
            module.addIncludePath(.{
                .cwd_relative = "/usr/include/pango-1.0",
            });
            module.addIncludePath(.{
                .cwd_relative = "/usr/include/harfbuzz",
            });
        }
    }.call;

    // ---- library module -------------------------------------------------

    const mod = b.addModule("wlprefs", .{
        .root_source_file = projectPath(b, "src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    mod.addImport(
        "wayland",
        wayland_module,
    );

    mod.addImport(
        "xkbcommon",
        xkbcommon_module,
    );

    fn_link_graphics(b, mod);

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
            .{
                .name = "wlprefs",
                .module = mod,
            },
            .{
                .name = "wayland",
                .module = wayland_module,
            },
            .{
                .name = "xkbcommon",
                .module = xkbcommon_module,
            },
        },
    });

    fn_link_graphics(b, exe_module);

    const exe = b.addExecutable(.{
        .name = "wlprefs",
        .root_module = exe_module,
        .use_llvm = use_llvm,
        .use_lld = use_llvm,
    });

    return exe;
}

// -------------------------------------------------------------------------
// Standalone build
// -------------------------------------------------------------------------

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const use_llvm = b.option(
        bool,
        "llvm",
        "Use LLVM backend + lld linker",
    ) orelse true;

    const exe = buildWlprefs(
        b,
        target,
        optimize,
        use_llvm,
    );

    b.installArtifact(exe);

    // ---- run ------------------------------------------------------------

    const run_step = b.step(
        "run",
        "Run wlprefs",
    );

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    run_step.dependOn(&run_cmd.step);

    // ---- tests ----------------------------------------------------------

    const mod_tests = b.addTest(.{
        .root_module = exe.root_module,
        .use_llvm = use_llvm,
        .use_lld = use_llvm,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step(
        "test",
        "Run tests",
    );

    test_step.dependOn(&run_mod_tests.step);
}
