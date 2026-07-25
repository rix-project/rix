const std = @import("std");
const lexer = @import("lexer.zig");
const ast = @import("ast.zig");

const Token = lexer.Token;
const TokenKind = lexer.TokenKind;
const Lexer = lexer.Lexer;
const Expr = ast.Expr;
const Span = ast.Span;

pub const Parser = struct {
    allocator: std.mem.Allocator,
    lexer: Lexer,
    current: Token,
    peek_token: Token,
    in_string_interpolation: bool,
    string_interpolation_depth: usize,
    interpolation_string_depth: usize, // Lexer's string_depth when current interpolation started

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, source: *std.Io.Reader, filename: []const u8) !Self {
        var lex = Lexer.init(allocator, source, filename);
        const current = try lex.nextToken();
        const peek = try lex.nextToken();

        return Self{
            .allocator = allocator,
            .lexer = lex,
            .current = current,
            .peek_token = peek,
            .in_string_interpolation = false,
            .string_interpolation_depth = 0,
            .interpolation_string_depth = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        self.lexer.deinit();
    }

    pub fn parseExpr(self: *Self) !Expr {
        return try self.parseExprBp(0);
    }

    // Pratt parser with binding powers
    fn parseExprBp(self: *Self, min_bp: u8) anyerror!Expr {
        var left = try self.parsePostfix(try self.parseSimple());

        while (true) {
            const op_info = self.getInfixOp() orelse break;
            if (op_info.left_bp < min_bp) break;

            self.advance();

            // Special case: has_attr (?) takes an attrpath on the right, not an expression
            if (op_info.op == .has_attr) {
                const attrpath = try self.parseAttrPath();
                const left_ptr = try self.allocator.create(Expr);
                left_ptr.* = left;
                // Encode the attrpath as a string (for simple single-part paths)
                const right_ptr = try self.allocator.create(Expr);
                if (attrpath.parts.len == 1) {
                    switch (attrpath.parts[0]) {
                        .ident => |id| right_ptr.* = Expr{ .string = id },
                        .string => |s| right_ptr.* = Expr{ .string = s },
                        .expr => |e| right_ptr.* = e.*,
                    }
                } else {
                    // Multi-part path — encode as string of first part for now
                    switch (attrpath.parts[0]) {
                        .ident => |id| right_ptr.* = Expr{ .string = id },
                        .string => |s| right_ptr.* = Expr{ .string = s },
                        .expr => |e| right_ptr.* = e.*,
                    }
                }

                left = Expr{
                    .binary_op = .{
                        .op = op_info.op,
                        .left = left_ptr,
                        .right = right_ptr,
                        .span = .{ .start = 0, .end = 0, .line = self.current.line, .column = self.current.column },
                    },
                };
                continue;
            }

            const right = try self.parseExprBp(op_info.right_bp);

            const left_ptr = try self.allocator.create(Expr);
            left_ptr.* = left;
            const right_ptr = try self.allocator.create(Expr);
            right_ptr.* = right;

            left = Expr{
                .binary_op = .{
                    .op = op_info.op,
                    .left = left_ptr,
                    .right = right_ptr,
                    .span = .{ .start = 0, .end = 0, .line = self.current.line, .column = self.current.column },
                },
            };
        }

        return left;
    }

    const InfixOp = struct {
        op: Expr.BinaryOperator,
        left_bp: u8,
        right_bp: u8,
    };

    fn getInfixOp(self: *Self) ?InfixOp {
        return switch (self.current.kind) {
            .or_or => InfixOp{ .op = .or_op, .left_bp = 1, .right_bp = 2 },
            .and_and => InfixOp{ .op = .and_op, .left_bp = 3, .right_bp = 4 },
            .eq_eq => InfixOp{ .op = .eq, .left_bp = 5, .right_bp = 6 },
            .not_eq => InfixOp{ .op = .neq, .left_bp = 5, .right_bp = 6 },
            .less => InfixOp{ .op = .lt, .left_bp = 5, .right_bp = 6 },
            .less_eq => InfixOp{ .op = .lte, .left_bp = 5, .right_bp = 6 },
            .greater => InfixOp{ .op = .gt, .left_bp = 5, .right_bp = 6 },
            .greater_eq => InfixOp{ .op = .gte, .left_bp = 5, .right_bp = 6 },
            .question => InfixOp{ .op = .has_attr, .left_bp = 6, .right_bp = 7 },
            .update => InfixOp{ .op = .update, .left_bp = 7, .right_bp = 8 },
            .plus => InfixOp{ .op = .add, .left_bp = 9, .right_bp = 10 },
            .minus => InfixOp{ .op = .sub, .left_bp = 9, .right_bp = 10 },
            .concat => InfixOp{ .op = .concat, .left_bp = 11, .right_bp = 12 },
            .star => InfixOp{ .op = .mul, .left_bp = 13, .right_bp = 14 },
            .slash => InfixOp{ .op = .div, .left_bp = 13, .right_bp = 14 },
            .arrow => InfixOp{ .op = .implies, .left_bp = 0, .right_bp = 1 },
            else => null,
        };
    }

    /// Parse a "simple" expression: an atom followed by any `.` attribute selects.
    /// This is used for function application arguments where `.` binds tighter
    /// than function application, so `f x.a` parses as `f (x.a)`.
    fn parseSimple(self: *Self) anyerror!Expr {
        var expr = try self.parsePrimary();
        while (self.current.kind == .dot) {
            expr = try self.parseSelect(expr);
        }
        return expr;
    }

    fn parsePrimary(self: *Self) anyerror!Expr {
        const start = self.current.offset;
        const line = self.current.line;
        const column = self.current.column;

        switch (self.current.kind) {
            .integer => {
                const val = self.current.value.integer;
                self.advance();
                return Expr{ .int = val };
            },
            .float => {
                const val = self.current.value.float;
                self.advance();
                return Expr{ .float = val };
            },
            .string => {
                const val = self.current.value.string;
                self.advance();
                return Expr{ .string = val };
            },
            .string_part => {
                // Start of an interpolated string
                return try self.parseInterpolatedString();
            },
            .path => {
                const val = self.current.value.path;
                self.advance();
                // Resolve relative paths (./foo, ../bar) relative to the source file
                if (std.mem.startsWith(u8, val, "./") or std.mem.startsWith(u8, val, "../")) {
                    const file_dir = std.fs.path.dirname(self.lexer.filename) orelse ".";
                    const resolved = std.fs.path.join(self.allocator, &.{ file_dir, val }) catch val;
                    return Expr{ .path = resolved };
                }
                return Expr{ .path = val };
            },
            .uri => {
                const val = self.current.value.uri;
                self.advance();
                return Expr{ .uri = val };
            },
            .identifier => {
                const name = self.current.value.identifier;
                self.advance();

                // Check for function patterns: `name: body` or `name@{ ... }: body`
                if (self.current.kind == .colon) {
                    // Simple function: `name: body`
                    self.advance();
                    const body = try self.parseExpr();
                    const body_ptr = try self.allocator.create(Expr);
                    body_ptr.* = body;
                    return Expr{
                        .lambda = .{
                            .param = .{ .ident = name },
                            .body = body_ptr,
                            .span = .{ .start = start, .end = self.current.offset, .line = line, .column = column },
                        },
                    };
                } else if (self.current.kind == .at) {
                    // Pattern with @ alias: `name@{ ... }: body`
                    self.advance();
                    try self.expect(.lbrace);
                    const pattern = try self.parsePattern(name);
                    try self.expect(.colon);
                    const body = try self.parseExpr();
                    const body_ptr = try self.allocator.create(Expr);
                    body_ptr.* = body;
                    return Expr{
                        .lambda = .{
                            .param = .{ .pattern = pattern },
                            .body = body_ptr,
                            .span = .{ .start = start, .end = self.current.offset, .line = line, .column = column },
                        },
                    };
                }

                return Expr{ .var_ref = name };
            },
            .lparen => {
                self.advance();
                const expr = try self.parseExpr();
                try self.expect(.rparen);
                return expr;
            },
            .lbracket => {
                return try self.parseList(start, line, column);
            },
            .lbrace => {
                // Disambiguate between attrs and function pattern
                return try self.parseAttrsOrPattern(start, line, column);
            },
            .kw_rec => {
                // Recursive attribute set: rec { ... }
                self.advance();
                const attrs = try self.parseRecAttrs(start, line, column);
                return attrs;
            },
            .kw_let => {
                return try self.parseLet(start, line, column);
            },
            .kw_if => {
                return try self.parseIf(start, line, column);
            },
            .kw_with => {
                return try self.parseWith(start, line, column);
            },
            .kw_assert => {
                return try self.parseAssert(start, line, column);
            },
            .not => {
                self.advance();
                const operand = try self.parseExprBp(20);
                const operand_ptr = try self.allocator.create(Expr);
                operand_ptr.* = operand;
                return Expr{
                    .unary_op = .{
                        .op = .not,
                        .operand = operand_ptr,
                        .span = .{ .start = start, .end = self.current.offset, .line = line, .column = column },
                    },
                };
            },
            .minus => {
                self.advance();
                const operand = try self.parseExprBp(20);
                const operand_ptr = try self.allocator.create(Expr);
                operand_ptr.* = operand;
                return Expr{
                    .unary_op = .{
                        .op = .negate,
                        .operand = operand_ptr,
                        .span = .{ .start = start, .end = self.current.offset, .line = line, .column = column },
                    },
                };
            },
            else => {
                std.debug.print("Unexpected token: {s} at line {}, column {} in {s}\n", .{
                    @tagName(self.current.kind),
                    self.current.line,
                    self.current.column,
                    self.lexer.filename,
                });
                return error.UnexpectedToken;
            },
        }
    }

    fn parsePostfix(self: *Self, base: Expr) !Expr {
        var expr = base;

        while (true) {
            switch (self.current.kind) {
                .dot => {
                    expr = try self.parseSelect(expr);
                },
                .lparen, .lbrace, .lbracket, .integer, .float, .string, .path, .identifier, .kw_rec => {
                    // Function application - use parseSimple for args so that
                    // `.` select binds tighter than application (f x.a = f (x.a))
                    // and application is left-associative (f x y = (f x) y)
                    const arg = try self.parseSimple();
                    const func_ptr = try self.allocator.create(Expr);
                    func_ptr.* = expr;
                    const arg_ptr = try self.allocator.create(Expr);
                    arg_ptr.* = arg;
                    expr = Expr{
                        .call = .{
                            .func = func_ptr,
                            .arg = arg_ptr,
                            .span = .{ .start = 0, .end = 0, .line = self.current.line, .column = self.current.column },
                        },
                    };
                },
                .string_part => {
                    // Only treat as function application if not inside string interpolation,
                    // OR if this is a NEW nested string (depth > our interpolation depth)
                    if (!self.in_string_interpolation or self.lexer.string_depth > self.interpolation_string_depth) {
                        const arg = try self.parseSimple();
                        const func_ptr = try self.allocator.create(Expr);
                        func_ptr.* = expr;
                        const arg_ptr = try self.allocator.create(Expr);
                        arg_ptr.* = arg;
                        expr = Expr{
                            .call = .{
                                .func = func_ptr,
                                .arg = arg_ptr,
                                .span = .{ .start = 0, .end = 0, .line = self.current.line, .column = self.current.column },
                            },
                        };
                    } else {
                        break;
                    }
                },
                else => break,
            }
        }

        return expr;
    }

    fn parseSelect(self: *Self, base: Expr) !Expr {
        try self.expect(.dot);

        var parts = std.ArrayList(Expr.AttrPathPart).empty;
        defer parts.deinit(self.allocator);

        while (true) {
            if (self.current.kind == .identifier) {
                try parts.append(self.allocator, .{ .ident = self.current.value.identifier });
                self.advance();
            } else if (self.current.kind == .string) {
                try parts.append(self.allocator, .{ .string = self.current.value.string });
                self.advance();
            } else if (self.current.kind == .string_part) {
                // Interpolated string as attribute name: ."${expr}"
                const interp = try self.parseInterpolatedString();
                const expr_ptr = try self.allocator.create(Expr);
                expr_ptr.* = interp;
                try parts.append(self.allocator, .{ .expr = expr_ptr });
            } else if (self.current.kind == .dollar_brace) {
                // Dynamic attribute: .${expr}
                self.advance();
                const expr = try self.parseExpr();
                try self.expect(.rbrace);
                const expr_ptr = try self.allocator.create(Expr);
                expr_ptr.* = expr;
                try parts.append(self.allocator, .{ .expr = expr_ptr });
            } else {
                return error.ExpectedIdentifier;
            }

            if (self.current.kind != .dot) break;
            self.advance();
        }

        var default_expr: ?*Expr = null;
        if (self.current.kind == .kw_or) {
            self.advance();
            const def = try self.parseExprBp(0);
            default_expr = try self.allocator.create(Expr);
            default_expr.?.* = def;
        }

        const base_ptr = try self.allocator.create(Expr);
        base_ptr.* = base;

        return Expr{
            .select = .{
                .base = base_ptr,
                .path = .{ .parts = try parts.toOwnedSlice(self.allocator) },
                .default = default_expr,
                .span = .{ .start = 0, .end = 0, .line = self.current.line, .column = self.current.column },
            },
        };
    }

    fn parseList(self: *Self, start: usize, line: usize, column: usize) !Expr {
        try self.expect(.lbracket);

        var elements = std.ArrayList(Expr).empty;

        while (self.current.kind != .rbracket and self.current.kind != .eof) {
            // List elements are "select" expressions (atoms + . selects), not full expressions.
            // So `[ f 1 2 ]` is three elements, not `[ (f 1 2) ]`.
            // Use parseSimple which handles atoms + dot selects but not function application.
            try elements.append(self.allocator, try self.parseSimple());
        }

        try self.expect(.rbracket);

        return Expr{
            .list = .{
                .elements = try elements.toOwnedSlice(self.allocator),
                .span = .{ .start = start, .end = self.current.offset, .line = line, .column = column },
            },
        };
    }

    /// Parse either an attribute set or a function pattern
    /// Disambiguates based on what follows the first identifier
    fn parseAttrsOrPattern(self: *Self, start: usize, line: usize, column: usize) !Expr {
        try self.expect(.lbrace);

        // Check if this is an empty set - could be `{ }` (attrset) or `{ }: body` (function pattern)
        if (self.current.kind == .rbrace) {
            self.advance();

            // Check for `@name` after empty pattern
            var at_name: ?[]const u8 = null;
            if (self.current.kind == .at) {
                self.advance();
                if (self.current.kind == .identifier) {
                    at_name = self.current.value.identifier;
                    self.advance();
                }
            }

            // If followed by `:`, it's a function with empty pattern
            if (self.current.kind == .colon) {
                self.advance();
                const body = try self.parseExpr();
                const body_ptr = try self.allocator.create(Expr);
                body_ptr.* = body;
                return Expr{
                    .lambda = .{
                        .param = .{
                            .pattern = .{
                                .formals = &[_]Expr.Formal{},
                                .ellipsis = false,
                                .at_name = at_name,
                            },
                        },
                        .body = body_ptr,
                        .span = .{ .start = start, .end = self.current.offset, .line = line, .column = column },
                    },
                };
            }

            // Otherwise it's an empty attrset
            return Expr{
                .attrs = .{
                    .bindings = &[_]Expr.Binding{},
                    .recursive = false,
                    .span = .{ .start = start, .end = self.current.offset, .line = line, .column = column },
                },
            };
        }

        // Check for `...}` pattern (ellipsis only)
        if (self.current.kind == .ellipsis) {
            self.advance();
            try self.expect(.rbrace);

            // Check for `@name` after the pattern
            var at_name: ?[]const u8 = null;
            if (self.current.kind == .at) {
                self.advance();
                if (self.current.kind == .identifier) {
                    at_name = self.current.value.identifier;
                    self.advance();
                }
            }

            // Must be followed by `:` for a function
            try self.expect(.colon);
            const body = try self.parseExpr();
            const body_ptr = try self.allocator.create(Expr);
            body_ptr.* = body;
            return Expr{
                .lambda = .{
                    .param = .{
                        .pattern = .{
                            .formals = &[_]Expr.Formal{},
                            .ellipsis = true,
                            .at_name = at_name,
                        },
                    },
                    .body = body_ptr,
                    .span = .{ .start = start, .end = self.current.offset, .line = line, .column = column },
                },
            };
        }

        // Need to look ahead to determine if this is a pattern or attrs
        // Patterns: `{ name, ... }` or `{ name ? default, ... }`
        // Attrs: `{ name = value; ... }`
        if (self.current.kind == .identifier) {
            const first_name = self.current.value.identifier;
            self.advance();

            if (self.current.kind == .comma or self.current.kind == .question or self.current.kind == .rbrace or self.current.kind == .ellipsis) {
                // This is a function pattern
                return self.finishPattern(start, line, column, first_name);
            } else if (self.current.kind == .eq or self.current.kind == .dot) {
                // This is an attribute set
                const attrs = try self.finishAttrs(start, line, column, first_name);
                return attrs;
            } else {
                std.debug.print("Expected ',' '?' '=' '.' or '}}' after identifier in braces, got {s} at line {}, column {}\n", .{
                    @tagName(self.current.kind),
                    self.current.line,
                    self.current.column,
                });
                return error.UnexpectedToken;
            }
        } else if (self.current.kind == .kw_or) {
            // 'or' used as attribute name
            self.advance();
            const attrs = try self.finishAttrs(start, line, column, "or");
            return attrs;
        } else if (self.current.kind == .string) {
            // Strings as keys means attribute set
            const first_name = self.current.value.string;
            self.advance();
            const attrs = try self.finishAttrs(start, line, column, first_name);
            return attrs;
        } else if (self.current.kind == .string_part) {
            // Interpolated strings as keys means attribute set
            const attrs = try self.finishAttrsNoFirst(start, line, column);
            return attrs;
        } else if (self.current.kind == .kw_inherit) {
            // inherit means attribute set
            const attrs = try self.finishAttrsNoFirst(start, line, column);
            return attrs;
        } else if (self.current.kind == .dollar_brace) {
            // ${expr} as key means attribute set with dynamic keys
            const attrs = try self.finishAttrsNoFirst(start, line, column);
            return attrs;
        }

        std.debug.print("Expected identifier or '}}' in braces, got {s} at line {}, column {} in {s}\n", .{
            @tagName(self.current.kind),
            self.current.line,
            self.current.column,
            self.lexer.filename,
        });
        return error.UnexpectedToken;
    }

    /// Finish parsing a function pattern after we've determined this is a pattern
    /// and consumed the first identifier
    fn finishPattern(self: *Self, start: usize, line: usize, column: usize, first_name: []const u8) !Expr {
        var formals = std.ArrayList(Expr.Formal).empty;

        // First formal
        var first_default: ?*Expr = null;
        if (self.current.kind == .question) {
            self.advance();
            const def = try self.parseExpr();
            first_default = try self.allocator.create(Expr);
            first_default.?.* = def;
        }
        try formals.append(self.allocator, .{
            .name = first_name,
            .default = first_default,
        });

        // Parse remaining formals
        var has_ellipsis = false;
        while (self.current.kind == .comma) {
            self.advance();

            if (self.current.kind == .ellipsis) {
                has_ellipsis = true;
                self.advance();
                break;
            }

            if (self.current.kind == .rbrace) break;

            if (self.current.kind != .identifier) {
                return error.ExpectedIdentifier;
            }

            const name = self.current.value.identifier;
            self.advance();

            var default_expr: ?*Expr = null;
            if (self.current.kind == .question) {
                self.advance();
                const def = try self.parseExpr();
                default_expr = try self.allocator.create(Expr);
                default_expr.?.* = def;
            }

            try formals.append(self.allocator, .{
                .name = name,
                .default = default_expr,
            });
        }

        // Handle trailing ellipsis without comma
        if (self.current.kind == .ellipsis) {
            has_ellipsis = true;
            self.advance();
        }

        try self.expect(.rbrace);

        // Check for `@name` after the pattern
        var at_name: ?[]const u8 = null;
        if (self.current.kind == .at) {
            self.advance();
            if (self.current.kind == .identifier) {
                at_name = self.current.value.identifier;
                self.advance();
            }
        }

        // Must be followed by `:` for a function
        try self.expect(.colon);
        const body = try self.parseExpr();
        const body_ptr = try self.allocator.create(Expr);
        body_ptr.* = body;

        return Expr{
            .lambda = .{
                .param = .{
                    .pattern = .{
                        .formals = try formals.toOwnedSlice(self.allocator),
                        .ellipsis = has_ellipsis,
                        .at_name = at_name,
                    },
                },
                .body = body_ptr,
                .span = .{ .start = start, .end = self.current.offset, .line = line, .column = column },
            },
        };
    }

    /// Parse a function pattern after `{` has been consumed
    fn parsePattern(self: *Self, at_name: ?[]const u8) !Expr.Pattern {
        var formals = std.ArrayList(Expr.Formal).empty;
        defer formals.deinit(self.allocator);

        var has_ellipsis = false;

        while (self.current.kind != .rbrace and self.current.kind != .eof) {
            if (self.current.kind == .ellipsis) {
                has_ellipsis = true;
                self.advance();
                break;
            }

            if (self.current.kind != .identifier) {
                return error.ExpectedIdentifier;
            }

            const name = self.current.value.identifier;
            self.advance();

            var default_expr: ?*Expr = null;
            if (self.current.kind == .question) {
                self.advance();
                const def = try self.parseExpr();
                default_expr = try self.allocator.create(Expr);
                default_expr.?.* = def;
            }

            try formals.append(self.allocator, .{
                .name = name,
                .default = default_expr,
            });

            if (self.current.kind == .comma) {
                self.advance();
            } else {
                break;
            }
        }

        // Handle trailing ellipsis
        if (self.current.kind == .ellipsis) {
            has_ellipsis = true;
            self.advance();
        }

        try self.expect(.rbrace);

        return Expr.Pattern{
            .formals = try formals.toOwnedSlice(self.allocator),
            .ellipsis = has_ellipsis,
            .at_name = at_name,
        };
    }

    /// Finish parsing an attribute set after we've consumed the first identifier
    fn finishAttrs(self: *Self, start: usize, line: usize, column: usize, first_name: []const u8) !Expr {
        const is_rec = false; // TODO: check for 'rec' keyword

        var bindings = std.ArrayList(Expr.Binding).empty;
        defer bindings.deinit(self.allocator);

        // Parse the first binding (we already have the first identifier)
        const first_binding = try self.parseBindingFromIdent(first_name);
        try bindings.append(self.allocator, first_binding);

        // Parse remaining bindings
        while (self.current.kind != .rbrace and self.current.kind != .eof) {
            if (self.current.kind == .identifier or self.current.kind == .string or self.current.kind == .string_part or self.current.kind == .dollar_brace or self.current.kind == .kw_or) {
                const binding = try self.parseBinding();
                try bindings.append(self.allocator, binding);
            } else if (self.current.kind == .kw_inherit) {
                try self.parseInherit(&bindings);
            } else {
                break;
            }
        }

        try self.expect(.rbrace);

        return Expr{
            .attrs = .{
                .bindings = try bindings.toOwnedSlice(self.allocator),
                .recursive = is_rec,
                .span = .{ .start = start, .end = self.current.offset, .line = line, .column = column },
            },
        };
    }

    /// Finish parsing an attribute set when we haven't consumed any identifier yet
    fn finishAttrsNoFirst(self: *Self, start: usize, line: usize, column: usize) !Expr {
        const is_rec = false;

        var bindings = std.ArrayList(Expr.Binding).empty;
        defer bindings.deinit(self.allocator);

        while (self.current.kind != .rbrace and self.current.kind != .eof) {
            if (self.current.kind == .identifier or self.current.kind == .string or self.current.kind == .string_part or self.current.kind == .dollar_brace or self.current.kind == .kw_or) {
                const binding = try self.parseBinding();
                try bindings.append(self.allocator, binding);
            } else if (self.current.kind == .kw_inherit) {
                try self.parseInherit(&bindings);
            } else {
                break;
            }
        }

        try self.expect(.rbrace);

        return Expr{
            .attrs = .{
                .bindings = try bindings.toOwnedSlice(self.allocator),
                .recursive = is_rec,
                .span = .{ .start = start, .end = self.current.offset, .line = line, .column = column },
            },
        };
    }

    /// Parse a recursive attribute set: rec { ... }
    fn parseRecAttrs(self: *Self, start: usize, line: usize, column: usize) !Expr {
        try self.expect(.lbrace);

        var bindings = std.ArrayList(Expr.Binding).empty;
        defer bindings.deinit(self.allocator);

        while (self.current.kind != .rbrace and self.current.kind != .eof) {
            if (self.current.kind == .identifier or self.current.kind == .string or self.current.kind == .string_part or self.current.kind == .dollar_brace or self.current.kind == .kw_or) {
                const binding = try self.parseBinding();
                try bindings.append(self.allocator, binding);
            } else if (self.current.kind == .kw_inherit) {
                try self.parseInherit(&bindings);
            } else {
                break;
            }
        }

        try self.expect(.rbrace);

        return Expr{
            .attrs = .{
                .bindings = try bindings.toOwnedSlice(self.allocator),
                .recursive = true,
                .span = .{ .start = start, .end = self.current.offset, .line = line, .column = column },
            },
        };
    }

    /// Parse a binding when we already have the first identifier
    fn parseBindingFromIdent(self: *Self, first_ident: []const u8) !Expr.Binding {
        var parts = std.ArrayList(Expr.AttrPathPart).empty;
        defer parts.deinit(self.allocator);

        try parts.append(self.allocator, .{ .ident = first_ident });

        // Continue parsing attribute path if there are dots
        while (self.current.kind == .dot) {
            self.advance();

            if (self.current.kind == .identifier) {
                try parts.append(self.allocator, .{ .ident = self.current.value.identifier });
                self.advance();
            } else if (self.current.kind == .kw_or) {
                try parts.append(self.allocator, .{ .ident = "or" });
                self.advance();
            } else if (self.current.kind == .string) {
                try parts.append(self.allocator, .{ .string = self.current.value.string });
                self.advance();
            } else if (self.current.kind == .string_part) {
                const interp = try self.parseInterpolatedString();
                const expr_ptr = try self.allocator.create(Expr);
                expr_ptr.* = interp;
                try parts.append(self.allocator, .{ .expr = expr_ptr });
            } else if (self.current.kind == .dollar_brace) {
                self.advance(); // consume ${
                const expr = try self.parseExpr();
                try self.expect(.rbrace);
                const expr_ptr = try self.allocator.create(Expr);
                expr_ptr.* = expr;
                try parts.append(self.allocator, .{ .expr = expr_ptr });
            } else {
                break;
            }
        }

        try self.expect(.eq);
        const value = try self.parseExpr();
        try self.expect(.semicolon);

        const value_ptr = try self.allocator.create(Expr);
        value_ptr.* = value;

        return Expr.Binding{
            .key = .{ .parts = try parts.toOwnedSlice(self.allocator) },
            .value = value_ptr,
            .span = .{ .start = 0, .end = 0, .line = self.current.line, .column = self.current.column },
        };
    }

    /// Parse an attribute path: ident.ident.${expr}...
    fn parseAttrPath(self: *Self) !Expr.AttrPath {
        var parts = std.ArrayList(Expr.AttrPathPart).empty;
        defer parts.deinit(self.allocator);

        while (true) {
            if (self.current.kind == .identifier) {
                try parts.append(self.allocator, .{ .ident = self.current.value.identifier });
                self.advance();
            } else if (self.current.kind == .kw_or) {
                try parts.append(self.allocator, .{ .ident = "or" });
                self.advance();
            } else if (self.current.kind == .string) {
                try parts.append(self.allocator, .{ .string = self.current.value.string });
                self.advance();
            } else if (self.current.kind == .dollar_brace) {
                self.advance(); // consume ${
                const expr = try self.parseExpr();
                try self.expect(.rbrace);
                const expr_ptr = try self.allocator.create(Expr);
                expr_ptr.* = expr;
                try parts.append(self.allocator, .{ .expr = expr_ptr });
            } else {
                break;
            }

            if (self.current.kind != .dot) break;
            self.advance();
        }

        return Expr.AttrPath{ .parts = try parts.toOwnedSlice(self.allocator) };
    }

    fn parseAttrs(self: *Self, start: usize, line: usize, column: usize) !Expr {
        try self.expect(.lbrace);

        const is_rec = false; // TODO: check for 'rec' keyword

        var bindings = std.ArrayList(Expr.Binding).empty;
        defer bindings.deinit(self.allocator);

        while (self.current.kind != .rbrace and self.current.kind != .eof) {
            if (self.current.kind == .identifier or self.current.kind == .string or self.current.kind == .string_part or self.current.kind == .dollar_brace or self.current.kind == .kw_or) {
                const binding = try self.parseBinding();
                try bindings.append(self.allocator, binding);
            } else if (self.current.kind == .kw_inherit) {
                // TODO: Parse inherit
                self.advance();
            } else {
                break;
            }
        }

        try self.expect(.rbrace);

        return Expr{
            .attrs = .{
                .bindings = try bindings.toOwnedSlice(self.allocator),
                .recursive = is_rec,
                .span = .{ .start = start, .end = self.current.offset, .line = line, .column = column },
            },
        };
    }

    fn parseBinding(self: *Self) !Expr.Binding {
        var parts = std.ArrayList(Expr.AttrPathPart).empty;
        defer parts.deinit(self.allocator);

        // Parse attribute path
        while (true) {
            if (self.current.kind == .identifier) {
                try parts.append(self.allocator, .{ .ident = self.current.value.identifier });
                self.advance();
            } else if (self.current.kind == .kw_or) {
                // 'or' can be used as an attribute name in Nix
                try parts.append(self.allocator, .{ .ident = "or" });
                self.advance();
            } else if (self.current.kind == .string) {
                try parts.append(self.allocator, .{ .string = self.current.value.string });
                self.advance();
            } else if (self.current.kind == .string_part) {
                // Interpolated string as key
                const interp = try self.parseInterpolatedString();
                const expr_ptr = try self.allocator.create(Expr);
                expr_ptr.* = interp;
                try parts.append(self.allocator, .{ .expr = expr_ptr });
            } else if (self.current.kind == .dollar_brace) {
                // ${expr} as dynamic key
                self.advance(); // consume ${
                const expr = try self.parseExpr();
                try self.expect(.rbrace);
                const expr_ptr = try self.allocator.create(Expr);
                expr_ptr.* = expr;
                try parts.append(self.allocator, .{ .expr = expr_ptr });
            } else {
                break;
            }

            if (self.current.kind != .dot) break;
            self.advance();
        }

        try self.expect(.eq);
        const value = try self.parseExpr();
        try self.expect(.semicolon);

        const value_ptr = try self.allocator.create(Expr);
        value_ptr.* = value;

        return Expr.Binding{
            .key = .{ .parts = try parts.toOwnedSlice(self.allocator) },
            .value = value_ptr,
            .span = .{ .start = 0, .end = 0, .line = self.current.line, .column = self.current.column },
        };
    }

    fn parseLet(self: *Self, start: usize, line: usize, column: usize) !Expr {
        try self.expect(.kw_let);

        var bindings = std.ArrayList(Expr.Binding).empty;
        defer bindings.deinit(self.allocator);

        while (self.current.kind != .kw_in and self.current.kind != .eof) {
            if (self.current.kind == .identifier or self.current.kind == .string or self.current.kind == .string_part or self.current.kind == .dollar_brace or self.current.kind == .kw_or) {
                const binding = try self.parseBinding();
                try bindings.append(self.allocator, binding);
            } else if (self.current.kind == .kw_inherit) {
                // Parse inherit (source)? names...;
                try self.parseInherit(&bindings);
            } else {
                break;
            }
        }

        try self.expect(.kw_in);
        const body = try self.parseExpr();
        const body_ptr = try self.allocator.create(Expr);
        body_ptr.* = body;

        return Expr{
            .let_in = .{
                .bindings = try bindings.toOwnedSlice(self.allocator),
                .body = body_ptr,
                .span = .{ .start = start, .end = self.current.offset, .line = line, .column = column },
            },
        };
    }

    /// Parse `inherit [( expr )] names... ;`
    fn parseInherit(self: *Self, bindings: *std.ArrayList(Expr.Binding)) !void {
        try self.expect(.kw_inherit);

        // Check for optional source expression: inherit (expr) ...
        var source_expr: ?*Expr = null;
        if (self.current.kind == .lparen) {
            self.advance();
            const src = try self.parseExpr();
            source_expr = try self.allocator.create(Expr);
            source_expr.?.* = src;
            try self.expect(.rparen);
        }

        // Parse attribute names to inherit
        // Nix allows identifiers, keywords used as identifiers (or, and), and quoted strings
        while (self.current.kind != .semicolon and self.current.kind != .rbrace and self.current.kind != .eof) {
            const name: []const u8 = switch (self.current.kind) {
                .identifier => self.current.value.identifier,
                .kw_or => "or",
                .string => self.current.value.string,
                else => break,
            };
            self.advance();

            // Create a binding for this inherited attribute
            // For `inherit a;` this is like `a = a;`
            // For `inherit (expr) a;` this is like `a = expr.a;`
            const value_expr = try self.allocator.create(Expr);
            if (source_expr) |src| {
                // inherit (expr) name  =>  name = expr.name
                const select_parts = try self.allocator.alloc(Expr.AttrPathPart, 1);
                select_parts[0] = .{ .ident = name };
                value_expr.* = Expr{
                    .select = .{
                        .base = src,
                        .path = .{ .parts = select_parts },
                        .default = null,
                        .span = .{ .start = 0, .end = 0, .line = self.current.line, .column = self.current.column },
                    },
                };
            } else {
                // inherit name  =>  name = name (from outer scope)
                value_expr.* = Expr{ .var_ref = name };
            }

            const owned_parts = try self.allocator.alloc(Expr.AttrPathPart, 1);
            owned_parts[0] = .{ .ident = name };

            try bindings.append(self.allocator, .{
                .key = .{ .parts = owned_parts },
                .value = value_expr,
                .span = .{ .start = 0, .end = 0, .line = self.current.line, .column = self.current.column },
            });
        }

        try self.expect(.semicolon);
    }

    fn parseIf(self: *Self, start: usize, line: usize, column: usize) !Expr {
        try self.expect(.kw_if);
        const cond = try self.parseExpr();
        try self.expect(.kw_then);
        const then_expr = try self.parseExpr();
        try self.expect(.kw_else);
        const else_expr = try self.parseExpr();

        const cond_ptr = try self.allocator.create(Expr);
        cond_ptr.* = cond;
        const then_ptr = try self.allocator.create(Expr);
        then_ptr.* = then_expr;
        const else_ptr = try self.allocator.create(Expr);
        else_ptr.* = else_expr;

        return Expr{
            .if_then_else = .{
                .cond = cond_ptr,
                .then_expr = then_ptr,
                .else_expr = else_ptr,
                .span = .{ .start = start, .end = self.current.offset, .line = line, .column = column },
            },
        };
    }

    fn parseWith(self: *Self, start: usize, line: usize, column: usize) !Expr {
        try self.expect(.kw_with);
        const env = try self.parseExpr();
        try self.expect(.semicolon);
        const body = try self.parseExpr();

        const env_ptr = try self.allocator.create(Expr);
        env_ptr.* = env;
        const body_ptr = try self.allocator.create(Expr);
        body_ptr.* = body;

        return Expr{
            .with = .{
                .env = env_ptr,
                .body = body_ptr,
                .span = .{ .start = start, .end = self.current.offset, .line = line, .column = column },
            },
        };
    }

    fn parseAssert(self: *Self, start: usize, line: usize, column: usize) !Expr {
        try self.expect(.kw_assert);
        const cond = try self.parseExpr();
        try self.expect(.semicolon);
        const body = try self.parseExpr();

        const cond_ptr = try self.allocator.create(Expr);
        cond_ptr.* = cond;
        const body_ptr = try self.allocator.create(Expr);
        body_ptr.* = body;

        return Expr{
            .assert_expr = .{
                .cond = cond_ptr,
                .body = body_ptr,
                .span = .{ .start = start, .end = self.current.offset, .line = line, .column = column },
            },
        };
    }

    /// Parse an interpolated string like "hello ${name}!"
    fn parseInterpolatedString(self: *Self) !Expr {
        var parts = std.ArrayList(Expr.StringPart).empty;
        defer parts.deinit(self.allocator);

        // Track our depth for this string
        self.string_interpolation_depth += 1;
        defer self.string_interpolation_depth -= 1;

        // Add the first literal part (before first ${)
        const first_lit = self.current.value.string;
        if (first_lit.len > 0) {
            try parts.append(self.allocator, .{ .literal = first_lit });
        }
        // Save the lexer's string depth for this interpolation
        // (before advancing, while we're still at the string_part token)
        const my_string_depth = self.lexer.string_depth;
        self.advance();

        // Now we've consumed string_part, the next tokens are the expression
        // Parse the expression, then expect string_part or string_end
        // Save and set flag to prevent parsePostfix from consuming string continuations
        const was_in_interpolation = self.in_string_interpolation;
        self.in_string_interpolation = true;
        // Also save the old lexer depth and set the current one
        const old_interpolation_string_depth = self.interpolation_string_depth;
        self.interpolation_string_depth = my_string_depth;
        defer self.interpolation_string_depth = old_interpolation_string_depth;

        while (true) {
            // Parse the interpolated expression (with flag set to prevent consuming string continuations)
            const expr = try self.parseExpr();
            const expr_ptr = try self.allocator.create(Expr);
            expr_ptr.* = expr;
            try parts.append(self.allocator, .{ .expr = expr_ptr });

            // After the expression, we should see string_part or string_end
            if (self.current.kind == .string_part) {
                const lit = self.current.value.string;
                if (lit.len > 0) {
                    try parts.append(self.allocator, .{ .literal = lit });
                }
                self.advance();
                // Continue to next interpolation
            } else if (self.current.kind == .string_end) {
                // This string_end is for our string (nested strings are fully consumed by their parseInterpolatedString)
                const lit = self.current.value.string;
                if (lit.len > 0) {
                    try parts.append(self.allocator, .{ .literal = lit });
                }
                self.advance();
                break; // Done
            } else {
                std.debug.print("parseInterpolatedString: expected string_part or string_end, got {s} at line {}, col {} in {s}\n", .{
                    @tagName(self.current.kind),
                    self.current.line,
                    self.current.column,
                    self.lexer.filename,
                });
                return error.UnexpectedToken;
            }
        }

        // Restore the flag after we're done with this string
        self.in_string_interpolation = was_in_interpolation;

        return Expr{
            .interpolated_string = .{
                .parts = try parts.toOwnedSlice(self.allocator),
                .span = .{ .start = 0, .end = 0, .line = 0, .column = 0 },
            },
        };
    }

    fn advance(self: *Self) void {
        self.current = self.peek_token;
        self.peek_token = self.lexer.nextToken() catch Token{
            .kind = .eof,
            .value = .none,
            .line = 0,
            .column = 0,
            .offset = 0,
        };
    }

    fn expect(self: *Self, kind: TokenKind) !void {
        if (self.current.kind != kind) {
            std.debug.print("Expected {s}, got {s} at line {}, column {} in {s}\n", .{
                @tagName(kind),
                @tagName(self.current.kind),
                self.current.line,
                self.current.column,
                self.lexer.filename,
            });
            return error.UnexpectedToken;
        }
        self.advance();
    }
};

test "parser basic expressions" {
    const allocator = std.testing.allocator;

    // Test integer
    {
        var reader = std.Io.Reader.fixed("42");
        var p = try Parser.init(allocator, &reader, "test");
        defer p.deinit();
        const expr = try p.parseExpr();
        try std.testing.expectEqual(@as(i64, 42), expr.int);
    }

    // Test simple arithmetic
    {
        var reader = std.Io.Reader.fixed("1 + 2");
        var p = try Parser.init(allocator, &reader, "test");
        defer p.deinit();
        const expr = try p.parseExpr();
        defer expr.deinit(allocator);
        try std.testing.expect(expr == .binary_op);
    }

    // Test list
    {
        var reader = std.Io.Reader.fixed("[ 1 2 3 ]");
        var p = try Parser.init(allocator, &reader, "test");
        defer p.deinit();
        const expr = try p.parseExpr();
        defer expr.deinit(allocator);
        try std.testing.expect(expr == .list);
        try std.testing.expectEqual(@as(usize, 3), expr.list.elements.len);
    }
}
