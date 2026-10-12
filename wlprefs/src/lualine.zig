// SPDX-License-Identifier: 0BSD
//
// The little bit of Lua that wlprefs understands: ONE LINE of config.lua.
//
// wlprefs never runs the script (no Lua in the settings window): it edits
// the file line by line, so that comments, loops, helpers and everything it
// does not know stay exactly as the user wrote them. It recognises two
// shapes of line, which is all that the compositor's default config and
// wlprefs' own output consist of:
//
//     key = literal                  gap = 8        terminal = "foot"
//     name("string", "string")       bind("Super+q", "close")   theme("nord")
//
// where a literal is a number, true/false, a string ("..", '..', [[..]]) or
// a table of those ({ 0.5, 1 }, { "Main", "Web" }). A line that is anything
// else -- an expression, a loop, two statements on one line -- is not ours
// and is left alone.

const std = @import("std");

/// State carried from one line to the next: are we inside a `--[[ ... ]]`
/// block comment? Lines inside one are not code.
pub const Lexer = struct {
    in_block: bool = false,
};

pub const Code = struct {
    /// The statement: no indentation, no comment, no trailing `;` or CR.
    body: []const u8,
    /// Where the comment starts in the raw line (raw.len if there is none).
    comment: usize,
};

/// The code of one line, or null for a blank line, a comment, a line that is
/// part of a block comment, or a line with more than one statement.
pub fn code(lex: *Lexer, raw: []const u8) ?Code {
    if (lex.in_block) {
        if (std.mem.indexOf(u8, raw, "]]") != null) lex.in_block = false;
        return null;
    }
    const lead = std.mem.trimStart(u8, raw, " \t");
    if (std.mem.startsWith(u8, lead, "--[[")) {
        if (std.mem.indexOf(u8, lead[4..], "]]") == null) lex.in_block = true;
        return null;
    }

    var end = raw.len;
    var in_str: u8 = 0;
    var semicolons: usize = 0;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        const ch = raw[i];
        if (in_str != 0) {
            if (ch == '\\') {
                i += 1;
            } else if (ch == in_str) {
                in_str = 0;
            }
            continue;
        }
        switch (ch) {
            '"', '\'' => in_str = ch,
            '[' => {
                if (i + 1 < raw.len and raw[i + 1] == '[') {
                    // A long string: skip it. One that does not end on this
                    // line is a multi-line string, which is not ours.
                    const close = std.mem.indexOfPos(u8, raw, i + 2, "]]") orelse return null;
                    i = close + 1;
                }
            },
            '-' => {
                if (i + 1 < raw.len and raw[i + 1] == '-') {
                    end = i;
                    break;
                }
            },
            ';' => semicolons += 1,
            else => {},
        }
    }
    if (in_str != 0) return null; // a string that does not end: not ours

    var body = std.mem.trim(u8, raw[0..end], " \t\r");
    if (semicolons > 0) {
        // One `;` at the very end is only decoration; any other is a second
        // statement.
        if (semicolons > 1 or !std.mem.endsWith(u8, body, ";")) return null;
        body = std.mem.trimEnd(u8, body[0 .. body.len - 1], " \t");
    }
    if (body.len == 0) return null;
    return .{ .body = body, .comment = end };
}

pub fn isIdentifier(s: []const u8) bool {
    if (s.len == 0 or std.ascii.isDigit(s[0])) return false;
    for (s) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '_') return false;
    return true;
}

pub const Assign = struct { key: []const u8, value: []const u8 };

/// `key = value`. The value is the text of the literal, not interpreted.
pub fn assignment(body: []const u8) ?Assign {
    const eq = std.mem.indexOfScalar(u8, body, '=') orelse return null;
    if (eq + 1 < body.len and body[eq + 1] == '=') return null; // `==`
    const key = std.mem.trim(u8, body[0..eq], " \t");
    if (!isIdentifier(key)) return null;
    const value = std.mem.trim(u8, body[eq + 1 ..], " \t");
    if (value.len == 0) return null;
    return .{ .key = key, .value = value };
}

pub const Call = struct {
    name: []const u8,
    /// The string literals as written (quotes included): see `unquote`.
    args: [2][]const u8 = .{ "", "" },
    n: usize = 0,
};

/// `name("a")` or `name("a", "b")`: nothing but string literals as arguments.
pub fn call(body: []const u8) ?Call {
    const open = std.mem.indexOfScalar(u8, body, '(') orelse return null;
    const name = std.mem.trim(u8, body[0..open], " \t");
    if (!isIdentifier(name)) return null;
    if (body[body.len - 1] != ')') return null;

    var c: Call = .{ .name = name };
    var rest = std.mem.trim(u8, body[open + 1 .. body.len - 1], " \t");
    while (rest.len > 0) {
        if (c.n == c.args.len) return null;
        const len = literalLen(rest) orelse return null;
        c.args[c.n] = rest[0..len];
        c.n += 1;
        rest = std.mem.trimStart(u8, rest[len..], " \t");
        if (rest.len == 0) break;
        if (rest[0] != ',') return null;
        rest = std.mem.trimStart(u8, rest[1..], " \t");
        if (rest.len == 0) return null; // `f("a",)`
    }
    return c;
}

/// How many bytes the string literal at the start of `s` takes (null: `s`
/// does not start with a complete one).
pub fn literalLen(s: []const u8) ?usize {
    if (s.len < 2) return null;
    if (s[0] == '"' or s[0] == '\'') {
        var i: usize = 1;
        while (i < s.len) : (i += 1) {
            if (s[i] == '\\') {
                i += 1;
            } else if (s[i] == s[0]) return i + 1;
        }
        return null;
    }
    if (std.mem.startsWith(u8, s, "[[")) {
        const close = std.mem.indexOfPos(u8, s, 2, "]]") orelse return null;
        return close + 2;
    }
    return null;
}

/// The text a string literal stands for (`"a\"b"` -> `a"b`). null if `lit`
/// is not exactly one string literal, or uses an escape that has no plain
/// text form here (\n, \x41, ...). Lives in `a`.
pub fn unquote(a: std.mem.Allocator, lit: []const u8) std.mem.Allocator.Error!?[]u8 {
    const len = literalLen(lit) orelse return null;
    if (len != lit.len) return null;

    if (lit[0] == '[') return try a.dupe(u8, lit[2 .. lit.len - 2]);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var i: usize = 1;
    while (i < lit.len - 1) : (i += 1) {
        const ch = lit[i];
        if (ch != '\\') {
            try out.append(a, ch);
            continue;
        }
        i += 1;
        switch (lit[i]) {
            '\\', '"', '\'' => try out.append(a, lit[i]),
            else => {
                out.deinit(a);
                return null;
            },
        }
    }
    return try out.toOwnedSlice(a);
}

/// Append `text` as a double-quoted Lua string. Control characters have no
/// place in a config line and are dropped.
pub fn appendQuoted(out: *std.ArrayList(u8), a: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error!void {
    try out.append(a, '"');
    for (text) |ch| {
        if (ch < 0x20 or ch == 0x7f) continue;
        if (ch == '\\' or ch == '"') try out.append(a, '\\');
        try out.append(a, ch);
    }
    try out.append(a, '"');
}

/// `text` as a double-quoted Lua string, in `a`.
pub fn quote(a: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try appendQuoted(&out, a, text);
    return out.toOwnedSlice(a);
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

const testing = std.testing;

test "code: comments, strings that contain `--`, semicolons, block comments" {
    var lex: Lexer = .{};
    try testing.expect(code(&lex, "") == null);
    try testing.expect(code(&lex, "-- a comment") == null);
    try testing.expect(code(&lex, "   -- indented") == null);

    const a = code(&lex, "gap = 8      -- between windows").?;
    try testing.expectEqualStrings("gap = 8", a.body);
    try testing.expectEqualStrings("-- between windows", "gap = 8      -- between windows"[a.comment..]);

    // `--` inside a string is not a comment.
    const b = code(&lex, "terminal = \"foot --server\"  -- x").?;
    try testing.expectEqualStrings("terminal = \"foot --server\"", b.body);
    const c = code(&lex, "bind(\"Super+p\", [[grim -g \"$(slurp)\" -- x]])").?;
    try testing.expect(std.mem.endsWith(u8, c.body, "]])"));

    // A trailing `;` is decoration, two statements are not ours.
    try testing.expectEqualStrings("gap = 8", code(&lex, "gap = 8;").?.body);
    try testing.expect(code(&lex, "gap = 8; outer_gap = 8") == null);

    // Block comments hide the lines inside them.
    try testing.expect(code(&lex, "--[[ commented out") == null);
    try testing.expect(lex.in_block);
    try testing.expect(code(&lex, "gap = 99") == null);
    try testing.expect(code(&lex, "]]") == null);
    try testing.expect(!lex.in_block);
    try testing.expect(code(&lex, "gap = 8") != null);
    try testing.expect(code(&lex, "--[[ one line ]]") == null);
    try testing.expect(!lex.in_block);

    // A string that does not end is not ours.
    try testing.expect(code(&lex, "terminal = \"foot") == null);
}

test "assignment and call" {
    const a = assignment("gap = 8").?;
    try testing.expectEqualStrings("gap", a.key);
    try testing.expectEqualStrings("8", a.value);
    try testing.expect(assignment("gap == 8") == null);
    try testing.expect(assignment("local gap = 8") == null);
    try testing.expect(assignment("bind(\"a=b\", \"c\")") == null);
    try testing.expect(assignment("gap =") == null);

    const c = call("bind( \"Super+q\" , 'close' )").?;
    try testing.expectEqualStrings("bind", c.name);
    try testing.expectEqual(@as(usize, 2), c.n);
    try testing.expectEqualStrings("'close'", c.args[1]);
    try testing.expectEqual(@as(usize, 1), call("theme(\"nord\")").?.n);
    try testing.expectEqual(@as(usize, 0), call("f()").?.n);
    try testing.expect(call("f(1)") == null);
    try testing.expect(call("f(\"a\",)") == null);
    try testing.expect(call("f(\"a\" \"b\")") == null);
    try testing.expect(call("f(\"a\", \"b\", \"c\")") == null);
    try testing.expect(call("gap = 8") == null);
}

test "unquote and quote round-trip; escapes that have no plain text are refused" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqualStrings("foot -e \"htop\"", (try unquote(a, "\"foot -e \\\"htop\\\"\"")).?);
    try testing.expectEqualStrings("a\\b", (try unquote(a, "'a\\\\b'")).?);
    try testing.expectEqualStrings("shell echo \"$x\"", (try unquote(a, "[[shell echo \"$x\"]]")).?);
    try testing.expect((try unquote(a, "\"a\\nb\"")) == null);
    try testing.expect((try unquote(a, "\"a\" .. \"b\"")) == null);
    try testing.expect((try unquote(a, "8")) == null);

    const q = try quote(a, "say \"hi\" \\ there");
    try testing.expectEqualStrings("\"say \\\"hi\\\" \\\\ there\"", q);
    try testing.expectEqualStrings("say \"hi\" \\ there", (try unquote(a, q)).?);
    try testing.expectEqualStrings("\"ab\"", try quote(a, "a\nb"));
}
