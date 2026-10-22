// SPDX-License-Identifier: GPL-3.0
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
// where a literal is a number, true/false, a string ("..", '..', [[..]],
// [==[..]==]) or a table of those ({ 0.5, 1 }, { "Main", "Web" }). A line that
// is anything else -- an expression, a loop, two statements on one line -- is
// not ours and is left alone. So are the lines INSIDE a string or a comment
// that spans several lines: `Lexer` follows those from line to line, so that a
// `gap = 5` in the middle of a `[[ ... ]]` is text, not a setting.

const std = @import("std");

/// State carried from one line to the next: are we inside a long bracket
/// that spans lines -- a `--[[ ... ]]` comment or a `[[ ... ]]` string (any
/// level: `[==[ ... ]==]`)? Lines inside one are not code.
pub const Lexer = struct {
    in_block: bool = false,
    /// The level of that long bracket: the number of `=` in `[==[`.
    level: usize = 0,
};

const LongOpen = struct {
    /// The number of `=` between the brackets.
    level: usize,
    /// Bytes the opener takes (`[[` is 2, `[==[` is 4).
    len: usize,
};

/// A long bracket opens at `s[at]`: `[`, any number of `=`, `[`.
fn longOpen(s: []const u8, at: usize) ?LongOpen {
    if (at >= s.len or s[at] != '[') return null;
    var i = at + 1;
    while (i < s.len and s[i] == '=') i += 1;
    if (i < s.len and s[i] == '[') return .{ .level = i - at - 1, .len = i - at + 1 };
    return null;
}

/// Where the closer of a long bracket of `level` (`]`, `level` times `=`,
/// `]`) starts at or after `from`. It is `level + 2` bytes long.
fn longClose(s: []const u8, from: usize, level: usize) ?usize {
    var i = from;
    while (i < s.len) : (i += 1) {
        if (s[i] != ']') continue;
        var j = i + 1;
        while (j < s.len and s[j] == '=') j += 1;
        if (j - i - 1 == level and j < s.len and s[j] == ']') return i;
    }
    return null;
}

pub const Code = struct {
    /// The statement: no indentation, no comment, no trailing `;` or CR.
    body: []const u8,
    /// Where the comment starts in the raw line (raw.len if there is none).
    comment: usize,
};

/// The code of one line, or null for a blank line, a comment, a line that is
/// part of a block comment, or a line with more than one statement.
pub fn code(lex: *Lexer, raw: []const u8) ?Code {
    return codeImpl(lex, raw, true);
}

/// Like `code`, but a line with several statements gives its whole text
/// (`bind("a", "b"); bind("c", "d")`) instead of null. For counting what
/// wlprefs cannot read, not for editing.
pub fn codeAny(lex: *Lexer, raw: []const u8) ?Code {
    return codeImpl(lex, raw, false);
}

fn codeImpl(lex: *Lexer, raw: []const u8, strict: bool) ?Code {
    // A UTF-8 byte order mark (some editors add one to the first line) is not
    // part of the code, but it stays part of the line.
    if (std.mem.startsWith(u8, raw, "\xEF\xBB\xBF")) {
        const c = codeImpl(lex, raw[3..], strict) orelse return null;
        return .{ .body = c.body, .comment = c.comment + 3 };
    }
    if (lex.in_block) {
        if (longClose(raw, 0, lex.level) != null) lex.in_block = false;
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
            '[' => if (longOpen(raw, i)) |o| {
                // A long string: skip it. One that does not end on this
                // line is a multi-line string: the line is not ours, and
                // neither are the ones up to its end.
                const close = longClose(raw, i + o.len, o.level) orelse {
                    lex.in_block = true;
                    lex.level = o.level;
                    return null;
                };
                i = close + o.level + 1;
            },
            '-' => {
                if (i + 1 < raw.len and raw[i + 1] == '-') {
                    end = i;
                    // `--[[ ... ]]`: a comment that may go on over the next
                    // lines. Whatever follows its end on this line is code
                    // we do not try to read.
                    if (longOpen(raw, i + 2)) |o| {
                        if (longClose(raw, i + 2 + o.len, o.level)) |close| {
                            const rest = std.mem.trim(u8, raw[close + o.level + 2 ..], " \t\r");
                            if (rest.len > 0) return null;
                        } else {
                            lex.in_block = true;
                            lex.level = o.level;
                        }
                    }
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
        if (semicolons > 1 or !std.mem.endsWith(u8, body, ";")) {
            if (strict) return null;
        } else {
            body = std.mem.trimEnd(u8, body[0 .. body.len - 1], " \t");
        }
    }
    if (body.len == 0) return null;
    return .{ .body = body, .comment = end };
}

/// Does the code `body` call `name(...)` anywhere (outside strings)? A longer
/// identifier does not count: `mybind(` is not `bind(`.
pub fn callsFunction(body: []const u8, name: []const u8) bool {
    var i: usize = 0;
    var in_str: u8 = 0;
    while (i < body.len) {
        const ch = body[i];
        if (in_str != 0) {
            if (ch == '\\') {
                i += 2;
                continue;
            }
            if (ch == in_str) in_str = 0;
            i += 1;
            continue;
        }
        if (ch == '"' or ch == '\'') {
            in_str = ch;
            i += 1;
            continue;
        }
        if (std.ascii.isAlphabetic(ch) or ch == '_') {
            const start = i;
            while (i < body.len and (std.ascii.isAlphanumeric(body[i]) or body[i] == '_')) i += 1;
            // After a `.` or `:` it is a field or method (`wm.bind(`), not the function.
            const field = start > 0 and (body[start - 1] == '.' or body[start - 1] == ':');
            if (!field and std.mem.eql(u8, body[start..i], name)) {
                const rest = std.mem.trimStart(u8, body[i..], " \t");
                if (rest.len > 0 and rest[0] == '(') return true;
            }
            continue;
        }
        i += 1;
    }
    return false;
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
    if (longOpen(s, 0)) |o| {
        const close = longClose(s, o.len, o.level) orelse return null;
        return close + o.level + 2;
    }
    return null;
}

/// The text a string literal stands for (`"a\"b"` -> `a"b`). null if `lit`
/// is not exactly one string literal, or uses an escape that has no plain
/// text form here (\n, \x41, ...). Lives in `a`.
pub fn unquote(a: std.mem.Allocator, lit: []const u8) std.mem.Allocator.Error!?[]u8 {
    const len = literalLen(lit) orelse return null;
    if (len != lit.len) return null;

    if (longOpen(lit, 0)) |o| return try a.dupe(u8, lit[o.len .. lit.len - o.level - 2]);

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
    try testing.expectEqualStrings("gap = 8", code(&lex, "\xEF\xBB\xBFgap = 8").?.body);
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

test "code: a multi-line string hides the lines inside it, of any level" {
    var lex: Lexer = .{};
    try testing.expect(code(&lex, "x = [[") == null);
    try testing.expect(lex.in_block);
    try testing.expect(code(&lex, "gap = 99") == null); // text, not a setting
    try testing.expect(code(&lex, "]]") == null);
    try testing.expect(!lex.in_block);
    try testing.expect(code(&lex, "gap = 8") != null);

    // Level 2: a `]]` inside does not end it.
    try testing.expect(code(&lex, "--[==[ a ]] still a comment") == null);
    try testing.expect(lex.in_block);
    try testing.expect(code(&lex, "gap = 99 ]==]") == null);
    try testing.expect(!lex.in_block);

    // Code in front of a block comment that starts in the middle of a line counts.
    const c = code(&lex, "gap = 8 --[[ a note").?;
    try testing.expectEqualStrings("gap = 8", c.body);
    try testing.expect(lex.in_block);
    try testing.expect(code(&lex, "still the note ]]") == null);
    try testing.expect(!lex.in_block);

    // Code after a comment that closes on the same line is not ours.
    try testing.expect(code(&lex, "--[[ x ]] gap = 8") == null);
    try testing.expect(!lex.in_block);

    // A string of level 1 is one literal, with its text.
    try testing.expectEqual(@as(?usize, 10), literalLen("[=[a]]b]=] x"));
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("a]]b", (try unquote(arena.allocator(), "[=[a]]b]=]")).?);
    try testing.expect(literalLen("[=[never closed]]") == null);
}

test "codeAny and callsFunction" {
    var lex: Lexer = .{};
    try testing.expect(code(&lex, "bind(\"a\", \"b\"); bind(\"c\", \"d\")") == null);
    const c = codeAny(&lex, "bind(\"a\", \"b\"); bind(\"c\", \"d\")  -- two").?;
    try testing.expect(callsFunction(c.body, "bind"));
    try testing.expectEqualStrings("gap = 8", codeAny(&lex, "gap = 8;").?.body);
    try testing.expect(callsFunction("for i = 1, 4 do bind(\"x\" .. i, \"y\") end", "bind"));
    try testing.expect(callsFunction("bind (\"a\", f())", "bind"));
    try testing.expect(!callsFunction("mybind(\"a\")", "bind"));
    try testing.expect(!callsFunction("terminal = \"x bind(y)\"", "bind"));
    try testing.expect(!callsFunction("wm.bind(\"a\")", "bind"));
    try testing.expect(!callsFunction("local bind = 3", "bind"));
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
