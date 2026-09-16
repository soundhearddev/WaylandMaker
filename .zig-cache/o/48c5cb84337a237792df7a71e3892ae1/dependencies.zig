pub const packages = struct {
    pub const @"wayland-0.7.0-dev-lQa1krn7AQCMUzT3J6gWyukl3L3kbMtCZy9djQemUYA-" = struct {
        pub const build_root = "/home/max/Dokumente/code/wmaker/Wayland/zig-pkg/wayland-0.7.0-dev-lQa1krn7AQCMUzT3J6gWyukl3L3kbMtCZy9djQemUYA-";
        pub const build_zig = @import("wayland-0.7.0-dev-lQa1krn7AQCMUzT3J6gWyukl3L3kbMtCZy9djQemUYA-");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
        };
    };
    pub const @"xkbcommon-0.5.0-dev-VDqIe0y2AgA1RzA2ICMdGhaAgSXdhtRTbYybQQu7WfOa" = struct {
        pub const build_root = "/home/max/Dokumente/code/wmaker/Wayland/zig-pkg/xkbcommon-0.5.0-dev-VDqIe0y2AgA1RzA2ICMdGhaAgSXdhtRTbYybQQu7WfOa";
        pub const build_zig = @import("xkbcommon-0.5.0-dev-VDqIe0y2AgA1RzA2ICMdGhaAgSXdhtRTbYybQQu7WfOa");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
        };
    };
};

pub const root_deps: []const struct { []const u8, []const u8 } = &.{
    .{ "wayland", "wayland-0.7.0-dev-lQa1krn7AQCMUzT3J6gWyukl3L3kbMtCZy9djQemUYA-" },
    .{ "xkbcommon", "xkbcommon-0.5.0-dev-VDqIe0y2AgA1RzA2ICMdGhaAgSXdhtRTbYybQQu7WfOa" },
};
