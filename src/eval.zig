const std = @import("std");
const ast = @import("ast.zig");
const builtins = @import("builtins.zig");

const Expr = ast.Expr;

pub const Value = union(enum) {
    int: i64,
    float: f64,
    bool: bool,
    string: []const u8,
    path: []const u8,
    null_val,
    list: []Value,
    attrs: AttrSet,
    lambda: Lambda,
    builtin: Builtin,
    thunk: *Thunk,

    pub const AttrSet = struct {
        bindings: std.StringHashMap(Value),
    };

    pub const Lambda = struct {
        param: ast.Expr.Param,
        body: *Expr,
        env: *Env,
    };

    pub const Builtin = struct {
        name: []const u8,
        func: *const fn (eval_ctx: ?*Evaluator, io: std.Io, allocator: std.mem.Allocator, args: []Value) anyerror!Value,
        arity: u8 = 1,
        partial_args: ?[]Value = null,
    };

    pub fn print(self: Value, writer: anytype) error{OutOfMemory}!void {
        switch (self) {
            .int => |v| writer.print("{}", .{v}) catch {},
            .float => |v| writer.print("{d}", .{v}) catch {},
            .bool => |v| writer.writeAll(if (v) "true" else "false") catch {},
            .string => |s| writer.print("\"{s}\"", .{s}) catch {},
            .path => |p| writer.print("{s}", .{p}) catch {},
            .null_val => writer.writeAll("null") catch {},
            .list => |l| {
                writer.writeAll("[ ") catch {};
                for (l) |elem| {
                    elem.print(writer) catch {};
                    writer.writeAll(" ") catch {};
                }
                writer.writeAll("]") catch {};
            },
            .attrs => |a| {
                writer.writeAll("{ ") catch {};
                var iter = a.bindings.iterator();
                while (iter.next()) |entry| {
                    writer.print("{s} = ", .{entry.key_ptr.*}) catch {};
                    entry.value_ptr.print(writer) catch {};
                    writer.writeAll("; ") catch {};
                }
                writer.writeAll("}") catch {};
            },
            .lambda => writer.writeAll("<lambda>") catch {},
            .builtin => |b| writer.print("<builtin:{s}>", .{b.name}) catch {},
            .thunk => writer.writeAll("<thunk>") catch {},
        }
    }

    pub fn deinit(self: Value, allocator: std.mem.Allocator) void {
        // With arena allocation, individual deinit is a no-op.
        // The arena frees everything at once in Evaluator.deinit().
        _ = self;
        _ = allocator;
    }
};

pub const Thunk = struct {
    expr: *Expr,
    env: *Env,
    value: ?Value,
    evaluating: bool,
};

pub const Env = struct {
    allocator: std.mem.Allocator,
    bindings: std.StringHashMap(Value),
    parent: ?*Env,

    pub fn init(allocator: std.mem.Allocator, parent: ?*Env) !*Env {
        const env = try allocator.create(Env);
        env.* = Env{
            .allocator = allocator,
            .bindings = std.StringHashMap(Value).init(allocator),
            .parent = parent,
        };
        return env;
    }

    pub fn deinit(self: *Env) void {
        // Don't recursively deinit values - they may be shared across
        // multiple environments (e.g., thunks in let bindings, follows).
        // Values are effectively arena-allocated for the evaluation lifetime.
        self.bindings.deinit();
        self.allocator.destroy(self);
    }

    pub fn define(self: *Env, name: []const u8, value: Value) !void {
        try self.bindings.put(name, value);
    }

    pub fn lookup(self: *Env, name: []const u8) ?Value {
        if (self.bindings.get(name)) |val| {
            return val;
        }
        if (self.parent) |parent| {
            return parent.lookup(name);
        }
        return null;
    }
};

pub const Evaluator = struct {
    parent_allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    global_env: *Env,
    io: std.Io,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !Self {
        var self = Self{
            .parent_allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .global_env = undefined,
            .io = io,
        };

        const global_env = try self.createEnv(null);

        // Register builtins
        try builtins.registerBuiltins(global_env);

        self.global_env = global_env;
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.arena.deinit();
    }

    /// Get the arena allocator for allocations during evaluation
    pub inline fn alloc(self: *Self) std.mem.Allocator {
        return self.arena.allocator();
    }

    /// Create an Env via the arena allocator.
    pub fn createEnv(self: *Self, parent: ?*Env) !*Env {
        const allocator = self.arena.allocator();
        const env = try allocator.create(Env);
        env.* = Env{
            .allocator = allocator,
            .bindings = std.StringHashMap(Value).init(allocator),
            .parent = parent,
        };
        return env;
    }

    /// Create a Thunk via the arena allocator.
    fn createThunk(self: *Self, expr: *Expr, env: *Env) !*Thunk {
        const allocator = self.arena.allocator();
        const thunk = try allocator.create(Thunk);
        thunk.* = Thunk{
            .expr = expr,
            .env = env,
            .value = null,
            .evaluating = false,
        };
        return thunk;
    }

    /// Resolve an AttrPathPart to a string key.
    /// Returns null if the key is a dynamic null (Nix skips such bindings).
    fn resolveAttrKey(self: *Self, part: Expr.AttrPathPart, env: *Env) !?[]const u8 {
        return switch (part) {
            .ident => |id| id,
            .string => |str| str,
            .expr => |e| {
                const val = try self.force(try self.evalInEnv(e.*, env));
                return switch (val) {
                    .string => val.string,
                    .null_val => null, // Nix: { ${null} = val; } is skipped
                    else => error.TypeError,
                };
            },
        };
    }

    pub fn eval(self: *Self, expr: Expr) !Value {
        const result = try self.evalInEnv(expr, self.global_env);
        return try self.force(result);
    }

    pub fn evalInEnv(self: *Self, expr: Expr, env: *Env) anyerror!Value {
        switch (expr) {
            .int => |v| return Value{ .int = v },
            .float => |v| return Value{ .float = v },
            .string => |s| return Value{ .string = s },
            .interpolated_string => |is| {
                // Evaluate all parts and concatenate
                var result: std.ArrayList(u8) = .empty;
                defer result.deinit(self.alloc());

                for (is.parts) |part| {
                    switch (part) {
                        .literal => |lit| try result.appendSlice(self.alloc(), lit),
                        .expr => |e| {
                            const val = try self.evalInEnv(e.*, env);
                            const forced = try self.force(val);
                            // Coerce to string (Nix string interpolation rules)
                            switch (forced) {
                                .string => |s| try result.appendSlice(self.alloc(), s),
                                .int => |i| {
                                    var buf: [32]u8 = undefined;
                                    const s = std.fmt.bufPrint(&buf, "{d}", .{i}) catch "";
                                    try result.appendSlice(self.alloc(), s);
                                },
                                .path => |p| try result.appendSlice(self.alloc(), p),
                                .bool => |b| try result.appendSlice(self.alloc(), if (b) "1" else "0"),
                                .null_val => try result.appendSlice(self.alloc(), ""),
                                .attrs => |a| {
                                    // Nix coerces attrsets with __toString or outPath
                                    if (a.bindings.get("__toString")) |to_str_fn| {
                                        const str_val = try self.apply(to_str_fn, forced);
                                        const forced_str = try self.force(str_val);
                                        if (forced_str == .string) {
                                            try result.appendSlice(self.alloc(), forced_str.string);
                                        }
                                    } else if (a.bindings.get("outPath")) |out_path| {
                                        const forced_path = try self.force(out_path);
                                        switch (forced_path) {
                                            .string => |s| try result.appendSlice(self.alloc(), s),
                                            .path => |p| try result.appendSlice(self.alloc(), p),
                                            else => return error.TypeError,
                                        }
                                    } else {
                                        return error.TypeError;
                                    }
                                },
                                .float => |f| {
                                    var buf: [64]u8 = undefined;
                                    const s = std.fmt.bufPrint(&buf, "{d}", .{f}) catch "";
                                    try result.appendSlice(self.alloc(), s);
                                },
                                else => return error.TypeError,
                            }
                        },
                    }
                }
                return Value{ .string = try result.toOwnedSlice(self.alloc()) };
            },
            .path => |p| return Value{ .path = p },
            .uri => |u| return Value{ .string = u },

            .var_ref => |name| {
                if (env.lookup(name)) |val| {
                    // Don't force thunks here - Nix is lazy.
                    // Thunks are forced at consumption points (attr access, arithmetic, etc.)
                    return val;
                }
                std.debug.print("Undefined variable: {s}\n", .{name});
                return error.UndefinedVariable;
            },

            .list => |l| {
                var values = try self.alloc().alloc(Value, l.elements.len);
                for (l.elements, 0..) |elem, i| {
                    values[i] = try self.evalInEnv(elem, env);
                }
                return Value{ .list = values };
            },

            .attrs => |a| {
                var attr_env = try self.createEnv(env);
                _ = &attr_env;
                var bindings = std.StringHashMap(Value).init(self.alloc());

                // If recursive, evaluate in extended env
                if (a.recursive) {
                    // First pass: create thunks
                    for (a.bindings) |binding| {
                        if (binding.key.parts.len == 1) {
                            const key = try self.resolveAttrKey(binding.key.parts[0], attr_env) orelse continue;
                            const thunk = try self.createThunk(binding.value, attr_env);
                            try bindings.put(key, Value{ .thunk = thunk });
                            try attr_env.define(key, Value{ .thunk = thunk });
                        }
                    }
                } else {
                    // Non-recursive: still use thunks for lazy evaluation.
                    // Nix attrset values are lazy even in non-recursive sets.
                    for (a.bindings) |binding| {
                        if (binding.key.parts.len == 1) {
                            const key = try self.resolveAttrKey(binding.key.parts[0], env) orelse continue;
                            const thunk = try self.createThunk(binding.value, env);
                            try bindings.put(key, Value{ .thunk = thunk });
                        }
                    }
                }

                return Value{ .attrs = .{ .bindings = bindings } };
            },

            .select => |s| {
                const base = try self.evalInEnv(s.base.*, env);
                const forced = try self.force(base);

                if (forced != .attrs) {
                    if (s.default) |def| {
                        return try self.evalInEnv(def.*, env);
                    }
                    return error.NotAnAttrSet;
                }

                // Navigate through attribute path
                var current = forced.attrs;
                for (s.path.parts, 0..) |part, i| {
                    const key = try self.resolveAttrKey(part, env) orelse return error.DynamicAttrPath;

                    if (current.bindings.get(key)) |val| {
                        if (i == s.path.parts.len - 1) {
                            return try self.force(val);
                        }
                        const forced_val = try self.force(val);
                        if (forced_val != .attrs) {
                            if (s.default) |def| {
                                return try self.evalInEnv(def.*, env);
                            }
                            return error.NotAnAttrSet;
                        }
                        current = forced_val.attrs;
                    } else {
                        if (s.default) |def| {
                            return try self.evalInEnv(def.*, env);
                        }
                        return error.AttributeNotFound;
                    }
                }
                return error.EmptyAttrPath;
            },

            .call => |c| {
                const raw_func = try self.evalInEnv(c.func.*, env);
                const func = try self.force(raw_func);
                const arg = try self.evalInEnv(c.arg.*, env);

                switch (func) {
                    .lambda => |lam| {
                        const call_env = try self.createEnv(lam.env);

                        switch (lam.param) {
                            .ident => |name| {
                                try call_env.define(name, arg);
                            },
                            .pattern => |p| {
                                const forced_arg = try self.force(arg);
                                if (forced_arg != .attrs) {
                                    return error.PatternMatchFailed;
                                }

                                // Bind @name first so defaults can reference it
                                if (p.at_name) |at| {
                                    try call_env.define(at, arg);
                                }

                                for (p.formals) |formal| {
                                    if (forced_arg.attrs.bindings.get(formal.name)) |val| {
                                        try call_env.define(formal.name, val);
                                    } else if (formal.default) |def| {
                                        const default_val = try self.evalInEnv(def.*, call_env);
                                        try call_env.define(formal.name, default_val);
                                    } else {
                                        return error.MissingAttribute;
                                    }
                                }
                            },
                        }

                        return try self.evalInEnv(lam.body.*, call_env);
                    },
                    .builtin => |b| {
                        // Collect args (including any partial args from currying)
                        const prev_args = b.partial_args orelse &[_]Value{};
                        const total_args = prev_args.len + 1;

                        if (total_args < b.arity) {
                            // Not enough args yet - return a new partial application
                            const new_partial = try self.alloc().alloc(Value, total_args);
                            @memcpy(new_partial[0..prev_args.len], prev_args);
                            new_partial[prev_args.len] = arg;
                            return Value{
                                .builtin = .{
                                    .name = b.name,
                                    .func = b.func,
                                    .arity = b.arity,
                                    .partial_args = new_partial,
                                },
                            };
                        }

                        // Have all args - force them and call the function
                        const args = try self.alloc().alloc(Value, total_args);
                        @memcpy(args[0..prev_args.len], prev_args);
                        args[prev_args.len] = arg;
                        // Force all args before passing to builtin
                        for (args) |*a| {
                            a.* = try self.force(a.*);
                        }
                        return try b.func(self, self.io, self.alloc(), args);
                    },
                    else => {
                        return error.NotAFunction;
                    },
                }
            },

            .lambda => |l| {
                return Value{
                    .lambda = .{
                        .param = l.param,
                        .body = l.body,
                        .env = env,
                    },
                };
            },

            .let_in => |l| {
                const let_env = try self.createEnv(env);

                // Nix let bindings are mutually recursive, so first create
                // thunks for all bindings, then evaluate the body.
                for (l.bindings) |binding| {
                    if (binding.key.parts.len == 1) {
                        const key = try self.resolveAttrKey(binding.key.parts[0], let_env) orelse continue;
                        const thunk = try self.createThunk(binding.value, let_env);
                        try let_env.define(key, Value{ .thunk = thunk });
                    }
                }

                return try self.evalInEnv(l.body.*, let_env);
            },

            .if_then_else => |i| {
                const cond = try self.force(try self.evalInEnv(i.cond.*, env));
                const cond_bool = try self.toBool(cond);

                if (cond_bool) {
                    return try self.evalInEnv(i.then_expr.*, env);
                } else {
                    return try self.evalInEnv(i.else_expr.*, env);
                }
            },

            .with => |w| {
                const with_set = try self.force(try self.evalInEnv(w.env.*, env));
                if (with_set != .attrs) {
                    return error.WithRequiresAttrSet;
                }

                const with_env = try self.createEnv(env);
                var iter = with_set.attrs.bindings.iterator();
                while (iter.next()) |entry| {
                    try with_env.define(entry.key_ptr.*, entry.value_ptr.*);
                }

                return try self.evalInEnv(w.body.*, with_env);
            },

            .assert_expr => |a| {
                const cond = try self.force(try self.evalInEnv(a.cond.*, env));
                const cond_bool = try self.toBool(cond);

                if (!cond_bool) {
                    return error.AssertionFailed;
                }

                return try self.evalInEnv(a.body.*, env);
            },

            .binary_op => |b| {
                return try self.evalBinaryOp(b.op, b.left.*, b.right.*, env);
            },

            .unary_op => |u| {
                return try self.evalUnaryOp(u.op, u.operand.*, env);
            },
        }
    }

    fn evalBinaryOp(self: *Self, op: Expr.BinaryOperator, left: Expr, right: Expr, env: *Env) !Value {
        // Short-circuit operators: don't evaluate right side eagerly
        switch (op) {
            .and_op => {
                const lval = try self.force(try self.evalInEnv(left, env));
                const l = try self.toBool(lval);
                if (!l) return Value{ .bool = false };
                const rval = try self.force(try self.evalInEnv(right, env));
                return Value{ .bool = try self.toBool(rval) };
            },
            .or_op => {
                const lval = try self.force(try self.evalInEnv(left, env));
                const l = try self.toBool(lval);
                if (l) return Value{ .bool = true };
                const rval = try self.force(try self.evalInEnv(right, env));
                return Value{ .bool = try self.toBool(rval) };
            },
            .implies => {
                const lval = try self.force(try self.evalInEnv(left, env));
                const l = try self.toBool(lval);
                if (!l) return Value{ .bool = true };
                const rval = try self.force(try self.evalInEnv(right, env));
                return Value{ .bool = try self.toBool(rval) };
            },
            else => {},
        }

        const lval = try self.force(try self.evalInEnv(left, env));
        const rval = try self.force(try self.evalInEnv(right, env));

        switch (op) {
            .add => {
                if (lval == .int and rval == .int) {
                    return Value{ .int = lval.int + rval.int };
                }
                if (lval == .float or rval == .float) {
                    const l = if (lval == .int) @as(f64, @floatFromInt(lval.int)) else if (lval == .float) lval.float else return error.TypeError;
                    const r = if (rval == .int) @as(f64, @floatFromInt(rval.int)) else if (rval == .float) rval.float else return error.TypeError;
                    return Value{ .float = l + r };
                }
                // String concatenation
                if (lval == .string and rval == .string) {
                    const result = try std.mem.concat(self.alloc(), u8, &.{ lval.string, rval.string });
                    return Value{ .string = result };
                }
                // Path + string = path concatenation
                if (lval == .path and rval == .string) {
                    const result = try std.mem.concat(self.alloc(), u8, &.{ lval.path, rval.string });
                    return Value{ .path = result };
                }
                // String + path = string concatenation
                if (lval == .string and rval == .path) {
                    const result = try std.mem.concat(self.alloc(), u8, &.{ lval.string, rval.path });
                    return Value{ .string = result };
                }
                return error.TypeError;
            },
            .sub => {
                if (lval == .int and rval == .int) {
                    return Value{ .int = lval.int - rval.int };
                }
                if (lval == .float or rval == .float) {
                    const l = if (lval == .int) @as(f64, @floatFromInt(lval.int)) else lval.float;
                    const r = if (rval == .int) @as(f64, @floatFromInt(rval.int)) else rval.float;
                    return Value{ .float = l - r };
                }
                return error.TypeError;
            },
            .mul => {
                if (lval == .int and rval == .int) {
                    return Value{ .int = lval.int * rval.int };
                }
                if (lval == .float or rval == .float) {
                    const l = if (lval == .int) @as(f64, @floatFromInt(lval.int)) else lval.float;
                    const r = if (rval == .int) @as(f64, @floatFromInt(rval.int)) else rval.float;
                    return Value{ .float = l * r };
                }
                return error.TypeError;
            },
            .div => {
                if (lval == .int and rval == .int) {
                    if (rval.int == 0) return error.DivisionByZero;
                    return Value{ .int = @divTrunc(lval.int, rval.int) };
                }
                if (lval == .float or rval == .float) {
                    const l = if (lval == .int) @as(f64, @floatFromInt(lval.int)) else lval.float;
                    const r = if (rval == .int) @as(f64, @floatFromInt(rval.int)) else rval.float;
                    return Value{ .float = l / r };
                }
                return error.TypeError;
            },
            .concat => {
                if (lval == .list and rval == .list) {
                    const new_list = try self.alloc().alloc(Value, lval.list.len + rval.list.len);
                    @memcpy(new_list[0..lval.list.len], lval.list);
                    @memcpy(new_list[lval.list.len..], rval.list);
                    return Value{ .list = new_list };
                }
                return error.TypeError;
            },
            .update => {
                if (lval == .attrs and rval == .attrs) {
                    var new_bindings = std.StringHashMap(Value).init(self.alloc());
                    var iter = lval.attrs.bindings.iterator();
                    while (iter.next()) |entry| {
                        try new_bindings.put(entry.key_ptr.*, entry.value_ptr.*);
                    }
                    var iter2 = rval.attrs.bindings.iterator();
                    while (iter2.next()) |entry| {
                        try new_bindings.put(entry.key_ptr.*, entry.value_ptr.*);
                    }
                    return Value{ .attrs = .{ .bindings = new_bindings } };
                }
                return error.TypeError;
            },
            .eq => return Value{ .bool = try self.equal(lval, rval) },
            .neq => return Value{ .bool = !(try self.equal(lval, rval)) },
            .lt, .lte, .gt, .gte => {
                if (lval == .int and rval == .int) {
                    return Value{
                        .bool = switch (op) {
                            .lt => lval.int < rval.int,
                            .lte => lval.int <= rval.int,
                            .gt => lval.int > rval.int,
                            .gte => lval.int >= rval.int,
                            else => unreachable,
                        },
                    };
                }
                if (lval == .string and rval == .string) {
                    const order = std.mem.order(u8, lval.string, rval.string);
                    return Value{
                        .bool = switch (op) {
                            .lt => order == .lt,
                            .lte => order != .gt,
                            .gt => order == .gt,
                            .gte => order != .lt,
                            else => unreachable,
                        },
                    };
                }
                if (lval == .float or rval == .float) {
                    const l = if (lval == .int) @as(f64, @floatFromInt(lval.int)) else if (lval == .float) lval.float else return error.TypeError;
                    const r = if (rval == .int) @as(f64, @floatFromInt(rval.int)) else if (rval == .float) rval.float else return error.TypeError;
                    return Value{
                        .bool = switch (op) {
                            .lt => l < r,
                            .lte => l <= r,
                            .gt => l > r,
                            .gte => l >= r,
                            else => unreachable,
                        },
                    };
                }
                return error.TypeError;
            },
            .and_op, .or_op, .implies => unreachable, // handled above as short-circuit
            .has_attr => {
                // lval ? attr  - check if attrset has the attribute
                if (lval != .attrs) return Value{ .bool = false };
                if (rval == .string) {
                    return Value{ .bool = lval.attrs.bindings.contains(rval.string) };
                }
                if (rval == .list) {
                    // Multi-part attr path encoded as a list of strings
                    var current_set = lval.attrs;
                    for (rval.list, 0..) |part, i| {
                        const key = if (part == .string) part.string else return Value{ .bool = false };
                        if (current_set.bindings.get(key)) |val| {
                            if (i == rval.list.len - 1) return Value{ .bool = true };
                            const forced_val = try self.force(val);
                            if (forced_val != .attrs) return Value{ .bool = false };
                            current_set = forced_val.attrs;
                        } else {
                            return Value{ .bool = false };
                        }
                    }
                    return Value{ .bool = false };
                }
                return Value{ .bool = false };
            },
        }
    }

    fn evalUnaryOp(self: *Self, op: Expr.UnaryOperator, operand: Expr, env: *Env) !Value {
        const val = try self.force(try self.evalInEnv(operand, env));

        switch (op) {
            .not => {
                const b = try self.toBool(val);
                return Value{ .bool = !b };
            },
            .negate => {
                if (val == .int) {
                    return Value{ .int = -val.int };
                }
                if (val == .float) {
                    return Value{ .float = -val.float };
                }
                return error.TypeError;
            },
        }
    }

    pub fn force(self: *Self, value: Value) anyerror!Value {
        var current = value;
        while (current == .thunk) {
            const thunk = current.thunk;
            if (thunk.value) |val| {
                current = val;
                continue;
            }
            if (thunk.evaluating) {
                return error.InfiniteRecursion;
            }

            thunk.evaluating = true;
            const result = try self.evalInEnv(thunk.expr.*, thunk.env);
            thunk.value = result;
            thunk.evaluating = false;

            current = result;
        }
        return current;
    }

    /// Apply a function value to an argument
    pub fn apply(self: *Self, func: Value, arg: Value) anyerror!Value {
        const forced_func = try self.force(func);

        switch (forced_func) {
            .lambda => |lam| {
                const call_env = try self.createEnv(lam.env);

                switch (lam.param) {
                    .ident => |name| {
                        try call_env.define(name, arg);
                    },
                    .pattern => |p| {
                        const forced_arg = try self.force(arg);
                        if (forced_arg != .attrs) {
                            return error.PatternMatchFailed;
                        }

                        // Bind @name first so defaults can reference it
                        if (p.at_name) |at| {
                            try call_env.define(at, arg);
                        }

                        for (p.formals) |formal| {
                            if (forced_arg.attrs.bindings.get(formal.name)) |val| {
                                try call_env.define(formal.name, val);
                            } else if (formal.default) |def| {
                                const default_val = try self.evalInEnv(def.*, call_env);
                                try call_env.define(formal.name, default_val);
                            } else if (!p.ellipsis) {
                                return error.MissingAttribute;
                            }
                        }
                    },
                }

                return try self.evalInEnv(lam.body.*, call_env);
            },
            .builtin => |b| {
                const prev_args = b.partial_args orelse &[_]Value{};
                const total_args = prev_args.len + 1;

                if (total_args < b.arity) {
                    const new_partial = try self.alloc().alloc(Value, total_args);
                    @memcpy(new_partial[0..prev_args.len], prev_args);
                    new_partial[prev_args.len] = arg;
                    return Value{
                        .builtin = .{
                            .name = b.name,
                            .func = b.func,
                            .arity = b.arity,
                            .partial_args = new_partial,
                        },
                    };
                }

                const args = try self.alloc().alloc(Value, total_args);
                @memcpy(args[0..prev_args.len], prev_args);
                args[prev_args.len] = arg;
                for (args) |*a| {
                    a.* = try self.force(a.*);
                }
                return try b.func(self, self.io, self.alloc(), args);
            },
            else => return error.NotAFunction,
        }
    }

    fn toBool(self: *Self, value: Value) !bool {
        _ = self;
        return switch (value) {
            .bool => |b| b,
            .null_val => false,
            else => true,
        };
    }

    pub fn equal(self: *Self, lval: Value, rval: Value) !bool {
        _ = self;
        if (@intFromEnum(lval) != @intFromEnum(rval)) return false;

        return switch (lval) {
            .int => lval.int == rval.int,
            .float => lval.float == rval.float,
            .bool => lval.bool == rval.bool,
            .string => std.mem.eql(u8, lval.string, rval.string),
            .path => std.mem.eql(u8, lval.path, rval.path),
            .null_val => true,
            else => false,
        };
    }
};

test "evaluator basic" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var evaluator = try Evaluator.init(allocator, io);
    defer evaluator.deinit();

    // Test integer
    {
        const result = try evaluator.eval(Expr{ .int = 42 });
        try std.testing.expectEqual(@as(i64, 42), result.int);
    }

    // Test arithmetic
    {
        const left = try allocator.create(Expr);
        left.* = Expr{ .int = 10 };
        const right = try allocator.create(Expr);
        right.* = Expr{ .int = 5 };

        const expr = Expr{
            .binary_op = .{
                .op = .add,
                .left = left,
                .right = right,
                .span = .{ .start = 0, .end = 0, .line = 1, .column = 1 },
            },
        };
        defer expr.deinit(allocator);

        const result = try evaluator.eval(expr);
        try std.testing.expectEqual(@as(i64, 15), result.int);
    }
}
