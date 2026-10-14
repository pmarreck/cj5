//! Zig bindings for cj5 JSON5 parser
//!
//! cj5 is a minimal JSON5 parser that supports:
//! - Unquoted object keys (ECMAScript 5.1 IdentifierName)
//! - Trailing commas in objects and arrays
//! - Single-quoted strings
//! - Multi-line strings (escaped newlines)
//! - Hexadecimal numbers
//! - Infinity, -Infinity, NaN
//! - Leading/trailing decimal points (.5, 5.)
//! - Single and multi-line comments
//!
//! See https://json5.org for the full specification.

const std = @import("std");
const c = @cImport({
    @cInclude("cj5.h");
});

pub const TokenType = enum(c_int) {
    object = c.CJ5_TOKEN_OBJECT,
    array = c.CJ5_TOKEN_ARRAY,
    number = c.CJ5_TOKEN_NUMBER,
    string = c.CJ5_TOKEN_STRING,
    bool_ = c.CJ5_TOKEN_BOOL,
    null_ = c.CJ5_TOKEN_NULL,
};

pub const NumberType = enum(c_int) {
    unknown = c.CJ5_TOKEN_NUMBER_UNKNOWN,
    float_ = c.CJ5_TOKEN_NUMBER_FLOAT,
    int_ = c.CJ5_TOKEN_NUMBER_INT,
    hex = c.CJ5_TOKEN_NUMBER_HEX,
};

pub const Error = error{
    Invalid, // invalid character/syntax
    Incomplete, // incomplete json string
    Overflow, // token buffer overflow, need more tokens
};

pub const Token = extern struct {
    type: TokenType,
    data: extern union {
        num_type: NumberType,
        key_hash: u32,
    },
    key_start: c_int,
    key_end: c_int,
    start: c_int,
    end: c_int,
    size: c_int,
    parent_id: c_int,

    /// Get the key name for this token (if it's an object member)
    pub fn getKey(self: *const Token, json: []const u8) ?[]const u8 {
        if (self.key_start < 0 or self.key_end < 0) return null;
        const start: usize = @intCast(self.key_start);
        const end: usize = @intCast(self.key_end);
        if (start >= json.len or end > json.len or start >= end) return null;
        return json[start..end];
    }

    /// Get the value string for this token
    pub fn getValue(self: *const Token, json: []const u8) ?[]const u8 {
        if (self.start < 0 or self.end < 0) return null;
        const start: usize = @intCast(self.start);
        const end: usize = @intCast(self.end);
        if (start >= json.len or end > json.len or start >= end) return null;
        return json[start..end];
    }
};

pub const Result = struct {
    json: []const u8,
    tokens: []Token,
    num_tokens: usize,
    error_line: c_int,
    error_col: c_int,

    /// Check if parsing was successful
    pub fn isOk(self: *const Result) bool {
        return self.num_tokens > 0;
    }

    /// Get the root token
    pub fn root(self: *const Result) ?*const Token {
        if (self.num_tokens == 0) return null;
        return &self.tokens[0];
    }

    /// Get a token by index
    pub fn getToken(self: *const Result, index: usize) ?*const Token {
        if (index >= self.num_tokens) return null;
        return &self.tokens[index];
    }
};

/// Parse a JSON5 string.
/// Returns an error if parsing fails, otherwise returns a Result with the parsed tokens.
/// The tokens slice must be large enough to hold all tokens; if not, returns error.Overflow.
pub fn parse(json: []const u8, tokens: []Token) Error!Result {
    // cj5_parse asserts max_tokens > 0; an empty buffer simply has no room.
    if (tokens.len == 0) return error.Overflow;
    const c_result = c.cj5_parse(
        json.ptr,
        @intCast(json.len),
        @ptrCast(tokens.ptr),
        @intCast(tokens.len),
    );

    return switch (c_result.@"error") {
        c.CJ5_ERROR_NONE => Result{
            .json = json,
            .tokens = tokens,
            .num_tokens = @intCast(c_result.num_tokens),
            .error_line = 0,
            .error_col = 0,
        },
        c.CJ5_ERROR_INVALID => error.Invalid,
        c.CJ5_ERROR_INCOMPLETE => error.Incomplete,
        c.CJ5_ERROR_OVERFLOW => error.Overflow,
        else => error.Invalid,
    };
}

/// Where and how an uncapped validation found the document invalid.
pub const Failure = struct {
    kind: enum { invalid, incomplete },
    /// Byte offset into the input where cj5 detected the error.
    offset: usize,
};

pub const Verdict = union(enum) {
    valid: struct { num_tokens: usize },
    invalid: Failure,
};

/// Reasons validateAll could not reach a verdict; callers report these as
/// limits of the check, never as valid or invalid.
pub const ValidateAllError = error{
    OutOfMemory,
    /// cj5 indexes input with a C int, so longer input cannot be examined.
    InputTooLarge,
};

/// Token store for cj5_parse_with_factory that grows through an allocator, so
/// validation has no fixed token cap; records allocation failure separately
/// from cj5's own overflow signal.
const GrowStore = struct {
    allocator: std.mem.Allocator,
    list: std.ArrayList(c.cj5_token) = .empty,
    out_of_memory: bool = false,

    fn create(user: ?*anyopaque) callconv(.c) [*c]c.cj5_token {
        const self: *GrowStore = @ptrCast(@alignCast(user.?));
        return self.list.addOne(self.allocator) catch {
            self.out_of_memory = true;
            return null;
        };
    }

    fn getAll(user: ?*anyopaque) callconv(.c) [*c]c.cj5_token {
        const self: *GrowStore = @ptrCast(@alignCast(user.?));
        return self.list.items.ptr;
    }
};

/// Parse the whole document with allocator-grown token storage and return the
/// raw C result with its token pointer cleared (the tokens are freed here).
fn parseUncapped(allocator: std.mem.Allocator, json: []const u8) ValidateAllError!c.cj5_result {
    if (json.len > std.math.maxInt(c_int)) return error.InputTooLarge;
    var store: GrowStore = .{ .allocator = allocator };
    defer store.list.deinit(allocator);
    var r = c.cj5_parse_with_factory(json.ptr, @intCast(json.len), .{
        .create_token = GrowStore.create,
        .get_all = GrowStore.getAll,
        .user_data = &store,
    });
    // The store refuses a token only when allocation fails, so cj5's overflow
    // signal here always means memory ran out.
    if (store.out_of_memory or r.@"error" == c.CJ5_ERROR_OVERFLOW) return error.OutOfMemory;
    r.tokens = null;
    return r;
}

/// Validate an entire JSON5 document with no token cap (memory grows with the
/// token count). Returns valid, or invalid with the byte offset of the first
/// error; errors mean no verdict was reached.
pub fn validateAll(allocator: std.mem.Allocator, json: []const u8) ValidateAllError!Verdict {
    const r = try parseUncapped(allocator, json);
    return switch (r.@"error") {
        c.CJ5_ERROR_NONE => .{ .valid = .{ .num_tokens = @intCast(r.num_tokens) } },
        c.CJ5_ERROR_INCOMPLETE => .{ .invalid = .{ .kind = .incomplete, .offset = @intCast(r.error_offset) } },
        else => .{ .invalid = .{ .kind = .invalid, .offset = @intCast(r.error_offset) } },
    };
}

/// Check whether a whole JSON5 document is valid, using the page allocator for
/// token storage. A bool cannot express "not checked", so out-of-memory and
/// oversized input return false; use validateAll to tell those apart.
pub fn isValid(json: []const u8) bool {
    const v = validateAll(std.heap.page_allocator, json) catch return false;
    return v == .valid;
}

/// Like isValid, with cj5's line/column report on failure. Out-of-memory and
/// oversized input report invalid with line and column 0; use validateAll to
/// tell those apart.
pub fn validate(json: []const u8) struct { valid: bool, error_line: c_int, error_col: c_int, num_tokens: c_int } {
    const r = parseUncapped(std.heap.page_allocator, json) catch
        return .{ .valid = false, .error_line = 0, .error_col = 0, .num_tokens = 0 };
    return .{
        .valid = r.@"error" == c.CJ5_ERROR_NONE,
        .error_line = r.error_line,
        .error_col = r.error_col,
        .num_tokens = r.num_tokens,
    };
}

// Re-export the raw C API for advanced use cases
pub const raw = c;

const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

/// Assert that token `index` is an object member whose key slice equals `key`.
/// In cj5's model the key is a string token (parented to the object) whose
/// `getKey`/`getValue` both return the key name; the value lives in the next token.
fn expectKey(result: *const Result, index: usize, key: []const u8) !void {
    const tok = result.getToken(index) orelse return error.MissingToken;
    try expectEqual(TokenType.string, tok.type);
    try expectEqualStrings(key, tok.getKey(result.json) orelse return error.MissingKeySlice);
}

test "parse simple object" {
    const json = "{\"foo\": 123}";
    var tokens: [16]Token = undefined;
    const result = try parse(json, &tokens);

    try expectEqual(@as(usize, 3), result.num_tokens); // object, key, number

    const obj = result.root().?;
    try expectEqual(TokenType.object, obj.type);
    try expectEqual(@as(c_int, 1), obj.size); // one member

    try expectKey(&result, 1, "foo");

    const val = result.getToken(2).?;
    try expectEqual(TokenType.number, val.type);
    try expectEqual(NumberType.int_, val.data.num_type);
    try expectEqualStrings("123", val.getValue(json).?);
}

test "parse json5 unquoted keys" {
    const json = "{foo: 123, bar: 'hello'}";
    var tokens: [16]Token = undefined;
    const result = try parse(json, &tokens);

    try expectEqual(@as(usize, 5), result.num_tokens);
    try expectEqual(TokenType.object, result.root().?.type);
    try expectEqual(@as(c_int, 2), result.root().?.size); // two members

    // foo: 123  — unquoted key parsed correctly
    try expectKey(&result, 1, "foo");
    try expectEqual(NumberType.int_, result.getToken(2).?.data.num_type);
    try expectEqualStrings("123", result.getToken(2).?.getValue(json).?);

    // bar: 'hello'  — unquoted key with single-quoted string value
    try expectKey(&result, 3, "bar");
    const hello = result.getToken(4).?;
    try expectEqual(TokenType.string, hello.type);
    try expectEqualStrings("hello", hello.getValue(json).?);
}

test "parse json5 trailing comma" {
    const json = "{\"foo\": 123,}";
    var tokens: [16]Token = undefined;
    const result = try parse(json, &tokens);

    // Trailing comma must not produce a phantom member/token.
    try expectEqual(@as(usize, 3), result.num_tokens);
    try expectEqual(@as(c_int, 1), result.root().?.size);
    try expectKey(&result, 1, "foo");
    try expectEqualStrings("123", result.getToken(2).?.getValue(json).?);
}

test "parse json5 comments" {
    const json =
        \\{
        \\  // single line comment
        \\  "foo": 123,
        \\  /* multi
        \\     line
        \\     comment */
        \\  "bar": 456
        \\}
    ;
    var tokens: [16]Token = undefined;
    const result = try parse(json, &tokens);

    // Comments are stripped: only the two real members remain.
    try expectEqual(@as(usize, 5), result.num_tokens);
    try expectEqual(@as(c_int, 2), result.root().?.size);
    try expectKey(&result, 1, "foo");
    try expectEqualStrings("123", result.getToken(2).?.getValue(json).?);
    try expectKey(&result, 3, "bar");
    try expectEqualStrings("456", result.getToken(4).?.getValue(json).?);
}

test "parse json5 hex numbers" {
    const json = "{hex: 0xFF, hex2: 0x1A}";
    var tokens: [16]Token = undefined;
    const result = try parse(json, &tokens);

    try expectEqual(@as(usize, 5), result.num_tokens);

    try expectKey(&result, 1, "hex");
    const v1 = result.getToken(2).?;
    try expectEqual(TokenType.number, v1.type);
    try expectEqual(NumberType.hex, v1.data.num_type); // classified as hex
    try expectEqualStrings("FF", v1.getValue(json).?); // 0x prefix stripped

    try expectKey(&result, 3, "hex2");
    const v2 = result.getToken(4).?;
    try expectEqual(NumberType.hex, v2.data.num_type);
    try expectEqualStrings("1A", v2.getValue(json).?);
}

test "parse array element types" {
    const json = "[1, 2.5, 0x10]";
    var tokens: [16]Token = undefined;
    const result = try parse(json, &tokens);

    try expectEqual(@as(usize, 4), result.num_tokens); // array + 3 numbers
    const arr = result.root().?;
    try expectEqual(TokenType.array, arr.type);
    try expectEqual(@as(c_int, 3), arr.size);

    try expectEqual(NumberType.int_, result.getToken(1).?.data.num_type);
    try expectEqualStrings("1", result.getToken(1).?.getValue(json).?);
    try expectEqual(NumberType.float_, result.getToken(2).?.data.num_type);
    try expectEqualStrings("2.5", result.getToken(2).?.getValue(json).?);
    try expectEqual(NumberType.hex, result.getToken(3).?.data.num_type);
    try expectEqualStrings("10", result.getToken(3).?.getValue(json).?);
}

test "isValid" {
    try std.testing.expect(isValid("{\"foo\": 123}"));
    try std.testing.expect(isValid("{foo: 123}")); // JSON5 unquoted key
    try std.testing.expect(isValid("{foo: 123,}")); // JSON5 trailing comma
    try std.testing.expect(!isValid("{\"foo\": 123")); // Incomplete
}

test "missing object value is invalid" {
    // `key:` with no value is not valid JSON5, whether it ends the object or is
    // followed by a comma. (Fixed in our cj5.h fork — upstream accepted these.)
    try std.testing.expect(!isValid("{foo: }")); // missing value before '}'
    try std.testing.expect(!isValid("{foo:}")); // same, no whitespace
    try std.testing.expect(!isValid("{a: , b: 1}")); // missing value before ','
    try std.testing.expect(!isValid("{a: 1, b: }")); // missing value, second member

    // Valid forms must still be accepted (guard against over-rejection):
    try std.testing.expect(isValid("{foo: 123}"));
    try std.testing.expect(isValid("{a: 1, b: 2}"));
    try std.testing.expect(isValid("{a: 1,}")); // object trailing comma
    try std.testing.expect(isValid("[1, 2,]")); // array trailing comma
    try std.testing.expect(isValid("{}")); // empty object
    try std.testing.expect(isValid("{a: {b: 1}}")); // nested object value
}

test "parse returns error.Overflow when token buffer is too small" {
    const json = "[1, 2, 3, 4, 5]"; // needs 6 tokens (array + 5 numbers)
    var tokens: [2]Token = undefined;
    try std.testing.expectError(error.Overflow, parse(json, &tokens));
}

test "isValid/validate check valid documents past the old 4096-token buffer" {
    // Build a flat array of 5000 numbers => 5001 tokens, which exceeds the
    // 4096-token stack buffer isValid()/validate() used before validateAll.
    // Layout: '[' + "1" + 4999*(",1") + ']' = 1 + 1 + 9998 + 1 = 10001 bytes.
    const big = try std.testing.allocator.alloc(u8, 10001);
    defer std.testing.allocator.free(big);
    var pos: usize = 0;
    big[pos] = '[';
    pos += 1;
    var i: usize = 0;
    while (i < 5000) : (i += 1) {
        if (i != 0) {
            big[pos] = ',';
            pos += 1;
        }
        big[pos] = '1';
        pos += 1;
    }
    big[pos] = ']';
    pos += 1;
    std.debug.assert(pos == big.len);

    // Sanity: with a 4096-token buffer this input genuinely overflows.
    var buf4096: [4096]Token = undefined;
    try std.testing.expectError(error.Overflow, parse(big, &buf4096));

    // The document is valid and is now checked in full, not assumed valid on
    // overflow; the invalid counterpart is the validateAll test further down.
    try std.testing.expect(isValid(big));
    try std.testing.expect(validate(big).valid);
}

test "whitespace between unquoted key and colon is valid (JSON5)" {
    // JSON5 (and JSON) allow arbitrary whitespace between a key and its ':'.
    try std.testing.expect(isValid("{a : 1}")); // space before colon
    try std.testing.expect(isValid("{a: 1, b : 2}")); // second member
    try std.testing.expect(isValid("{ foo : 'x' , bar : 2 }")); // spaces everywhere
    try std.testing.expect(isValid("{a\t: 1}")); // tab before colon
    try std.testing.expect(isValid("{a\n: 1}")); // newline before colon

    // The key must still parse to the correct slice, not just report "valid".
    const json = "{a : 1}";
    var tokens: [16]Token = undefined;
    const r = try parse(json, &tokens);
    try expectEqual(@as(usize, 3), r.num_tokens);
    try expectKey(&r, 1, "a");
    const v = r.getToken(2).?;
    try expectEqual(NumberType.int_, v.data.num_type);
    try expectEqualStrings("1", v.getValue(json).?);

    // Regression guard: a missing value with whitespace is still invalid.
    try std.testing.expect(!isValid("{a : }"));
}

test "parse with an empty token slice returns error.Overflow" {
    // Upstream cj5_parse asserts max_tokens > 0; the Zig wrapper must keep the
    // empty-buffer case a recoverable error rather than an assertion abort.
    var tokens: [0]Token = .{};
    try std.testing.expectError(error.Overflow, parse("{a: 1}", &tokens));
}

/// Growable token store for the raw cj5_parse_with_factory API. It reallocates
/// on every growth so any parser code holding a stale token pointer is caught.
const GrowingFactory = struct {
    list: std.ArrayList(c.cj5_token) = .empty,
    fn create(user: ?*anyopaque) callconv(.c) [*c]c.cj5_token {
        const self: *GrowingFactory = @ptrCast(@alignCast(user.?));
        const old = self.list.items;
        var fresh = std.testing.allocator.alloc(c.cj5_token, old.len + 1) catch return null;
        @memcpy(fresh[0..old.len], old);
        self.list.deinit(std.testing.allocator);
        self.list = .fromOwnedSlice(fresh);
        return &fresh[old.len];
    }
    fn getAll(user: ?*anyopaque) callconv(.c) [*c]c.cj5_token {
        const self: *GrowingFactory = @ptrCast(@alignCast(user.?));
        return self.list.items.ptr;
    }
};

test "factory parse agrees with fixed-buffer parse, including fork validity fixes" {
    // Differential check: the upstream token-factory path must produce the same
    // verdict and tokens as the fixed-buffer path for valid and invalid inputs.
    const cases = [_][]const u8{
        "{a : 1, b: [1, 2, {c: 'x'}], d: null}",
        "{a: 1, b : 2}",
        "{a: }",
        "{a: , b: 1}",
        "{a : }",
        "[1, 2,]",
        "{a: 1",
    };
    for (cases) |json| {
        var fixed: [64]c.cj5_token = undefined;
        const r1 = c.cj5_parse(json.ptr, @intCast(json.len), &fixed, fixed.len);

        var gf: GrowingFactory = .{};
        defer gf.list.deinit(std.testing.allocator);
        const factory: c.cj5_factory = .{
            .create_token = GrowingFactory.create,
            .get_all = GrowingFactory.getAll,
            .user_data = &gf,
        };
        const r2 = c.cj5_parse_with_factory(json.ptr, @intCast(json.len), factory);

        try expectEqual(r1.@"error", r2.@"error");
        try expectEqual(r1.num_tokens, r2.num_tokens);
        if (r1.@"error" == c.CJ5_ERROR_NONE) {
            const n: usize = @intCast(r1.num_tokens);
            for (fixed[0..n], gf.list.items[0..n]) |a, b| {
                // Both paths memset each token to zero, so whole-token bytes must match.
                try std.testing.expectEqualSlices(u8, std.mem.asBytes(&a), std.mem.asBytes(&b));
            }
        }
    }
}

/// Builds "[1,1,...,1<tail>]" with `count` ones, so the document needs more
/// tokens than any fixed buffer while `tail` places an error after them.
fn buildBigArray(allocator: std.mem.Allocator, count: usize, tail: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '[');
    for (0..count) |i| {
        if (i != 0) try out.append(allocator, ',');
        try out.append(allocator, '1');
    }
    try out.appendSlice(allocator, tail);
    try out.append(allocator, ']');
    return out.toOwnedSlice(allocator);
}

test "validateAll checks a document past the old 4096-token cap" {
    const big = try buildBigArray(std.testing.allocator, 5000, "");
    defer std.testing.allocator.free(big);
    const v = try validateAll(std.testing.allocator, big);
    try expectEqual(@as(usize, 5001), v.valid.num_tokens);
}

test "validateAll reports an error after token 4096 as invalid at its byte offset" {
    // Missing object value after 5000 array elements: the '}' is the error.
    const big = try buildBigArray(std.testing.allocator, 5000, ",{a: }");
    defer std.testing.allocator.free(big);
    const brace = std.mem.lastIndexOfScalar(u8, big, '}').?;
    const v = try validateAll(std.testing.allocator, big);
    try expectEqual(Failure{ .kind = .invalid, .offset = brace }, v.invalid);
    // The bool conveniences must never call this document valid.
    try std.testing.expect(!isValid(big));
    try std.testing.expect(!validate(big).valid);
}

test "validateAll reports small invalid and incomplete documents with offsets" {
    const missing = "{a: }";
    try expectEqual(Failure{ .kind = .invalid, .offset = 4 }, (try validateAll(std.testing.allocator, missing)).invalid);
    const open = "{a: 1";
    try expectEqual(Failure{ .kind = .incomplete, .offset = open.len }, (try validateAll(std.testing.allocator, open)).invalid);
    const ok = "{a: [1, 'x']}";
    // object, key "a", array, 1, 'x' (cj5 counts keys as tokens)
    try expectEqual(@as(usize, 5), (try validateAll(std.testing.allocator, ok)).valid.num_tokens);
}

test "validateAll surfaces allocation failure instead of a verdict" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, validateAll(failing.allocator(), "{a: 1}"));
}

test "validateAll rejects input longer than cj5's int length as InputTooLarge" {
    // Only the length is inspected; the bytes past the first are never read.
    const byte: u8 = '{';
    const p: [*]const u8 = @ptrCast(&byte);
    const huge = p[0 .. @as(usize, std.math.maxInt(c_int)) + 1];
    try std.testing.expectError(error.InputTooLarge, validateAll(std.testing.allocator, huge));
}
