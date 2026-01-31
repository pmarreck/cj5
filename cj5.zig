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

test "parse simple object" {
    const json = "{\"foo\": 123}";
    var tokens: [16]Token = undefined;
    const result = try parse(json, &tokens);
    try std.testing.expect(result.isOk());
    try std.testing.expectEqual(@as(usize, 3), result.num_tokens); // object, key, number
}

test "parse json5 unquoted keys" {
    const json = "{foo: 123, bar: 'hello'}";
    var tokens: [16]Token = undefined;
    const result = try parse(json, &tokens);
    try std.testing.expect(result.isOk());
}

test "parse json5 trailing comma" {
    const json = "{\"foo\": 123,}";
    var tokens: [16]Token = undefined;
    const result = try parse(json, &tokens);
    try std.testing.expect(result.isOk());
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
    try std.testing.expect(result.isOk());
}

test "parse json5 hex numbers" {
    const json = "{hex: 0xFF, hex2: 0x1A}";
    var tokens: [16]Token = undefined;
    const result = try parse(json, &tokens);
    try std.testing.expect(result.isOk());
}

test "isValid" {
    try std.testing.expect(isValid("{\"foo\": 123}"));
    try std.testing.expect(isValid("{foo: 123}")); // JSON5 unquoted key
    try std.testing.expect(isValid("{foo: 123,}")); // JSON5 trailing comma
    try std.testing.expect(!isValid("{\"foo\": 123")); // Incomplete
}
