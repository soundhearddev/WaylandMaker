// SPDX-License-Identifier: 0BSD
//
// Old-style (NeXTSTEP / GNUstep) property lists: the file format of every
// Window Maker configuration file (WindowMaker, WMRootMenu, WMWindowAttributes,
// WMState) and of wlmaker's themes.
//
//     {                                   dictionary   key = value;
//       Name = "Default Theme";
//       Sizes = (1, 2, 3);                array        ( a, b, c )
//       Blob = <deadbeef>;                data         <hex>
//     }
//
// Written from the format description, not derived from any GPL code.
//
// Accepted beyond the strict format (all of it appears in wlmaker files):
//   * `// line` and `/* block */` comments between tokens,
//   * a trailing comma in arrays and a missing `;` after the last dictionary
//     entry,
//   * a wider set of characters in unquoted strings.
//
// Everything is allocated in the arena the caller passes in; there is
// nothing to free individually.

const std = @import("std");

pub const Entry = struct {
    key: []const u8,
    value: Value,
};

pub const Value = union(enum) {
    string: []const u8,
    data: []const u8,
    array: []const Value,
    dict: []const Entry,

    /// Dictionary lookup. Case-sensitive, first match wins.
    pub fn get(v: Value, key: []const u8) ?Value {
        const list = switch (v) {
            .dict => |d| d,
            else => return null,
        };
        for (list) |e| {
            if (std.mem.eql(u8, e.key, key)) return e.value;
        }
        return null;
    }

    pub fn str(v: Value) ?[]const u8 {
        return switch (v) {
            .string => |s| s,
            else => null,
        };
    }

    pub fn items(v: Value) ?[]const Value {
        return switch (v) {
            .array => |a| a,
            else => null,
        };
    }

    pub fn entries(v: Value) ?[]const Entry {
        return switch (v) {
            .dict => |d| d,
            else => null,
        };
    }

    /// Window Maker booleans: Yes/No, True/False, YES/NO, 1/0 (any case).
    pub fn boolean(v: Value) ?bool {
        const s = v.str() orelse return null;
        inline for (.{ "yes", "true", "1", "on" }) |t| if (std.ascii.eqlIgnoreCase(s, t)) return true;
        inline for (.{ "no", "false", "0", "off" }) |t| if (std.ascii.eqlIgnoreCase(s, t)) return false;
        return null;
    }

    /// Integers in C notation (`%i`): decimal, 0x hex, 0 octal.
    pub fn int(v: Value) ?i64 {
        const s = v.str() orelse return null;
        return std.fmt.parseInt(i64, s, 0) catch null;
    }

    pub fn float(v: Value) ?f64 {
        const s = v.str() orelse return null;
        return std.fmt.parseFloat(f64, s) catch null;
    }
};

/// Where a parse failed. `line` is 1-based.
pub const Diag = struct {
    line: u32 = 0,
    message: []const u8 = "",

    pub fn format(d: Diag, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("line {d}: {s}", .{ d.line, d.message });
    }
};

pub const Error = error{ Syntax, OutOfMemory };

/// Parse one value; anything but whitespace and comments after it is an error.
pub fn parse(arena: std.mem.Allocator, text: []const u8, diag: ?*Diag) Error!Value {
    var p: Parser = .{ .a = arena, .text = text, .diag = diag };
    p.skip();
    const v = try p.value();
    p.skip();
    if (p.pos < p.text.len) return p.fail("unexpected text after the top-level value");
    return v;
}

const Parser = struct {
    a: std.mem.Allocator,
    text: []const u8,
    pos: usize = 0,
    line: u32 = 1,
    diag: ?*Diag,

    fn fail(p: *Parser, msg: []const u8) Error {
        if (p.diag) |d| d.* = .{ .line = p.line, .message = msg };
        return error.Syntax;
    }

    fn peek(p: *Parser) ?u8 {
        return if (p.pos < p.text.len) p.text[p.pos] else null;
    }

    fn advance(p: *Parser) void {
        if (p.text[p.pos] == '\n') p.line += 1;
        p.pos += 1;
    }

    /// Skip whitespace and comments. A `/` only starts a comment when it is
    /// followed by `/` or `*`, so unquoted paths such as /usr/bin/foot are
    /// untouched.
    fn skip(p: *Parser) void {
        while (p.peek()) |c| {
            if (std.ascii.isWhitespace(c)) {
                p.advance();
            } else if (c == '/' and p.pos + 1 < p.text.len and p.text[p.pos + 1] == '/') {
                while (p.peek()) |d| {
                    if (d == '\n') break;
                    p.advance();
                }
            } else if (c == '/' and p.pos + 1 < p.text.len and p.text[p.pos + 1] == '*') {
                p.advance();
                p.advance();
                while (p.pos < p.text.len) {
                    if (p.text[p.pos] == '*' and p.pos + 1 < p.text.len and p.text[p.pos + 1] == '/') {
                        p.advance();
                        p.advance();
                        break;
                    }
                    p.advance();
                }
            } else break;
        }
    }

    fn value(p: *Parser) Error!Value {
        const c = p.peek() orelse return p.fail("unexpected end of input, expected a value");
        return switch (c) {
            '{' => p.dict(),
            '(' => p.array(),
            '<' => p.data(),
            '"' => .{ .string = try p.quoted() },
            else => if (isBare(c))
                .{ .string = p.bare() }
            else
                p.fail("expected a string, array, dictionary or data; if this is a string, enclose it in quotes"),
        };
    }

    fn dict(p: *Parser) Error!Value {
        p.advance(); // {
        var list: std.ArrayList(Entry) = .empty;
        while (true) {
            p.skip();
            const c = p.peek() orelse return p.fail("unterminated dictionary, missing `}`");
            if (c == '}') {
                p.advance();
                break;
            }
            const key = if (c == '"')
                try p.quoted()
            else if (isBare(c))
                p.bare()
            else
                return p.fail("expected a dictionary key");
            p.skip();
            if (p.peek() != '=') return p.fail("expected `=` after the dictionary key");
            p.advance();
            p.skip();
            const v = try p.value();
            try list.append(p.a, .{ .key = key, .value = v });
            p.skip();
            switch (p.peek() orelse return p.fail("unterminated dictionary, missing `}`")) {
                ';' => p.advance(),
                '}' => {}, // the last `;` may be missing
                else => return p.fail("expected `;` after the dictionary value"),
            }
        }
        return .{ .dict = try list.toOwnedSlice(p.a) };
    }

    fn array(p: *Parser) Error!Value {
        p.advance(); // (
        var list: std.ArrayList(Value) = .empty;
        while (true) {
            p.skip();
            const c = p.peek() orelse return p.fail("unterminated array, missing `)`");
            if (c == ')') {
                p.advance();
                break;
            }
            try list.append(p.a, try p.value());
            p.skip();
            switch (p.peek() orelse return p.fail("unterminated array, missing `)`")) {
                ',' => p.advance(),
                ')' => {},
                else => return p.fail("expected `,` or `)` in the array"),
            }
        }
        return .{ .array = try list.toOwnedSlice(p.a) };
    }

    fn data(p: *Parser) Error!Value {
        p.advance(); // <
        var out: std.ArrayList(u8) = .empty;
        var high: ?u8 = null;
        while (true) {
            const c = p.peek() orelse return p.fail("unterminated data, missing `>`");
            p.advance();
            if (c == '>') break;
            if (std.ascii.isWhitespace(c)) continue;
            const nib = std.fmt.charToDigit(c, 16) catch return p.fail("invalid hex digit in data");
            if (high) |h| {
                try out.append(p.a, (h << 4) | nib);
                high = null;
            } else high = nib;
        }
        if (high != null) return p.fail("data has an odd number of hex digits");
        return .{ .data = try out.toOwnedSlice(p.a) };
    }

    fn quoted(p: *Parser) Error![]const u8 {
        p.advance(); // opening "
        var out: std.ArrayList(u8) = .empty;
        while (true) {
            const c = p.peek() orelse return p.fail("unterminated string, missing `\"`");
            p.advance();
            switch (c) {
                '"' => break,
                '\\' => {
                    const e = p.peek() orelse return p.fail("unterminated escape sequence");
                    p.advance();
                    switch (e) {
                        'n' => try out.append(p.a, '\n'),
                        't' => try out.append(p.a, '\t'),
                        'r' => try out.append(p.a, '\r'),
                        'a' => try out.append(p.a, 0x07),
                        'b' => try out.append(p.a, 0x08),
                        'f' => try out.append(p.a, 0x0c),
                        'v' => try out.append(p.a, 0x0b),
                        '0'...'7' => {
                            // up to three octal digits
                            var n: u32 = e - '0';
                            var digits: u8 = 1;
                            while (digits < 3) : (digits += 1) {
                                const d = p.peek() orelse break;
                                if (d < '0' or d > '7') break;
                                n = n * 8 + (d - '0');
                                p.advance();
                            }
                            try out.append(p.a, @truncate(n));
                        },
                        else => try out.append(p.a, e), // \" \\ and anything else
                    }
                },
                else => try out.append(p.a, c),
            }
        }
        return out.toOwnedSlice(p.a);
    }

    fn bare(p: *Parser) []const u8 {
        const start = p.pos;
        while (p.peek()) |c| {
            if (!isBare(c)) break;
            p.pos += 1;
        }
        return p.text[start..p.pos];
    }
};

/// Characters allowed in an unquoted string. Window Maker itself allows
/// letters, digits and `. _ / +`; the rest covers what real files use for
/// unquoted words (`-64`, `Foo-Bar`, `user@host`, `~/x`).
fn isBare(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or switch (c) {
        '.', '_', '/', '+', '-', '$', ':', '~', '*', '@', '%' => true,
        else => false,
    };
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

fn parseT(arena: std.mem.Allocator, text: []const u8) !Value {
    return parse(arena, text, null);
}

test "dictionary, array, strings" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const v = try parseT(arena.allocator(),
        \\{
        \\  Name = "Default Theme";
        \\  Count = 4;
        \\  List = (a, "b c", d);
        \\  Nested = { Yes = Yes; No = no };
        \\}
    );
    try std.testing.expectEqualStrings("Default Theme", v.get("Name").?.str().?);
    try std.testing.expectEqual(@as(i64, 4), v.get("Count").?.int().?);
    const list = v.get("List").?.items().?;
    try std.testing.expectEqual(@as(usize, 3), list.len);
    try std.testing.expectEqualStrings("b c", list[1].str().?);
    try std.testing.expectEqual(true, v.get("Nested").?.get("Yes").?.boolean().?);
    try std.testing.expectEqual(false, v.get("Nested").?.get("No").?.boolean().?);
    try std.testing.expect(v.get("Missing") == null);
}

test "comments, trailing comma, missing last semicolon" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const v = try parseT(arena.allocator(),
        \\// theme header
        \\{
        \\  /* block
        \\     comment */
        \\  A = (1, 2, );   // trailing comma
        \\  B = x
        \\}
    );
    try std.testing.expectEqual(@as(usize, 2), v.get("A").?.items().?.len);
    try std.testing.expectEqualStrings("x", v.get("B").?.str().?);
}

test "unquoted paths are not comments" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const v = try parseT(arena.allocator(), "(\"Terminal\", Execute, /usr/bin/foot)");
    const items = v.items().?;
    try std.testing.expectEqualStrings("/usr/bin/foot", items[2].str().?);
}

test "escapes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const v = try parseT(arena.allocator(), "\"a\\tb\\n\\\"q\\\"\\\\ \\101\"");
    try std.testing.expectEqualStrings("a\tb\n\"q\"\\ A", v.str().?);
}

test "data" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const v = try parseT(arena.allocator(), "<de ad BE ef>");
    try std.testing.expectEqualSlices(u8, &.{ 0xde, 0xad, 0xbe, 0xef }, v.data);
}

test "empty containers" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqual(@as(usize, 0), (try parseT(arena.allocator(), "()")).items().?.len);
    try std.testing.expectEqual(@as(usize, 0), (try parseT(arena.allocator(), "{}")).entries().?.len);
}

test "window maker dock state (own sample of the documented format)" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const v = try parseT(arena.allocator(),
        \\{
        \\  Dock = {
        \\    Applications = (
        \\      { Command = xterm; Name = xterm.XTerm; AutoLaunch = No; Position = "0,1"; }
        \\    );
        \\    Position = "-64,0";
        \\    Lowered = No;
        \\  };
        \\}
    );
    const apps = v.get("Dock").?.get("Applications").?.items().?;
    try std.testing.expectEqual(@as(usize, 1), apps.len);
    try std.testing.expectEqualStrings("xterm.XTerm", apps[0].get("Name").?.str().?);
    try std.testing.expectEqual(false, apps[0].get("AutoLaunch").?.boolean().?);
    try std.testing.expectEqualStrings("-64,0", v.get("Dock").?.get("Position").?.str().?);
}

test "errors carry the line number" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};

    try std.testing.expectError(error.Syntax, parse(arena.allocator(), "{\n  A = 1;\n  B 2;\n}", &diag));
    try std.testing.expectEqual(@as(u32, 3), diag.line);

    try std.testing.expectError(error.Syntax, parse(arena.allocator(), "(a, b", &diag));
    try std.testing.expectError(error.Syntax, parse(arena.allocator(), "\"open", &diag));
    try std.testing.expectError(error.Syntax, parse(arena.allocator(), "a b", &diag));
    try std.testing.expectError(error.Syntax, parse(arena.allocator(), "<abc>", &diag)); // odd digits
    try std.testing.expectError(error.Syntax, parse(arena.allocator(), "", &diag));
}

test "booleans and integers" {
    const yes: Value = .{ .string = "YES" };
    const zero: Value = .{ .string = "0" };
    const hex: Value = .{ .string = "0x10" };
    const junk: Value = .{ .string = "maybe" };
    try std.testing.expectEqual(true, yes.boolean().?);
    try std.testing.expectEqual(false, zero.boolean().?);
    try std.testing.expectEqual(@as(i64, 16), hex.int().?);
    try std.testing.expect(junk.boolean() == null);
    try std.testing.expect(junk.int() == null);
}
