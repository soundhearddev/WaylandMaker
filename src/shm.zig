// SPDX-License-Identifier: 0BSD
//
// A single-buffer wl_shm pool: memfd + mmap.

const std = @import("std");
const wayland = @import("wayland");
const wl = wayland.client.wl;
const posix = std.posix;
const linux = std.os.linux;

/// Largest buffer we agree to create (per side and in bytes). A menu or an
/// output that asks for more is a bug or an attack; refusing is safer than
/// mapping gigabytes.
pub const max_side: i32 = 16384;
pub const max_bytes: usize = 256 * 1024 * 1024;

pub const SizeError = error{ InvalidSize, TooLarge };

/// Validated `stride` and byte size for a `width` x `height` ARGB32 buffer.
/// Pure arithmetic, so it can be tested without a compositor.
pub fn checkedSize(width: i32, height: i32) SizeError!struct { stride: i32, size: usize } {
    if (width <= 0 or height <= 0) return error.InvalidSize;
    if (width > max_side or height > max_side) return error.TooLarge;
    // Both sides <= 16384: stride <= 65536 fits i32, and the product below
    // is computed in usize, so nothing overflows.
    const stride: i32 = width * 4;
    const size: usize = @as(usize, @intCast(stride)) * @as(usize, @intCast(height));
    if (size > max_bytes) return error.TooLarge;
    return .{ .stride = stride, .size = size };
}

pub const Buffer = struct {
    pool: *wl.ShmPool,
    buffer: *wl.Buffer,
    data: []align(std.heap.page_size_min) u8,
    width: i32,
    height: i32,
    stride: i32,

    pub fn create(shm: *wl.Shm, width: i32, height: i32) !Buffer {
        const dims = try checkedSize(width, height);
        const stride = dims.stride;
        const size = dims.size;

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
        errdefer buffer.destroy();

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

test "checkedSize accepts normal sizes" {
    const r = try checkedSize(1280, 720);
    try std.testing.expectEqual(@as(i32, 5120), r.stride);
    try std.testing.expectEqual(@as(usize, 5120 * 720), r.size);
}

test "checkedSize rejects zero, negative and overflowing sizes" {
    try std.testing.expectError(error.InvalidSize, checkedSize(0, 100));
    try std.testing.expectError(error.InvalidSize, checkedSize(100, 0));
    try std.testing.expectError(error.InvalidSize, checkedSize(-5, 100));
    try std.testing.expectError(error.InvalidSize, checkedSize(100, std.math.minInt(i32)));
    // width*4 would overflow i32 here; must be refused, not wrap.
    try std.testing.expectError(error.TooLarge, checkedSize(std.math.maxInt(i32), 1));
    try std.testing.expectError(error.TooLarge, checkedSize(1, std.math.maxInt(i32)));
    try std.testing.expectError(error.TooLarge, checkedSize(max_side + 1, 10));
}

test "checkedSize caps the total bytes" {
    // Each side is allowed, the product is not: 16384*16384*4 = 1 GiB.
    try std.testing.expectError(error.TooLarge, checkedSize(max_side, max_side));
    // Just under the cap works.
    _ = try checkedSize(8192, 8192); // 256 MiB exactly
}

test "Buffer.create actually refuses an oversized request, not just checkedSize in isolation" {
    // No wl_shm here (that needs a compositor); this only reaches the size
    // check, which must run before any fd/mmap/wayland call.
    const result = Buffer.create(undefined, max_side + 1, 10);
    try std.testing.expectError(error.TooLarge, result);
}
