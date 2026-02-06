const std = @import("std");

pub const Span = struct {
    start: usize,
    end: usize,
    line: usize,
    column: usize,
};

pub const Expr = union(enum) {
    int: i64,
    float: f64,
    string: []const u8,
    interpolated_string: InterpolatedString,
    path: []const u8,
    uri: []const u8,
    var_ref: []const u8,
    list: List,
    attrs: Attrs,
    select: Select,
    call: Call,
    lambda: Lambda,
    let_in: LetIn,
    if_then_else: IfThenElse,
    with: With,
    assert_expr: Assert,
    binary_op: BinaryOp,
    unary_op: UnaryOp,

    pub const InterpolatedString = struct {
        parts: []StringPart,
        span: Span,
    };

    pub const StringPart = union(enum) {
        literal: []const u8,
        expr: *Expr,
    };

    pub const List = struct {
        elements: []Expr,
        span: Span,
    };

    pub const Attrs = struct {
        bindings: []Binding,
        recursive: bool,
        span: Span,
    };

    pub const Binding = struct {
        key: AttrPath,
        value: *Expr,
        span: Span,
    };

    pub const AttrPath = struct {
        parts: []AttrPathPart,
    };

    pub const AttrPathPart = union(enum) {
        ident: []const u8,
        string: []const u8,
        expr: *Expr,
    };

    pub const Select = struct {
        base: *Expr,
        path: AttrPath,
        default: ?*Expr,
        span: Span,
    };

    pub const Call = struct {
        func: *Expr,
        arg: *Expr,
        span: Span,
    };

    pub const Lambda = struct {
        param: Param,
        body: *Expr,
        span: Span,
    };

    pub const Param = union(enum) {
        ident: []const u8,
        pattern: Pattern,
    };

    pub const Pattern = struct {
        formals: []Formal,
        ellipsis: bool,
        at_name: ?[]const u8,
    };

    pub const Formal = struct {
        name: []const u8,
        default: ?*Expr,
    };

    pub const LetIn = struct {
        bindings: []Binding,
        body: *Expr,
        span: Span,
    };

    pub const IfThenElse = struct {
        cond: *Expr,
        then_expr: *Expr,
        else_expr: *Expr,
        span: Span,
    };

    pub const With = struct {
        env: *Expr,
        body: *Expr,
        span: Span,
    };

    pub const Assert = struct {
        cond: *Expr,
        body: *Expr,
        span: Span,
    };

    pub const BinaryOp = struct {
        op: BinaryOperator,
        left: *Expr,
        right: *Expr,
        span: Span,
    };

    pub const UnaryOp = struct {
        op: UnaryOperator,
        operand: *Expr,
        span: Span,
    };

    pub const BinaryOperator = enum {
        add,
        sub,
        mul,
        div,
        concat,
        update,
        eq,
        neq,
        lt,
        lte,
        gt,
        gte,
        and_op,
        or_op,
        implies,
        has_attr,
    };

    pub const UnaryOperator = enum {
        not,
        negate,
    };

    pub fn deinit(self: Expr, allocator: std.mem.Allocator) void {
        switch (self) {
            .int, .float => {},
            // NOTE: String slices point into source, don't free them
            .string => {},
            .interpolated_string => |is| {
                for (is.parts) |part| {
                    switch (part) {
                        // Literals are slices into source, don't free
                        .literal => |l| {
                            allocator.free(l);
                        },
                        .expr => |e| {
                            e.deinit(allocator);
                            allocator.destroy(e);
                        },
                    }
                }
                allocator.free(is.parts);
            },
            // Paths, URIs, var_refs are slices into source, don't free
            .path => {},
            .uri => {},
            .var_ref => {},
            .list => |l| {
                for (l.elements) |elem| {
                    elem.deinit(allocator);
                }
                allocator.free(l.elements);
            },
            .attrs => |a| {
                for (a.bindings) |binding| {
                    for (binding.key.parts) |part| {
                        switch (part) {
                            // ident/string are slices into source, don't free
                            .ident => {},
                            .string => {},
                            .expr => |e| {
                                e.deinit(allocator);
                                allocator.destroy(e);
                            },
                        }
                    }
                    allocator.free(binding.key.parts);
                    binding.value.deinit(allocator);
                    allocator.destroy(binding.value);
                }
                allocator.free(a.bindings);
            },
            .select => |s| {
                s.base.deinit(allocator);
                allocator.destroy(s.base);
                for (s.path.parts) |part| {
                    switch (part) {
                        // ident/string are slices into source, don't free
                        .ident => {},
                        .string => {},
                        .expr => |e| {
                            e.deinit(allocator);
                            allocator.destroy(e);
                        },
                    }
                }
                allocator.free(s.path.parts);
                if (s.default) |d| {
                    d.deinit(allocator);
                    allocator.destroy(d);
                }
            },
            .call => |c| {
                c.func.deinit(allocator);
                allocator.destroy(c.func);
                c.arg.deinit(allocator);
                allocator.destroy(c.arg);
            },
            .lambda => |l| {
                switch (l.param) {
                    // ident is slice into source, don't free
                    .ident => {},
                    .pattern => |p| {
                        for (p.formals) |formal| {
                            // formal.name is slice into source, don't free
                            if (formal.default) |d| {
                                d.deinit(allocator);
                                allocator.destroy(d);
                            }
                        }
                        allocator.free(p.formals);
                        // at_name is slice into source, don't free
                    },
                }
                l.body.deinit(allocator);
                allocator.destroy(l.body);
            },
            .let_in => |l| {
                for (l.bindings) |binding| {
                    for (binding.key.parts) |part| {
                        switch (part) {
                            // ident/string are slices into source, don't free
                            .ident => {},
                            .string => {},
                            .expr => |e| {
                                e.deinit(allocator);
                                allocator.destroy(e);
                            },
                        }
                    }
                    allocator.free(binding.key.parts);
                    binding.value.deinit(allocator);
                    allocator.destroy(binding.value);
                }
                allocator.free(l.bindings);
                l.body.deinit(allocator);
                allocator.destroy(l.body);
            },
            .if_then_else => |i| {
                i.cond.deinit(allocator);
                allocator.destroy(i.cond);
                i.then_expr.deinit(allocator);
                allocator.destroy(i.then_expr);
                i.else_expr.deinit(allocator);
                allocator.destroy(i.else_expr);
            },
            .with => |w| {
                w.env.deinit(allocator);
                allocator.destroy(w.env);
                w.body.deinit(allocator);
                allocator.destroy(w.body);
            },
            .assert_expr => |a| {
                a.cond.deinit(allocator);
                allocator.destroy(a.cond);
                a.body.deinit(allocator);
                allocator.destroy(a.body);
            },
            .binary_op => |b| {
                b.left.deinit(allocator);
                allocator.destroy(b.left);
                b.right.deinit(allocator);
                allocator.destroy(b.right);
            },
            .unary_op => |u| {
                u.operand.deinit(allocator);
                allocator.destroy(u.operand);
            },
        }
    }

    pub fn print(self: Expr, writer: anytype, indent: usize) !void {
        try self.printIndent(writer, indent);
        switch (self) {
            .int => |v| try writer.print("Int({})\n", .{v}),
            .float => |v| try writer.print("Float({})\n", .{v}),
            .string => |s| try writer.print("String(\"{s}\")\n", .{s}),
            .interpolated_string => |is| {
                try writer.writeAll("InterpolatedString(\n");
                for (is.parts) |part| {
                    try self.printIndent(writer, indent + 2);
                    switch (part) {
                        .literal => |lit| try writer.print("Lit(\"{s}\")\n", .{lit}),
                        .expr => |e| {
                            try writer.writeAll("Expr(\n");
                            try e.print(writer, indent + 4);
                            try self.printIndent(writer, indent + 2);
                            try writer.writeAll(")\n");
                        },
                    }
                }
                try self.printIndent(writer, indent);
                try writer.writeAll(")\n");
            },
            .path => |p| try writer.print("Path({s})\n", .{p}),
            .uri => |u| try writer.print("Uri({s})\n", .{u}),
            .var_ref => |v| try writer.print("Var({s})\n", .{v}),
            .list => |l| {
                try writer.writeAll("List[\n");
                for (l.elements) |elem| {
                    try elem.print(writer, indent + 2);
                }
                try self.printIndent(writer, indent);
                try writer.writeAll("]\n");
            },
            .attrs => |a| {
                if (a.recursive) {
                    try writer.writeAll("RecAttrs{\n");
                } else {
                    try writer.writeAll("Attrs{\n");
                }
                for (a.bindings) |binding| {
                    try self.printIndent(writer, indent + 2);
                    try self.printAttrPath(binding.key, writer);
                    try writer.writeAll(" =\n");
                    try binding.value.print(writer, indent + 4);
                }
                try self.printIndent(writer, indent);
                try writer.writeAll("}\n");
            },
            .select => |s| {
                try writer.writeAll("Select(\n");
                try s.base.print(writer, indent + 2);
                try self.printIndent(writer, indent + 2);
                try writer.writeAll(".");
                try self.printAttrPath(s.path, writer);
                try writer.writeAll("\n");
                if (s.default) |def| {
                    try self.printIndent(writer, indent + 2);
                    try writer.writeAll("or\n");
                    try def.print(writer, indent + 4);
                }
                try self.printIndent(writer, indent);
                try writer.writeAll(")\n");
            },
            .call => |c| {
                try writer.writeAll("Call(\n");
                try c.func.print(writer, indent + 2);
                try c.arg.print(writer, indent + 2);
                try self.printIndent(writer, indent);
                try writer.writeAll(")\n");
            },
            .lambda => |l| {
                try writer.writeAll("Lambda(\n");
                try self.printIndent(writer, indent + 2);
                try self.printParam(l.param, writer);
                try writer.writeAll(" =>\n");
                try l.body.print(writer, indent + 2);
                try self.printIndent(writer, indent);
                try writer.writeAll(")\n");
            },
            .let_in => |l| {
                try writer.writeAll("Let{\n");
                for (l.bindings) |binding| {
                    try self.printIndent(writer, indent + 2);
                    try self.printAttrPath(binding.key, writer);
                    try writer.writeAll(" =\n");
                    try binding.value.print(writer, indent + 4);
                }
                try self.printIndent(writer, indent);
                try writer.writeAll("} in\n");
                try l.body.print(writer, indent + 2);
            },
            .if_then_else => |i| {
                try writer.writeAll("If(\n");
                try i.cond.print(writer, indent + 2);
                try self.printIndent(writer, indent);
                try writer.writeAll(") then\n");
                try i.then_expr.print(writer, indent + 2);
                try self.printIndent(writer, indent);
                try writer.writeAll("else\n");
                try i.else_expr.print(writer, indent + 2);
            },
            .with => |w| {
                try writer.writeAll("With(\n");
                try w.env.print(writer, indent + 2);
                try self.printIndent(writer, indent);
                try writer.writeAll(") in\n");
                try w.body.print(writer, indent + 2);
            },
            .assert_expr => |a| {
                try writer.writeAll("Assert(\n");
                try a.cond.print(writer, indent + 2);
                try self.printIndent(writer, indent);
                try writer.writeAll(") in\n");
                try a.body.print(writer, indent + 2);
            },
            .binary_op => |b| {
                try writer.print("BinaryOp({s},\n", .{@tagName(b.op)});
                try b.left.print(writer, indent + 2);
                try b.right.print(writer, indent + 2);
                try self.printIndent(writer, indent);
                try writer.writeAll(")\n");
            },
            .unary_op => |u| {
                try writer.print("UnaryOp({s},\n", .{@tagName(u.op)});
                try u.operand.print(writer, indent + 2);
                try self.printIndent(writer, indent);
                try writer.writeAll(")\n");
            },
        }
    }

    fn printIndent(self: Expr, writer: anytype, indent: usize) !void {
        _ = self;
        var i: usize = 0;
        while (i < indent) : (i += 1) {
            try writer.writeAll(" ");
        }
    }

    fn printAttrPath(self: Expr, path: AttrPath, writer: anytype) !void {
        _ = self;
        for (path.parts, 0..) |part, i| {
            if (i > 0) try writer.writeAll(".");
            switch (part) {
                .ident => |id| try writer.print("{s}", .{id}),
                .string => |s| try writer.print("\"{s}\"", .{s}),
                .expr => try writer.writeAll("${...}"),
            }
        }
    }

    fn printParam(self: Expr, param: Lambda.Param, writer: anytype) !void {
        _ = self;
        switch (param) {
            .ident => |id| try writer.print("{s}", .{id}),
            .pattern => |p| {
                try writer.writeAll("{ ");
                for (p.formals, 0..) |formal, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try writer.print("{s}", .{formal.name});
                    if (formal.default != null) try writer.writeAll(" ? ...");
                }
                if (p.ellipsis) try writer.writeAll(", ...");
                try writer.writeAll(" }");
                if (p.at_name) |name| {
                    try writer.print(" @ {s}", .{name});
                }
            },
        }
    }
};
