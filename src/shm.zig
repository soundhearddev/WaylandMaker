// SPDX-License-Identifier: 0BSD
//
// A single-buffer wl_shm pool: memfd + mmap.

const std = @import("std");
const wayland = @import("wayland");
const wl = wayland.client.wl;
const posix = std.posix;
const linux = std.os.linux;

pub const Buffer = struct {
    pool: *wl.ShmPool,
    buffer: *wl.Buffer,
    data: []align(std.heap.page_size_min) u8,
    width: i32,
    height: i32,
    stride: i32,

    pub fn create(shm: *wl.Shm, width: i32, height: i32) !Buffer {
        const stride = width * 4;
        const size: usize = @intCast(stride * height);

        const rc = linux.memfd_create("wmaker-wl-shm", linux.MFD.CLOEXEC);
        if (linux.errno(rc) != .SUCCESS) return error.MemfdCreate;
        const fd: posix.fd_t = @intCast(rc);
        defer _ = linux.close(fd);

        if (linux.errno(linux.ftruncate(fd, @intCast(size))) != .SUCCESS) return error.Truncate;

        const data = try posix.mmap(
            null,
            size,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED },
            fd,
            0,
        );
        errdefer posix.munmap(data);

        const pool = try shm.createPool(fd, @intCast(size));
        errdefer pool.destroy();
        const buffer = try pool.createBuffer(0, width, height, stride, .argb8888);

        return .{
            .pool = pool,
            .buffer = buffer,
            .data = data,
            .width = width,
            .height = height,
            .stride = stride,
        };
    }

    pub fn destroy(b: *Buffer) void {
        b.buffer.destroy();
        b.pool.destroy();
        posix.munmap(b.data);
    }
};
