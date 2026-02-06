const std = @import("std");

pub const TokenKind = enum {
    // Literals
    integer,
    float,
    string,
    string_part, // Part of an interpolated string before ${
    string_end, // Final part of an interpolated string
    path,
    uri,
    identifier,

    // Keywords
    kw_if,
    kw_then,
    kw_else,
    kw_assert,
    kw_with,
    kw_let,
    kw_in,
    kw_rec,
    kw_inherit,
    kw_or,

    // Operators and delimiters
    lparen, // (
    rparen, // )
    lbrace, // {
    rbrace, // }
    lbracket, // [
    rbracket, // ]
    semicolon, // ;
    colon, // :
    comma, // ,
    dot, // .
    ellipsis, // ...
    eq, // =
    eq_eq, // ==
    not_eq, // !=
    less, // <
    less_eq, // <=
    greater, // >
    greater_eq, // >=
    plus, // +
    minus, // -
    star, // *
    slash, // /
    concat, // ++
    and_and, // &&
    or_or, // ||
    not, // !
    question, // ?
    at, // @
    arrow, // ->
    update, // //
    dollar_brace, // ${

    // Special
    eof,
    invalid,
};

pub const TokenValue = union(enum) {
    none,
    integer: i64,
    float: f64,
    identifier: []const u8,
    string: []const u8,
    path: []const u8,
    uri: []const u8,
};

pub const Token = struct {
    kind: TokenKind,
    value: TokenValue,
    line: usize,
    column: usize,
    offset: usize,
};

pub const Lexer = struct {
    allocator: std.mem.Allocator,
    source: *std.Io.Reader,
    filename: []const u8,
    pos: usize,
    line: usize,
    column: usize,
    line_start: usize,
    // String interpolation state
    string_depth: usize, // > 0 when inside interpolated string
    brace_depth: usize, // Tracks nested braces inside ${}
    allocated_strings: std.ArrayList([]const u8), // Track allocated strings to free
    // Stack tracking whether each string_depth level is an indented string.
    // Index 0 is unused (depth 0 = not in a string). Index i corresponds to string_depth i.
    indented_string_stack: [max_string_depth]bool,

    const max_string_depth = 32;

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, source: *std.Io.Reader, filename: []const u8) Self {
        return Self{
            .allocator = allocator,
            .source = source,
            .filename = filename,
            .pos = 0,
            .line = 1,
            .column = 1,
            .line_start = 0,
            .string_depth = 0,
            .brace_depth = 0,
            .allocated_strings = .empty,
            .indented_string_stack = [_]bool{false} ** max_string_depth,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocated_strings.deinit(self.allocator);
    }

    fn isInIndentedString(self: *const Self) bool {
        if (self.string_depth == 0 or self.string_depth >= max_string_depth) return false;
        return self.indented_string_stack[self.string_depth];
    }

    fn setIndentedString(self: *Self, value: bool) void {
        if (self.string_depth > 0 and self.string_depth < max_string_depth) {
            self.indented_string_stack[self.string_depth] = value;
        }
    }

    // --- Streaming helpers ---

    fn peekSlice(self: *Self, n: usize) ![]u8 {
        self.source.fill(n) catch |err| switch (err) {
            error.EndOfStream => {},
            error.ReadFailed => return error.ReadFailed,
        };
        return self.source.buffered();
    }

    fn currentByte(self: *Self) !?u8 {
        const byte = self.source.peekByte() catch |err| switch (err) {
            error.EndOfStream => return null,
            else => |e| return e,
        };
        return byte;
    }

    fn peekAhead(self: *Self) !u8 {
        const buf = try self.peekSlice(2);
        if (buf.len < 2) return 0;
        return buf[1];
    }

    fn advance(self: *Self) void {
        self.source.toss(1);
        self.pos += 1;
        self.column += 1;
    }

    fn advanceLine(self: *Self) void {
        self.source.toss(1);
        self.pos += 1;
        self.line += 1;
        self.column = 1;
        self.line_start = self.pos;
    }

    fn makeToken(self: *Self, kind: TokenKind, line: usize, column: usize, start: usize) Token {
        _ = self;
        return Token{
            .kind = kind,
            .value = .none,
            .line = line,
            .column = column,
            .offset = start,
        };
    }

    pub fn nextToken(self: *Self) !Token {
        while (true) {
            const wc = try self.currentByte() orelse break;
            if (wc == ' ' or wc == '\t' or wc == '\r') {
                self.advance();
            } else if (wc == '\n') {
                self.advanceLine();
            } else if (wc == '#') {
                self.advance();
                while (true) {
                    const c = try self.currentByte() orelse break;
                    if (c == '\n') break;
                    self.advance();
                }
            } else if (wc == '/' and (try self.peekAhead()) == '*') {
                self.advance();
                self.advance();
                while (true) {
                    const c = try self.currentByte() orelse break;
                    if (c == '*' and (try self.peekAhead()) == '/') {
                        self.advance();
                        self.advance();
                        break;
                    }
                    if (c == '\n') {
                        self.advanceLine();
                    } else {
                        self.advance();
                    }
                }
            } else {
                break;
            }
        }

        const token_start = self.pos;
        const token_line = self.line;
        const token_column = self.column;

        const ch = try self.currentByte() orelse {
            return Token{ .kind = .eof, .value = .none, .line = token_line, .column = token_column, .offset = token_start };
        };

        if (self.string_depth > 0 and self.brace_depth > 0) {
            if (ch == '{') {
                self.brace_depth += 1;
                self.advance();
                return Token{ .kind = .lbrace, .value = .none, .line = token_line, .column = token_column, .offset = token_start };
            } else if (ch == '}') {
                self.brace_depth -= 1;
                if (self.brace_depth == 0) {
                    self.advance();
                    const result = if (self.isInIndentedString())
                        try self.lexIndentedStringContinue(token_line, token_column, token_start)
                    else
                        try self.lexStringContinue(token_line, token_column, token_start);
                    if (self.string_depth > 0) {
                        self.brace_depth = 1;
                    }
                    return result;
                } else {
                    self.advance();
                    return Token{ .kind = .rbrace, .value = .none, .line = token_line, .column = token_column, .offset = token_start };
                }
            }
        }

        if (ch == '"') return try self.lexString(token_line, token_column, token_start);

        if (ch == '\'') {
            if ((try self.peekAhead()) == '\'') {
                return try self.lexIndentedString(token_line, token_column, token_start);
            }
        }

        if (std.ascii.isDigit(ch)) return try self.lexNumber(token_line, token_column, token_start);
        if (std.ascii.isAlphabetic(ch) or ch == '_') return try self.lexIdentifier(token_line, token_column, token_start);
        if ((ch == '.' or ch == '/') and (try self.isPathStart())) return try self.lexPath(token_line, token_column, token_start);
        if (std.ascii.isAlphabetic(ch) and (try self.isUriStart())) return try self.lexUri(token_line, token_column, token_start);

        const next = try self.peekAhead();
        if (ch == '=' and next == '=') {
            self.advance();
            self.advance();
            return self.makeToken(.eq_eq, token_line, token_column, token_start);
        }
        if (ch == '!' and next == '=') {
            self.advance();
            self.advance();
            return self.makeToken(.not_eq, token_line, token_column, token_start);
        }
        if (ch == '<' and next == '=') {
            self.advance();
            self.advance();
            return self.makeToken(.less_eq, token_line, token_column, token_start);
        }
        if (ch == '>' and next == '=') {
            self.advance();
            self.advance();
            return self.makeToken(.greater_eq, token_line, token_column, token_start);
        }
        if (ch == '+' and next == '+') {
            self.advance();
            self.advance();
            return self.makeToken(.concat, token_line, token_column, token_start);
        }
        if (ch == '&' and next == '&') {
            self.advance();
            self.advance();
            return self.makeToken(.and_and, token_line, token_column, token_start);
        }
        if (ch == '|' and next == '|') {
            self.advance();
            self.advance();
            return self.makeToken(.or_or, token_line, token_column, token_start);
        }
        if (ch == '-' and next == '>') {
            self.advance();
            self.advance();
            return self.makeToken(.arrow, token_line, token_column, token_start);
        }
        if (ch == '/' and next == '/') {
            self.advance();
            self.advance();
            return self.makeToken(.update, token_line, token_column, token_start);
        }
        if (ch == '.' and next == '.') {
            const buf = try self.peekSlice(3);
            if (buf.len >= 3 and buf[2] == '.') {
                self.advance();
                self.advance();
                self.advance();
                return self.makeToken(.ellipsis, token_line, token_column, token_start);
            }
        }
        if (ch == '$' and next == '{') {
            self.advance();
            self.advance();
            if (self.string_depth > 0) self.brace_depth += 1;
            return self.makeToken(.dollar_brace, token_line, token_column, token_start);
        }

        self.advance();
        return self.makeToken(switch (ch) {
            '(' => .lparen,
            ')' => .rparen,
            '{' => .lbrace,
            '}' => .rbrace,
            '[' => .lbracket,
            ']' => .rbracket,
            ';' => .semicolon,
            ':' => .colon,
            ',' => .comma,
            '.' => .dot,
            '=' => .eq,
            '<' => .less,
            '>' => .greater,
            '+' => .plus,
            '-' => .minus,
            '*' => .star,
            '/' => .slash,
            '!' => .not,
            '?' => .question,
            '@' => .at,
            else => .invalid,
        }, token_line, token_column, token_start);
    }

    fn lexString(self: *Self, line: usize, column: usize, start: usize) !Token {
        var buffer: std.ArrayList(u8) = .empty;
        const initial_string_depth = self.string_depth;
        self.advance(); // Skip opening "

        while (true) {
            const ch = try self.currentByte() orelse return error.UnterminatedString;
            if (ch == '"') {
                self.advance();
                const str = buffer.items;
                try self.allocated_strings.append(self.allocator, str);
                const had_interpolation = self.string_depth > initial_string_depth;
                const kind: TokenKind = if (had_interpolation) .string_end else .string;
                if (had_interpolation) self.string_depth -= 1;
                return Token{ .kind = kind, .value = .{ .string = str }, .line = line, .column = column, .offset = start };
            }
            if (ch == '$' and (try self.peekAhead()) == '{') {
                self.string_depth += 1;
                self.brace_depth = 1;
                self.setIndentedString(false);
                self.advance();
                self.advance();
                const str = buffer.items;
                try self.allocated_strings.append(self.allocator, str);
                return Token{ .kind = .string_part, .value = .{ .string = str }, .line = line, .column = column, .offset = start };
            }
            if (ch == '\\') {
                self.advance();
                const escaped = try self.currentByte() orelse return error.UnterminatedString;
                self.advance();
                try buffer.append(self.allocator, switch (escaped) {
                    'n' => '\n',
                    'r' => '\r',
                    't' => '\t',
                    '\\' => '\\',
                    '"' => '"',
                    '$' => '$',
                    else => escaped,
                });
            } else {
                try buffer.append(self.allocator, ch);
                if (ch == '\n') self.advanceLine() else self.advance();
            }
        }
    }

    fn lexStringContinue(self: *Self, line: usize, column: usize, start: usize) !Token {
        var buffer: std.ArrayList(u8) = .empty;
        defer buffer.deinit(self.allocator);
        while (true) {
            const ch = try self.currentByte() orelse return error.UnterminatedString;
            if (ch == '"') {
                self.advance();
                const str = try buffer.toOwnedSlice(self.allocator);
                try self.allocated_strings.append(self.allocator, str);
                self.string_depth -= 1;
                return Token{ .kind = .string_end, .value = .{ .string = str }, .line = line, .column = column, .offset = start };
            }
            if (ch == '$' and (try self.peekAhead()) == '{') {
                self.brace_depth = 1;
                self.advance();
                self.advance();
                const str = try buffer.toOwnedSlice(self.allocator);
                try self.allocated_strings.append(self.allocator, str);
                return Token{ .kind = .string_part, .value = .{ .string = str }, .line = line, .column = column, .offset = start };
            }
            if (ch == '\\') {
                self.advance();
                const escaped = try self.currentByte() orelse return error.UnterminatedString;
                self.advance();
                try buffer.append(self.allocator, switch (escaped) {
                    'n' => '\n',
                    'r' => '\r',
                    't' => '\t',
                    '\\' => '\\',
                    '"' => '"',
                    '$' => '$',
                    else => escaped,
                });
            } else {
                try buffer.append(self.allocator, ch);
                if (ch == '\n') self.advanceLine() else self.advance();
            }
        }
    }

    fn lexIndentedString(self: *Self, line: usize, column: usize, start: usize) !Token {
        var buffer: std.ArrayList(u8) = .empty;
        defer buffer.deinit(self.allocator);
        const initial_string_depth = self.string_depth;
        self.advance();
        self.advance(); // Skip ''

        while (true) {
            const peeked = try self.peekSlice(3);
            if (peeked.len == 0) return error.UnterminatedString;

            if (peeked.len >= 2 and peeked[0] == '\'' and peeked[1] == '\'') {
                if (peeked.len >= 3 and peeked[2] == '$') {
                    self.advance();
                    self.advance();
                    self.advance();
                    try buffer.append(self.allocator, '$');
                    continue;
                }
                if (peeked.len >= 3 and peeked[2] == '\'') {
                    try buffer.append(self.allocator, '\'');
                    try buffer.append(self.allocator, '\'');
                    self.advance();
                    self.advance();
                    self.advance();
                    continue;
                }
                if (peeked.len >= 3 and peeked[2] == '\\') {
                    self.advance();
                    self.advance();
                    self.advance();
                    const esc = try self.currentByte() orelse return error.UnterminatedString;
                    switch (esc) {
                        'n' => try buffer.append(self.allocator, '\n'),
                        'r' => try buffer.append(self.allocator, '\r'),
                        't' => try buffer.append(self.allocator, '\t'),
                        else => {
                            try buffer.append(self.allocator, '\\');
                            try buffer.append(self.allocator, esc);
                        },
                    }
                    self.advance();
                    continue;
                }
                self.advance();
                self.advance();
                const str = try buffer.toOwnedSlice(self.allocator);
                try self.allocated_strings.append(self.allocator, str);
                const had_interpolation = self.string_depth > initial_string_depth;
                const kind: TokenKind = if (had_interpolation) .string_end else .string;
                if (had_interpolation) self.string_depth -= 1;
                return Token{ .kind = kind, .value = .{ .string = str }, .line = line, .column = column, .offset = start };
            }

            if (peeked.len >= 2 and peeked[0] == '$' and peeked[1] == '{') {
                self.string_depth += 1;
                self.brace_depth = 1;
                self.setIndentedString(true);
                self.advance();
                self.advance();
                const str = try buffer.toOwnedSlice(self.allocator);
                try self.allocated_strings.append(self.allocator, str);
                return Token{ .kind = .string_part, .value = .{ .string = str }, .line = line, .column = column, .offset = start };
            }

            const ch = peeked[0];
            try buffer.append(self.allocator, ch);
            if (ch == '\n') self.advanceLine() else self.advance();
        }
    }

    fn lexIndentedStringContinue(self: *Self, line: usize, column: usize, start: usize) !Token {
        var buffer: std.ArrayList(u8) = .empty;
        defer buffer.deinit(self.allocator);
        while (true) {
            const peeked = try self.peekSlice(3);
            if (peeked.len == 0) return error.UnterminatedString;

            if (peeked.len >= 2 and peeked[0] == '\'' and peeked[1] == '\'') {
                if (peeked.len >= 3 and peeked[2] == '$') {
                    self.advance();
                    self.advance();
                    self.advance();
                    try buffer.append(self.allocator, '$');
                    continue;
                }
                if (peeked.len >= 3 and peeked[2] == '\'') {
                    try buffer.append(self.allocator, '\'');
                    try buffer.append(self.allocator, '\'');
                    self.advance();
                    self.advance();
                    self.advance();
                    continue;
                }
                if (peeked.len >= 3 and peeked[2] == '\\') {
                    self.advance();
                    self.advance();
                    self.advance();
                    const esc = try self.currentByte() orelse return error.UnterminatedString;
                    switch (esc) {
                        'n' => try buffer.append(self.allocator, '\n'),
                        'r' => try buffer.append(self.allocator, '\r'),
                        't' => try buffer.append(self.allocator, '\t'),
                        else => {
                            try buffer.append(self.allocator, '\\');
                            try buffer.append(self.allocator, esc);
                        },
                    }
                    self.advance();
                    continue;
                }
                self.advance();
                self.advance();
                const str = try buffer.toOwnedSlice(self.allocator);
                try self.allocated_strings.append(self.allocator, str);
                self.string_depth -= 1;
                return Token{ .kind = .string_end, .value = .{ .string = str }, .line = line, .column = column, .offset = start };
            }

            if (peeked.len >= 2 and peeked[0] == '$' and peeked[1] == '{') {
                self.brace_depth = 1;
                self.advance();
                self.advance();
                const str = try buffer.toOwnedSlice(self.allocator);
                try self.allocated_strings.append(self.allocator, str);
                return Token{ .kind = .string_part, .value = .{ .string = str }, .line = line, .column = column, .offset = start };
            }

            const ch = peeked[0];
            try buffer.append(self.allocator, ch);
            if (ch == '\n') self.advanceLine() else self.advance();
        }
    }

    fn lexNumber(self: *Self, line: usize, column: usize, start: usize) !Token {
        var num_buf: std.ArrayList(u8) = .empty;
        defer num_buf.deinit(self.allocator);
        var is_float = false;

        while (true) {
            const ch = try self.currentByte() orelse break;
            if (std.ascii.isDigit(ch)) {
                try num_buf.append(self.allocator, ch);
                self.advance();
            } else if (ch == '.' and !is_float) {
                const nxt = try self.peekAhead();
                if (std.ascii.isDigit(nxt)) {
                    is_float = true;
                    try num_buf.append(self.allocator, ch);
                    self.advance();
                } else break;
            } else if ((ch == 'e' or ch == 'E') and !is_float) {
                is_float = true;
                try num_buf.append(self.allocator, ch);
                self.advance();
                const sign = try self.currentByte();
                if (sign != null and (sign.? == '+' or sign.? == '-')) {
                    try num_buf.append(self.allocator, sign.?);
                    self.advance();
                }
            } else break;
        }

        const text = num_buf.items;
        if (is_float) {
            const val = std.fmt.parseFloat(f64, text) catch 0.0;
            return Token{ .kind = .float, .value = .{ .float = val }, .line = line, .column = column, .offset = start };
        } else {
            const val = std.fmt.parseInt(i64, text, 10) catch 0;
            return Token{ .kind = .integer, .value = .{ .integer = val }, .line = line, .column = column, .offset = start };
        }
    }

    fn lexIdentifier(self: *Self, line: usize, column: usize, start: usize) !Token {
        var id_buf: std.ArrayList(u8) = .empty;
        // defer id_buf.deinit(self.allocator);

        while (true) {
            const ch = try self.currentByte() orelse break;
            if (std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-' or ch == '\'') {
                try id_buf.append(self.allocator, ch);
                self.advance();
            } else break;
        }

        const text = id_buf.items;
        const kind: TokenKind = if (std.mem.eql(u8, text, "if")) .kw_if else if (std.mem.eql(u8, text, "then")) .kw_then else if (std.mem.eql(u8, text, "else")) .kw_else else if (std.mem.eql(u8, text, "assert")) .kw_assert else if (std.mem.eql(u8, text, "with")) .kw_with else if (std.mem.eql(u8, text, "let")) .kw_let else if (std.mem.eql(u8, text, "in")) .kw_in else if (std.mem.eql(u8, text, "rec")) .kw_rec else if (std.mem.eql(u8, text, "inherit")) .kw_inherit else if (std.mem.eql(u8, text, "or")) .kw_or else .identifier;

        if (kind == .identifier) {
            try self.allocated_strings.append(self.allocator, id_buf.items);
            return Token{ .kind = .identifier, .value = .{ .identifier = id_buf.items }, .line = line, .column = column, .offset = start };
        }
        return Token{ .kind = kind, .value = .none, .line = line, .column = column, .offset = start };
    }

    fn lexPath(self: *Self, line: usize, column: usize, start: usize) !Token {
        var path_buf: std.ArrayList(u8) = .empty;
        defer path_buf.deinit(self.allocator);
        while (true) {
            const ch = try self.currentByte() orelse break;
            if (std.ascii.isAlphanumeric(ch) or ch == '/' or ch == '.' or ch == '_' or ch == '-' or ch == '+') {
                try path_buf.append(self.allocator, ch);
                self.advance();
            } else break;
        }
        const path = path_buf.items;
        try self.allocated_strings.append(self.allocator, path);
        return Token{ .kind = .path, .value = .{ .path = path }, .line = line, .column = column, .offset = start };
    }

    fn lexUri(self: *Self, line: usize, column: usize, start: usize) !Token {
        var uri_buf: std.ArrayList(u8) = .empty;
        defer uri_buf.deinit(self.allocator);
        while (true) {
            const ch = try self.currentByte() orelse break;
            if (std.ascii.isAlphanumeric(ch) or ch == '+' or ch == '-' or ch == '.') {
                try uri_buf.append(self.allocator, ch);
                self.advance();
            } else if (ch == ':') {
                try uri_buf.append(self.allocator, ch);
                self.advance();
                break;
            } else break;
        }
        while (true) {
            const ch = try self.currentByte() orelse break;
            if (std.ascii.isAlphanumeric(ch) or ch == '%' or ch == '/' or ch == '?' or
                ch == ':' or ch == '@' or ch == '&' or ch == '=' or ch == '+' or
                ch == '$' or ch == ',' or ch == '-' or ch == '_' or ch == '.' or
                ch == '!' or ch == '~' or ch == '*' or ch == '\'' or ch == '(' or ch == ')')
            {
                try uri_buf.append(self.allocator, ch);
                self.advance();
            } else break;
        }
        const uri = try uri_buf.toOwnedSlice(self.allocator);
        try self.allocated_strings.append(self.allocator, uri);
        return Token{ .kind = .uri, .value = .{ .uri = uri }, .line = line, .column = column, .offset = start };
    }

    fn isPathStart(self: *Self) !bool {
        const buf = try self.peekSlice(3);
        if (buf.len == 0) return false;
        const ch = buf[0];
        if (ch == '/' and buf.len >= 2) {
            const nxt = buf[1];
            return std.ascii.isAlphanumeric(nxt) or nxt == '_' or nxt == '-' or nxt == '.';
        }
        if (ch == '.' and buf.len >= 2) {
            const nxt = buf[1];
            if (nxt == '.' and buf.len >= 3 and buf[2] == '.') return false;
            return nxt == '/' or nxt == '.';
        }
        return false;
    }

    fn isUriStart(self: *Self) !bool {
        const buf = try self.peekSlice(23);
        if (buf.len == 0) return false;
        var i: usize = 0;
        while (i < buf.len) : (i += 1) {
            const ch = buf[i];
            if (ch == ':') return i > 0 and i + 2 < buf.len and buf[i + 1] == '/' and buf[i + 2] == '/';
            if (!std.ascii.isAlphanumeric(ch) and ch != '+' and ch != '-' and ch != '.') return false;
            if (i > 20) return false;
        }
        return false;
    }
};

// Tests
test "lexer basic tokens" {
    const allocator = std.testing.allocator;
    const source = "( ) { } [ ] ; : , . = + - * /";
    var reader = std.Io.Reader.fixed(source);
    var lex = Lexer.init(allocator, &reader, "test");
    defer lex.deinit();
    const expected = [_]TokenKind{
        .lparen,    .rparen, .lbrace, .rbrace, .lbracket, .rbracket,
        .semicolon, .colon,  .comma,  .dot,    .eq,       .plus,
        .minus,     .star,   .slash,
    };
    for (expected) |kind| {
        const token = try lex.nextToken();
        try std.testing.expectEqual(kind, token.kind);
    }
}

test "lexer numbers" {
    const allocator = std.testing.allocator;
    const source = "42 3.14 1e10";
    var reader = std.Io.Reader.fixed(source);
    var lex = Lexer.init(allocator, &reader, "test");
    defer lex.deinit();
    const tok1 = try lex.nextToken();
    try std.testing.expectEqual(TokenKind.integer, tok1.kind);
    try std.testing.expectEqual(@as(i64, 42), tok1.value.integer);
    const tok2 = try lex.nextToken();
    try std.testing.expectEqual(TokenKind.float, tok2.kind);
    const tok3 = try lex.nextToken();
    try std.testing.expectEqual(TokenKind.float, tok3.kind);
}

test "lexer keywords" {
    const allocator = std.testing.allocator;
    const source = "if then else let in rec";
    var reader = std.Io.Reader.fixed(source);
    var lex = Lexer.init(allocator, &reader, "test");
    defer lex.deinit();
    try std.testing.expectEqual(TokenKind.kw_if, (try lex.nextToken()).kind);
    try std.testing.expectEqual(TokenKind.kw_then, (try lex.nextToken()).kind);
    try std.testing.expectEqual(TokenKind.kw_else, (try lex.nextToken()).kind);
    try std.testing.expectEqual(TokenKind.kw_let, (try lex.nextToken()).kind);
    try std.testing.expectEqual(TokenKind.kw_in, (try lex.nextToken()).kind);
    try std.testing.expectEqual(TokenKind.kw_rec, (try lex.nextToken()).kind);
}
