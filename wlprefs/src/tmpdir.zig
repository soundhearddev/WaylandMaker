// SPDX-License-Identifier: GPL-3.0
//
// Private scratch directories for tests. A fixed `/tmp/<name>-XXXXXX`
// template is shared with every other user of the machine and ignores
// `$TMPDIR`; this looks at `$XDG_RUNTIME_DIR` (private to the user) first,
// then `$TMPDIR`, then `/tmp`. `mkdtemp` makes the directory mode 0700.

const std = @import("std");

const c = @cImport({
    @cInclude("stdlib.h");
});

pub const buf_len = 256;

/// Create a fresh directory named `<base>/<prefix>-XXXXXX` and return its
/// path (a slice of `buf`). The caller removes it.
pub fn make(buf: *[buf_len]u8, prefix: []const u8) error{MkdTemp}![:0]u8 {
    const names = [_][:0]const u8{ "XDG_RUNTIME_DIR", "TMPDIR" };
    for (names) |name| {
        const base = c.getenv(name.ptr) orelse continue;
        if (tryBase(buf, std.mem.span(base), prefix)) |dir| return dir;
    }
    if (tryBase(buf, "/tmp", prefix)) |dir| return dir;
    return error.MkdTemp;
}

fn tryBase(buf: *[buf_len]u8, base: []const u8, prefix: []const u8) ?[:0]u8 {
    // A relative base would depend on the working directory of the test.
    if (base.len == 0 or base[0] != '/') return null;
    const tmpl = std.fmt.bufPrintZ(buf, "{s}/{s}-XXXXXX", .{ std.mem.trimEnd(u8, base, "/"), prefix }) catch return null;
    if (c.mkdtemp(tmpl.ptr) == null) return null;
    return tmpl;
}

test "make: a private directory that exists, named after the prefix" {
    var buf: [buf_len]u8 = undefined;
    const dir = try make(&buf, "wmaker-tmpdir-test");
    defer _ = std.c.rmdir(dir.ptr);
    try std.testing.expect(std.mem.indexOf(u8, dir, "/wmaker-tmpdir-test-") != null);
    try std.testing.expect(!std.mem.endsWith(u8, dir, "XXXXXX"));
    try std.testing.expect(std.c.access(dir.ptr, 0) == 0);
}

test "make: two calls give two different directories" {
    var a: [buf_len]u8 = undefined;
    var b: [buf_len]u8 = undefined;
    const d1 = try make(&a, "wmaker-tmpdir-test");
    defer _ = std.c.rmdir(d1.ptr);
    const d2 = try make(&b, "wmaker-tmpdir-test");
    defer _ = std.c.rmdir(d2.ptr);
    try std.testing.expect(!std.mem.eql(u8, d1, d2));
}

test "tryBase: a relative or empty base is refused" {
    var buf: [buf_len]u8 = undefined;
    try std.testing.expect(tryBase(&buf, "", "x") == null);
    try std.testing.expect(tryBase(&buf, "relative/dir", "x") == null);
}
