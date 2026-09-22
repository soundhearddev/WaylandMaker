// SPDX-License-Identifier: 0BSD
//
// UI Client: wl_compositor, wl_shm, and event dispatch via poll().
// Handles off-screen surfaces for menu rendering, separate from river windows.

const std = @import("std");
const wayland = @import("wayland");
const wl = wayland.client.wl;
const gfx = @import("gfx.zig");

pub const UiClient = struct {
    compositor: ?*wl.Compositor = null,
    shm: ?*wl.Shm = null,
    shm_pool: ?*wl.ShmPool = null,
    shm_fd: ?std.posix.fd_t = null,
    shm_data: ?[]align(std.heap.page_size_min) u8 = null,
    shm_size: u32 = 0,

    alloc: std.mem.Allocator,
    poll_fds: std.ArrayListUnmanaged(std.posix.pollfd) = .empty,
    display_fd: std.posix.fd_t = -1,

    pub fn create(alloc: std.mem.Allocator) UiClient {
        return .{
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *UiClient) void {
        if (self.shm_data) |data| {
            std.posix.munmap(data);
        }
        if (self.shm_pool) |pool| pool.destroy();
        if (self.shm) |shm| shm.destroy();
        if (self.shm_fd) |fd| {
            _ = std.posix.system.close(fd);
        }
        self.poll_fds.deinit(self.alloc);
    }

    pub fn bindCompositor(self: *UiClient, compositor: *wl.Compositor) void {
        self.compositor = compositor;
    }

    pub fn bindShm(self: *UiClient, shm: *wl.Shm) !void {
        self.shm = shm;

        // Create a 4MB shm buffer for rendering surfaces.
        const shm_size: u32 = 4 * 1024 * 1024;
        const fd = try allocShm(shm_size);
        errdefer _ = std.posix.system.close(fd);

        const data = try std.posix.mmap(
            null,
            shm_size,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED },
            fd,
            0,
        );
        errdefer std.posix.munmap(data);

        self.shm_fd = fd;
        self.shm_data = data;
        self.shm_size = shm_size;

        self.shm_pool = try shm.createPool(fd, @intCast(shm_size));
    }

    pub fn setDisplayFd(self: *UiClient, fd: std.posix.fd_t) !void {
        self.display_fd = fd;
        try self.poll_fds.append(self.alloc, .{
            .fd = fd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        });
    }

    pub fn pollOnce(self: *UiClient, timeout_ms: i32) !usize {
        if (self.poll_fds.items.len == 0) return 0;
        return std.posix.poll(self.poll_fds.items, timeout_ms);
    }

    pub fn createSurface(self: *UiClient) !?*wl.Surface {
        if (self.compositor) |comp| {
            return comp.createSurface();
        }
        return null;
    }

    pub fn allocateShmBuffer(
        self: *UiClient,
        width: i32,
        height: i32,
    ) !?*wl.Buffer {
        if (self.shm_pool == null or self.shm_data == null) return null;

        const stride = width * 4;
        const size: u32 = @intCast(stride * height);
        if (size > self.shm_size) return error.BufferTooLarge;

        return self.shm_pool.?.createBuffer(0, width, height, stride, wl.Shm.Format.argb8888);
    }
};

fn allocShm(size: usize) !std.posix.fd_t {
    const flags = std.posix.MFD.CLOEXEC | std.posix.MFD.ALLOW_SEALING;
    const fd = try std.posix.memfd_create("wmaker-wl-shm", flags);
    errdefer _ = std.posix.system.close(fd);

    const res = std.posix.system.ftruncate(fd, @intCast(size));
    switch (std.posix.errno(res)) {
        .SUCCESS => {},
        else => |err| return std.posix.unexpectedErrno(err),
    }

    return fd;
}

test "ui_client basics" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var ui = UiClient.create(alloc);
    defer ui.deinit();

    try std.testing.expectEqual(@as(usize, 0), ui.poll_fds.items.len);
}

test "setDisplayFd registers the fd for polling" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var ui = UiClient.create(alloc);
    defer ui.deinit();

    const p = try std.posix.pipe();
    defer std.posix.close(p[0]);
    defer std.posix.close(p[1]);

    try ui.setDisplayFd(p[0]);
    try std.testing.expectEqual(@as(usize, 1), ui.poll_fds.items.len);
    try std.testing.expectEqual(p[0], ui.display_fd);

    // Writing to the pipe should make it immediately pollable.
    _ = try std.posix.write(p[1], "x");
    const ready = try ui.pollOnce(0);
    try std.testing.expectEqual(@as(usize, 1), ready);
}
