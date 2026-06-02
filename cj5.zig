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

/// Check if a JSON5 string is valid (syntactically correct).
/// This is a convenience function that allocates temporary tokens on the stack.
/// For large documents, use parse() with a pre-allocated token buffer.
pub fn isValid(json: []const u8) bool {
    // Use a reasonable stack buffer for tokens
    var tokens: [4096]Token = undefined;

    const c_result = c.cj5_parse(
        json.ptr,
        @intCast(json.len),
        @ptrCast(&tokens),
        tokens.len,
    );

    // If we overflow, the JSON might still be valid, just larger than our buffer
    // In that case, we can't determine validity with this simple check
    if (c_result.@"error" == c.CJ5_ERROR_OVERFLOW) {
        // For very large files, we'd need dynamic allocation
        // For now, return true since the syntax was valid up to overflow
        return true;
    }

    return c_result.@"error" == c.CJ5_ERROR_NONE;
}

/// Check if JSON5 is valid, with detailed error info on failure.
pub fn validate(json: []const u8) struct { valid: bool, error_line: c_int, error_col: c_int, num_tokens: c_int } {
    var tokens: [4096]Token = undefined;

    const c_result = c.cj5_parse(
        json.ptr,
        @intCast(json.len),
        @ptrCast(&tokens),
        tokens.len,
    );

    return .{
        .valid = c_result.@"error" == c.CJ5_ERROR_NONE or c_result.@"error" == c.CJ5_ERROR_OVERFLOW,
        .error_line = c_result.error_line,
        .error_col = c_result.error_col,
        .num_tokens = c_result.num_tokens,
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

test "isValid/validate are lenient on token overflow (pins current behavior)" {
    // Build a flat array of 5000 numbers => 5001 tokens, which exceeds the
    // internal 4096-token stack buffer used by isValid()/validate().
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

    // Current (lenient) contract: syntactically-valid input that overflows the
    // internal buffer is reported as VALID by both isValid() and validate()
    // (see the comments in those functions). This test pins that behavior so a
    // future policy change — treating overflow as invalid — must update it
    // deliberately rather than silently.
    try std.testing.expect(isValid(big));
    try std.testing.expect(validate(big).valid);
}
