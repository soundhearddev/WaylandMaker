// SPDX-License-Identifier: 0BSD
//
// Reading a small file completely. Shared by the XPM icon loader, the icon
// theme lookup and OPEN_MENU's menu files.

const std = @import("std");

const c = @cImport({
    @cInclude("stdio.h");
});

/// No icon and no menu file is anywhere near this; a bigger file is not one.
pub const max_file: usize = 1 << 20;

/// Read `path` completely (at most `max_file` bytes). null if it is missing,
/// unreadable, or too big. Caller frees.
pub fn readSmallFile(gpa: std.mem.Allocator, path: [:0]const u8) ?[]u8 {
    const f = c.fopen(path.ptr, "rb") orelse return null;
    defer _ = c.fclose(f);

    var list: std.ArrayList(u8) = .empty;
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = c.fread(&buf, 1, buf.len, f);
        if (n > 0) {
            if (list.items.len + n > max_file) {
                list.deinit(gpa);
                return null;
            }
            list.appendSlice(gpa, buf[0..n]) catch {
                list.deinit(gpa);
                return null;
            };
        }
        if (n < buf.len) break;
    }
    if (c.ferror(f) != 0) {
        list.deinit(gpa);
        return null;
    }
    return list.toOwnedSlice(gpa) catch {
        list.deinit(gpa);
        return null;
    };
}

test "readSmallFile: missing file is null" {
    try std.testing.expect(readSmallFile(std.testing.allocator, "/nonexistent/wmaker-wl/x") == null);
}

test "readSmallFile reads a real file" {
    const a = std.testing.allocator;
    const text = readSmallFile(a, "/proc/self/comm") orelse return error.SkipZigTest;
    defer a.free(text);
    try std.testing.expect(text.len > 0);
}
