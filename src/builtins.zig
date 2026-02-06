const std = @import("std");
const eval = @import("eval.zig");
const store = @import("store.zig");
const parser = @import("parser.zig");
const Io = std.Io;
const Dir = Io.Dir;

const Value = eval.Value;
const Env = eval.Env;
const Evaluator = eval.Evaluator;

pub fn registerBuiltins(env: *Env) !void {
    // Basic builtins
    try env.define("true", Value{ .bool = true });
    try env.define("false", Value{ .bool = false });
    try env.define("null", Value{ .null_val = {} });

    // Create builtins attrset
    var builtins_set = std.StringHashMap(Value).init(env.allocator);

    // Core type functions
    try builtins_set.put("toString", Value{ .builtin = .{ .name = "toString", .func = builtinToString } });
    try builtins_set.put("typeOf", Value{ .builtin = .{ .name = "typeOf", .func = builtinTypeOf } });
    try builtins_set.put("import", Value{ .builtin = .{ .name = "import", .func = builtinImport } });

    // List functions
    try builtins_set.put("length", Value{ .builtin = .{ .name = "length", .func = builtinLength } });
    try builtins_set.put("head", Value{ .builtin = .{ .name = "head", .func = builtinHead } });
    try builtins_set.put("tail", Value{ .builtin = .{ .name = "tail", .func = builtinTail } });
    try builtins_set.put("elemAt", Value{ .builtin = .{ .name = "elemAt", .func = builtinElemAt, .arity = 2 } });
    try builtins_set.put("map", Value{ .builtin = .{ .name = "map", .func = builtinMap, .arity = 2 } });
    try builtins_set.put("filter", Value{ .builtin = .{ .name = "filter", .func = builtinFilter, .arity = 2 } });
    try builtins_set.put("foldl'", Value{ .builtin = .{ .name = "foldl'", .func = builtinFoldl, .arity = 3 } });
    try builtins_set.put("concatLists", Value{ .builtin = .{ .name = "concatLists", .func = builtinConcatLists } });
    try builtins_set.put("genList", Value{ .builtin = .{ .name = "genList", .func = builtinGenList, .arity = 2 } });

    // Attrset functions
    try builtins_set.put("attrNames", Value{ .builtin = .{ .name = "attrNames", .func = builtinAttrNames } });
    try builtins_set.put("attrValues", Value{ .builtin = .{ .name = "attrValues", .func = builtinAttrValues } });
    try builtins_set.put("hasAttr", Value{ .builtin = .{ .name = "hasAttr", .func = builtinHasAttr, .arity = 2 } });
    try builtins_set.put("getAttr", Value{ .builtin = .{ .name = "getAttr", .func = builtinGetAttr, .arity = 2 } });
    try builtins_set.put("removeAttrs", Value{ .builtin = .{ .name = "removeAttrs", .func = builtinRemoveAttrs, .arity = 2 } });
    try builtins_set.put("listToAttrs", Value{ .builtin = .{ .name = "listToAttrs", .func = builtinListToAttrs } });
    try builtins_set.put("intersectAttrs", Value{ .builtin = .{ .name = "intersectAttrs", .func = builtinIntersectAttrs, .arity = 2 } });
    try builtins_set.put("mapAttrs", Value{ .builtin = .{ .name = "mapAttrs", .func = builtinMapAttrs, .arity = 2 } });

    // String functions
    try builtins_set.put("stringLength", Value{ .builtin = .{ .name = "stringLength", .func = builtinStringLength } });
    try builtins_set.put("substring", Value{ .builtin = .{ .name = "substring", .func = builtinSubstring, .arity = 3 } });
    try builtins_set.put("concatStrings", Value{ .builtin = .{ .name = "concatStrings", .func = builtinConcatStrings } });
    try builtins_set.put("concatStringsSep", Value{ .builtin = .{ .name = "concatStringsSep", .func = builtinConcatStringsSep, .arity = 2 } });
    try builtins_set.put("replaceStrings", Value{ .builtin = .{ .name = "replaceStrings", .func = builtinReplaceStrings, .arity = 3 } });
    try builtins_set.put("split", Value{ .builtin = .{ .name = "split", .func = builtinSplit, .arity = 2 } });

    // Comparison and logic
    try builtins_set.put("isNull", Value{ .builtin = .{ .name = "isNull", .func = builtinIsNull } });
    try builtins_set.put("isFunction", Value{ .builtin = .{ .name = "isFunction", .func = builtinIsFunction } });
    try builtins_set.put("isList", Value{ .builtin = .{ .name = "isList", .func = builtinIsList } });
    try builtins_set.put("isAttrs", Value{ .builtin = .{ .name = "isAttrs", .func = builtinIsAttrs } });
    try builtins_set.put("isString", Value{ .builtin = .{ .name = "isString", .func = builtinIsString } });
    try builtins_set.put("isInt", Value{ .builtin = .{ .name = "isInt", .func = builtinIsInt } });
    try builtins_set.put("isBool", Value{ .builtin = .{ .name = "isBool", .func = builtinIsBool } });
    try builtins_set.put("isPath", Value{ .builtin = .{ .name = "isPath", .func = builtinIsPath } });

    // System and derivation
    try builtins_set.put("currentSystem", Value{ .string = store.getCurrentSystem() });
    try builtins_set.put("derivation", Value{ .builtin = .{ .name = "derivation", .func = builtinDerivation } });
    try builtins_set.put("derivationStrict", Value{ .builtin = .{ .name = "derivationStrict", .func = builtinDerivation } });
    try builtins_set.put("placeholder", Value{ .builtin = .{ .name = "placeholder", .func = builtinPlaceholder } });

    // Path operations
    try builtins_set.put("pathExists", Value{ .builtin = .{ .name = "pathExists", .func = builtinPathExists } });
    try builtins_set.put("readFile", Value{ .builtin = .{ .name = "readFile", .func = builtinReadFile } });
    try builtins_set.put("readDir", Value{ .builtin = .{ .name = "readDir", .func = builtinReadDir } });
    try builtins_set.put("toPath", Value{ .builtin = .{ .name = "toPath", .func = builtinToPath } });
    try builtins_set.put("baseNameOf", Value{ .builtin = .{ .name = "baseNameOf", .func = builtinBaseNameOf } });
    try builtins_set.put("dirOf", Value{ .builtin = .{ .name = "dirOf", .func = builtinDirOf } });

    // Fetchers
    try builtins_set.put("fetchurl", Value{ .builtin = .{ .name = "fetchurl", .func = builtinFetchurl } });
    try builtins_set.put("fetchTarball", Value{ .builtin = .{ .name = "fetchTarball", .func = builtinFetchTarball } });
    try builtins_set.put("fetchGit", Value{ .builtin = .{ .name = "fetchGit", .func = builtinFetchGit } });

    // JSON
    try builtins_set.put("toJSON", Value{ .builtin = .{ .name = "toJSON", .func = builtinToJSON } });
    try builtins_set.put("fromJSON", Value{ .builtin = .{ .name = "fromJSON", .func = builtinFromJSON } });

    // Math
    try builtins_set.put("add", Value{ .builtin = .{ .name = "add", .func = builtinAdd, .arity = 2 } });
    try builtins_set.put("sub", Value{ .builtin = .{ .name = "sub", .func = builtinSub, .arity = 2 } });
    try builtins_set.put("mul", Value{ .builtin = .{ .name = "mul", .func = builtinMul, .arity = 2 } });
    try builtins_set.put("div", Value{ .builtin = .{ .name = "div", .func = builtinDiv, .arity = 2 } });

    // Misc
    try builtins_set.put("seq", Value{ .builtin = .{ .name = "seq", .func = builtinSeq, .arity = 2 } });
    try builtins_set.put("deepSeq", Value{ .builtin = .{ .name = "deepSeq", .func = builtinDeepSeq, .arity = 2 } });
    try builtins_set.put("trace", Value{ .builtin = .{ .name = "trace", .func = builtinTrace, .arity = 2 } });
    try builtins_set.put("throw", Value{ .builtin = .{ .name = "throw", .func = builtinThrow } });
    try builtins_set.put("abort", Value{ .builtin = .{ .name = "abort", .func = builtinAbort } });
    try builtins_set.put("tryEval", Value{ .builtin = .{ .name = "tryEval", .func = builtinTryEval } });

    // Additional builtins needed by nixpkgs lib
    try builtins_set.put("compareVersions", Value{ .builtin = .{ .name = "compareVersions", .func = builtinCompareVersions, .arity = 2 } });
    try builtins_set.put("splitVersion", Value{ .builtin = .{ .name = "splitVersion", .func = builtinSplitVersion } });
    try builtins_set.put("match", Value{ .builtin = .{ .name = "match", .func = builtinMatch, .arity = 2 } });
    try builtins_set.put("getEnv", Value{ .builtin = .{ .name = "getEnv", .func = builtinGetEnv } });
    try builtins_set.put("functionArgs", Value{ .builtin = .{ .name = "functionArgs", .func = builtinFunctionArgs } });
    try builtins_set.put("isFloat", Value{ .builtin = .{ .name = "isFloat", .func = builtinIsFloat } });
    try builtins_set.put("all", Value{ .builtin = .{ .name = "all", .func = builtinAll, .arity = 2 } });
    try builtins_set.put("any", Value{ .builtin = .{ .name = "any", .func = builtinAny, .arity = 2 } });
    try builtins_set.put("elem", Value{ .builtin = .{ .name = "elem", .func = builtinElem, .arity = 2 } });
    try builtins_set.put("sort", Value{ .builtin = .{ .name = "sort", .func = builtinSort, .arity = 2 } });
    try builtins_set.put("catAttrs", Value{ .builtin = .{ .name = "catAttrs", .func = builtinCatAttrs, .arity = 2 } });
    try builtins_set.put("concatMap", Value{ .builtin = .{ .name = "concatMap", .func = builtinConcatMap, .arity = 2 } });
    try builtins_set.put("lessThan", Value{ .builtin = .{ .name = "lessThan", .func = builtinLessThan, .arity = 2 } });
    try builtins_set.put("groupBy", Value{ .builtin = .{ .name = "groupBy", .func = builtinGroupBy, .arity = 2 } });
    try builtins_set.put("partition", Value{ .builtin = .{ .name = "partition", .func = builtinPartition, .arity = 2 } });
    try builtins_set.put("genericClosure", Value{ .builtin = .{ .name = "genericClosure", .func = builtinGenericClosure } });
    try builtins_set.put("zipAttrsWith", Value{ .builtin = .{ .name = "zipAttrsWith", .func = builtinZipAttrsWith, .arity = 2 } });
    try builtins_set.put("addErrorContext", Value{ .builtin = .{ .name = "addErrorContext", .func = builtinAddErrorContext, .arity = 2 } });
    try builtins_set.put("unsafeGetAttrPos", Value{ .builtin = .{ .name = "unsafeGetAttrPos", .func = builtinUnsafeGetAttrPos, .arity = 2 } });
    try builtins_set.put("unsafeDiscardStringContext", Value{ .builtin = .{ .name = "unsafeDiscardStringContext", .func = builtinUnsafeDiscardStringContext } });
    try builtins_set.put("hasContext", Value{ .builtin = .{ .name = "hasContext", .func = builtinHasContext } });
    try builtins_set.put("getContext", Value{ .builtin = .{ .name = "getContext", .func = builtinGetContext } });
    try builtins_set.put("parseDrvName", Value{ .builtin = .{ .name = "parseDrvName", .func = builtinParseDrvName } });
    try builtins_set.put("warn", Value{ .builtin = .{ .name = "warn", .func = builtinWarn, .arity = 2 } });
    try builtins_set.put("readFileType", Value{ .builtin = .{ .name = "readFileType", .func = builtinReadFileType } });
    try builtins_set.put("storeDir", Value{ .string = "/nix/store" });
    try builtins_set.put("nixVersion", Value{ .string = "2.24.0" });
    try builtins_set.put("langVersion", Value{ .int = 6 });
    try builtins_set.put("currentSystem", Value{ .string = store.getCurrentSystem() });

    // Also put common builtins at top level for convenience
    // These are the primops that Nix exposes in the global scope (not just via builtins.*)
    try env.define("toString", Value{ .builtin = .{ .name = "toString", .func = builtinToString } });
    try env.define("typeOf", Value{ .builtin = .{ .name = "typeOf", .func = builtinTypeOf } });
    try env.define("import", Value{ .builtin = .{ .name = "import", .func = builtinImport } });
    try env.define("derivation", Value{ .builtin = .{ .name = "derivation", .func = builtinDerivation } });
    try env.define("derivationStrict", Value{ .builtin = .{ .name = "derivationStrict", .func = builtinDerivation } });
    try env.define("abort", Value{ .builtin = .{ .name = "abort", .func = builtinAbort } });
    try env.define("throw", Value{ .builtin = .{ .name = "throw", .func = builtinThrow } });
    try env.define("removeAttrs", Value{ .builtin = .{ .name = "removeAttrs", .func = builtinRemoveAttrs, .arity = 2 } });
    try env.define("map", Value{ .builtin = .{ .name = "map", .func = builtinMap, .arity = 2 } });
    try env.define("baseNameOf", Value{ .builtin = .{ .name = "baseNameOf", .func = builtinBaseNameOf } });
    try env.define("dirOf", Value{ .builtin = .{ .name = "dirOf", .func = builtinDirOf } });
    try env.define("isNull", Value{ .builtin = .{ .name = "isNull", .func = builtinIsNull } });
    try env.define("placeholder", Value{ .builtin = .{ .name = "placeholder", .func = builtinPlaceholder } });
    try env.define("scopedImport", Value{ .builtin = .{ .name = "scopedImport", .func = builtinImport } }); // TODO: proper scopedImport
    try env.define("fetchTarball", Value{ .builtin = .{ .name = "fetchTarball", .func = builtinFetchTarball } });
    try env.define("fetchGit", Value{ .builtin = .{ .name = "fetchGit", .func = builtinFetchGit } });

    // Register builtins attrset
    try env.define("builtins", Value{ .attrs = .{ .bindings = builtins_set } });
}

fn builtinToString(eval_ctx: ?*eval.Evaluator, io: std.Io, allocator: std.mem.Allocator, args: []Value) !Value {
    _ = io;
    if (args.len != 1) return error.InvalidArgCount;
    const evaluator = eval_ctx orelse return error.TypeError;
    const arg = try evaluator.force(args[0]);

    switch (arg) {
        .int => |v| {
            const str = try std.fmt.allocPrint(allocator, "{}", .{v});
            return Value{ .string = str };
        },
        .float => |v| {
            const str = try std.fmt.allocPrint(allocator, "{d}", .{v});
            return Value{ .string = str };
        },
        .bool => |v| return Value{ .string = if (v) "true" else "false" },
        .string => |s| return Value{ .string = s },
        .path => |p| return Value{ .string = p },
        .null_val => return Value{ .string = "null" },
        else => return Value{ .string = "<value>" },
    }
}

fn builtinTypeOf(eval_ctx: ?*eval.Evaluator, io: std.Io, allocator: std.mem.Allocator, args: []Value) !Value {
    _ = io;
    _ = allocator;
    if (args.len != 1) return error.InvalidArgCount;
    const evaluator = eval_ctx orelse return error.TypeError;
    const val = try evaluator.force(args[0]);

    const type_name = switch (val) {
        .int => "int",
        .float => "float",
        .bool => "bool",
        .string => "string",
        .path => "path",
        .null_val => "null",
        .list => "list",
        .attrs => "set",
        .lambda => "lambda",
        .builtin => "lambda",
        .thunk => "thunk",
    };

    return Value{ .string = type_name };
}

fn builtinImport(eval_ctx: ?*Evaluator, io: std.Io, allocator: std.mem.Allocator, args: []Value) !Value {
    if (args.len != 1) return error.InvalidArgCount;

    const evaluator = eval_ctx orelse return error.NoEvaluatorContext;

    // Force the argument (may be a thunk from lazy var_ref)
    const forced_arg = try evaluator.force(args[0]);

    // Get the path to import
    const import_path = switch (forced_arg) {
        .path => |p| p,
        .string => |s| s,
        else => {
            std.debug.print("builtinImport: arg is {s}, not path/string\n", .{@tagName(forced_arg)});
            return error.TypeError;
        },
    };

    // Determine the actual file to read
    // If it's a directory, import default.nix from it
    var file_path: []const u8 = import_path;
    var free_file_path = false;

    const stat = Dir.statFile(.cwd(), io, import_path, .{}) catch null;

    if (stat == null) {
        // stat failed (path may not exist) - try import_path as-is
        file_path = import_path;
    } else if (stat) |st| {
        if (st.kind == .directory) {
            file_path = try std.fs.path.join(allocator, &.{ import_path, "default.nix" });
            free_file_path = true;
        } else {
            file_path = import_path;
        }
    }
    defer if (free_file_path) allocator.free(file_path);

    // Read the file
    const file = Dir.openFile(.cwd(), io, file_path, .{}) catch {
        return error.FileNotFound;
    };
    defer file.close(io);

    var read_buf: [8192]u8 = undefined;
    var reader = file.reader(io, &read_buf);

    // Parse the file
    var p = parser.Parser.init(allocator, &reader.interface, file_path) catch {
        return error.ParseError;
    };
    defer p.deinit();

    const expr = p.parseExpr() catch {
        return error.ParseError;
    };

    // Evaluate the expression in the global env
    return evaluator.eval(expr);
}

// ============== List functions ==============

fn builtinLength(eval_ctx: ?*eval.Evaluator, io: std.Io, allocator: std.mem.Allocator, args: []Value) !Value {
    _ = io;
    _ = allocator;
    if (args.len != 1) return error.InvalidArgCount;
    const evaluator = eval_ctx orelse return error.TypeError;
    const val = try evaluator.force(args[0]);
    if (val != .list) return error.TypeError;
    return Value{ .int = @intCast(val.list.len) };
}

fn builtinHead(eval_ctx: ?*eval.Evaluator, io: std.Io, allocator: std.mem.Allocator, args: []Value) !Value {
    _ = io;
    _ = allocator;
    if (args.len != 1) return error.InvalidArgCount;
    const evaluator = eval_ctx orelse return error.TypeError;
    const val = try evaluator.force(args[0]);
    if (val != .list) return error.TypeError;
    if (val.list.len == 0) return error.EmptyList;
    return val.list[0];
}

fn builtinTail(eval_ctx: ?*eval.Evaluator, io: std.Io, allocator: std.mem.Allocator, args: []Value) !Value {
    _ = io;
    _ = allocator;
    if (args.len != 1) return error.InvalidArgCount;
    const evaluator = eval_ctx orelse return error.TypeError;
    const val = try evaluator.force(args[0]);
    if (val != .list) return error.TypeError;
    if (val.list.len == 0) return error.EmptyList;
    return Value{ .list = val.list[1..] };
}

fn builtinElemAt(eval_ctx: ?*eval.Evaluator, io: std.Io, allocator: std.mem.Allocator, args: []Value) !Value {
    _ = io;
    _ = allocator;
    if (args.len != 2) return error.InvalidArgCount;
    const evaluator = eval_ctx orelse return error.TypeError;
    const list_val = try evaluator.force(args[0]);
    const idx_val = try evaluator.force(args[1]);
    if (list_val != .list) return error.TypeError;
    if (idx_val != .int) return error.TypeError;
    const idx: usize = @intCast(idx_val.int);
    if (idx >= list_val.list.len) return error.IndexOutOfBounds;
    return list_val.list[idx];
}

fn builtinMap(eval_ctx: ?*eval.Evaluator, io: std.Io, allocator: std.mem.Allocator, args: []Value) !Value {
    _ = io;
    if (args.len != 2) return error.InvalidArgCount;
    const evaluator = eval_ctx orelse return error.TypeError;
    const func = try evaluator.force(args[0]);
    const list_val = try evaluator.force(args[1]);
    if (list_val != .list) return error.TypeError;
    const list = list_val.list;
    var result = try allocator.alloc(Value, list.len);
    for (list, 0..) |item, i| {
        result[i] = try evaluator.apply(func, item);
    }
    return Value{ .list = result };
}

fn builtinFilter(eval_ctx: ?*eval.Evaluator, io: std.Io, allocator: std.mem.Allocator, args: []Value) !Value {
    _ = io;
    if (args.len != 2) return error.InvalidArgCount;
    const evaluator = eval_ctx orelse return error.TypeError;
    const func = try evaluator.force(args[0]);
    const list_val = try evaluator.force(args[1]);
    if (list_val != .list) return error.TypeError;
    const list = list_val.list;
    var result = std.ArrayList(Value).empty;
    defer result.deinit(allocator);
    for (list) |item| {
        const pred_result = try evaluator.apply(func, item);
        const forced = try evaluator.force(pred_result);
        if (forced == .bool and forced.bool) {
            try result.append(allocator, item);
        }
    }
    return Value{ .list = try result.toOwnedSlice(allocator) };
}

fn builtinFoldl(eval_ctx: ?*eval.Evaluator, io: std.Io, allocator: std.mem.Allocator, args: []Value) !Value {
    _ = io;
    _ = allocator;
    if (args.len != 3) return error.InvalidArgCount;
    const evaluator = eval_ctx orelse return error.TypeError;
    const func = try evaluator.force(args[0]);
    var acc = args[1];
    const list_val = try evaluator.force(args[2]);
    if (list_val != .list) return error.TypeError;
    for (list_val.list) |item| {
        // foldl' is strict in the accumulator
        acc = try evaluator.force(try evaluator.apply(func, acc));
        acc = try evaluator.apply(acc, item);
    }
    return acc;
}

fn builtinConcatLists(eval_ctx: ?*eval.Evaluator, io: std.Io, allocator: std.mem.Allocator, args: []Value) !Value {
    _ = io;
    if (args.len != 1) return error.InvalidArgCount;
    const evaluator = eval_ctx orelse return error.TypeError;
    const outer = try evaluator.force(args[0]);
    if (outer != .list) return error.TypeError;

    var total_len: usize = 0;
    for (outer.list) |inner_raw| {
        const inner = try evaluator.force(inner_raw);
        if (inner != .list) return error.TypeError;
        total_len += inner.list.len;
    }

    const result = try allocator.alloc(Value, total_len);
    var idx: usize = 0;
    for (outer.list) |inner_raw| {
        const inner = try evaluator.force(inner_raw);
        @memcpy(result[idx .. idx + inner.list.len], inner.list);
        idx += inner.list.len;
    }

    return Value{ .list = result };
}

fn builtinGenList(eval_ctx: ?*eval.Evaluator, io: std.Io, allocator: std.mem.Allocator, args: []Value) !Value {
    _ = io;
    if (args.len != 2) return error.InvalidArgCount;
    const evaluator = eval_ctx orelse return error.TypeError;
    const func = try evaluator.force(args[0]);
    const len_val = try evaluator.force(args[1]);
    if (len_val != .int) return error.TypeError;

    const len: usize = @intCast(len_val.int);
    const result = try allocator.alloc(Value, len);

    for (0..len) |i| {
        result[i] = try evaluator.apply(func, Value{ .int = @intCast(i) });
    }

    return Value{ .list = result };
}

// ============== Attrset functions ==============

fn builtinAttrNames(eval_ctx: ?*eval.Evaluator, io: std.Io, allocator: std.mem.Allocator, args: []Value) !Value {
    _ = io;
    if (args.len != 1) return error.InvalidArgCount;
    const evaluator = eval_ctx orelse return error.TypeError;
    const val = try evaluator.force(args[0]);
    if (val != .attrs) return error.TypeError;

    const attrs = val.attrs;
    const result = try allocator.alloc(Value, attrs.bindings.count());

    var i: usize = 0;
    var iter = attrs.bindings.iterator();
    while (iter.next()) |entry| {
        result[i] = Value{ .string = entry.key_ptr.* };
        i += 1;
    }

    return Value{ .list = result };
}

fn builtinAttrValues(eval_ctx: ?*eval.Evaluator, io: std.Io, allocator: std.mem.Allocator, args: []Value) !Value {
    _ = io;
    if (args.len != 1) return error.InvalidArgCount;
    const evaluator = eval_ctx orelse return error.TypeError;
    const val = try evaluator.force(args[0]);
    if (val != .attrs) return error.TypeError;

    const attrs = val.attrs;
    const result = try allocator.alloc(Value, attrs.bindings.count());

    var i: usize = 0;
    var iter = attrs.bindings.iterator();
    while (iter.next()) |entry| {
        result[i] = entry.value_ptr.*;
        i += 1;
    }

    return Value{ .list = result };
}

fn builtinHasAttr(eval_ctx: ?*eval.Evaluator, io: std.Io, allocator: std.mem.Allocator, args: []Value) !Value {
    _ = io;
    _ = allocator;
    if (args.len != 2) return error.InvalidArgCount;
    const evaluator = eval_ctx orelse return error.TypeError;
    const name = try evaluator.force(args[0]);
    const set = try evaluator.force(args[1]);
    if (name != .string) return error.TypeError;
    if (set != .attrs) return error.TypeError;

    const key = name.string;
    return Value{ .bool = set.attrs.bindings.contains(key) };
}

fn builtinGetAttr(eval_ctx: ?*eval.Evaluator, io: std.Io, allocator: std.mem.Allocator, args: []Value) !Value {
    _ = io;
    _ = allocator;
    if (args.len != 2) return error.InvalidArgCount;
    const evaluator = eval_ctx orelse return error.TypeError;
    const name = try evaluator.force(args[0]);
    const set = try evaluator.force(args[1]);
    if (name != .string) return error.TypeError;
    if (set != .attrs) return error.TypeError;

    const key = name.string;
    if (set.attrs.bindings.get(key)) |val| {
        return val;
    }
    return error.AttributeNotFound;
}

fn builtinRemoveAttrs(eval_ctx: ?*eval.Evaluator, io: std.Io, allocator: std.mem.Allocator, args: []Value) !Value {
    _ = io;
    if (args.len != 2) return error.InvalidArgCount;
    const evaluator = eval_ctx orelse return error.TypeError;
    const set = try evaluator.force(args[0]);
    const names = try evaluator.force(args[1]);
    if (set != .attrs) return error.TypeError;
    if (names != .list) return error.TypeError;

    var new_bindings = std.StringHashMap(Value).init(allocator);
    var iter = set.attrs.bindings.iterator();
    while (iter.next()) |entry| {
        var should_remove = false;
        for (names.list) |item_raw| {
            const item = try evaluator.force(item_raw);
            if (item == .string and std.mem.eql(u8, item.string, entry.key_ptr.*)) {
                should_remove = true;
                break;
            }
        }
        if (!should_remove) {
            try new_bindings.put(entry.key_ptr.*, entry.value_ptr.*);
        }
    }

    return Value{ .attrs = .{ .bindings = new_bindings } };
}

fn builtinListToAttrs(eval_ctx: ?*eval.Evaluator, io: std.Io, allocator: std.mem.Allocator, args: []Value) !Value {
    _ = io;
    if (args.len != 1) return error.InvalidArgCount;
    const evaluator = eval_ctx orelse return error.TypeError;
    const list_val = try evaluator.force(args[0]);
    if (list_val != .list) return error.TypeError;

    var bindings = std.StringHashMap(Value).init(allocator);

    for (list_val.list) |item| {
        const forced_item = try evaluator.force(item);
        if (forced_item != .attrs) return error.TypeError;
        const name_val = forced_item.attrs.bindings.get("name") orelse return error.MissingAttribute;
        const value = forced_item.attrs.bindings.get("value") orelse return error.MissingAttribute;
        const name = try evaluator.force(name_val);
        if (name != .string) return error.TypeError;
        try bindings.put(name.string, value);
    }

    return Value{ .attrs = .{ .bindings = bindings } };
}

fn builtinIntersectAttrs(eval_ctx: ?*eval.Evaluator, io: std.Io, allocator: std.mem.Allocator, args: []Value) !Value {
    _ = io;
    if (args.len != 2) return error.InvalidArgCount;
    const evaluator = eval_ctx orelse return error.TypeError;
    const a = try evaluator.force(args[0]);
    const b = try evaluator.force(args[1]);
    if (a != .attrs) return error.TypeError;
    if (b != .attrs) return error.TypeError;

    var bindings = std.StringHashMap(Value).init(allocator);
    var iter = b.attrs.bindings.iterator();
    while (iter.next()) |entry| {
        if (a.attrs.bindings.contains(entry.key_ptr.*)) {
            try bindings.put(entry.key_ptr.*, entry.value_ptr.*);
        }
    }

    return Value{ .attrs = .{ .bindings = bindings } };
}

fn builtinMapAttrs(eval_ctx: ?*eval.Evaluator, io: std.Io, allocator: std.mem.Allocator, args: []Value) !Value {
    _ = io;
    if (args.len != 2) return error.InvalidArgCount;
    const evaluator = eval_ctx orelse return error.TypeError;
    const func = try evaluator.force(args[0]);
    const set = try evaluator.force(args[1]);
    if (set != .attrs) return error.TypeError;

    var result = std.StringHashMap(Value).init(allocator);
    var iter = set.attrs.bindings.iterator();
    while (iter.next()) |entry| {
        const applied = try evaluator.apply(func, Value{ .string = entry.key_ptr.* });
        const val = try evaluator.apply(applied, entry.value_ptr.*);
        try result.put(entry.key_ptr.*, val);
    }

    return Value{ .attrs = .{ .bindings = result } };
}

// ============== String functions ==============

fn builtinStringLength(eval_ctx: ?*eval.Evaluator, io: std.Io, allocator: std.mem.Allocator, args: []Value) !Value {
    _ = io;
    _ = allocator;
    if (args.len != 1) return error.InvalidArgCount;
    const evaluator = eval_ctx orelse return error.TypeError;
    const val = try evaluator.force(args[0]);
    if (val != .string) return error.TypeError;
    return Value{ .int = @intCast(val.string.len) };
}

fn builtinSubstring(eval_ctx: ?*eval.Evaluator, io: std.Io, allocator: std.mem.Allocator, args: []Value) !Value {
    _ = io;
    if (args.len != 3) return error.InvalidArgCount;
    const evaluator = eval_ctx orelse return error.TypeError;
    const start_val = try evaluator.force(args[0]);
    const len_val = try evaluator.force(args[1]);
    const str_val = try evaluator.force(args[2]);
    if (start_val != .int) return error.TypeError;
    if (len_val != .int) return error.TypeError;
    if (str_val != .string) return error.TypeError;

    const start: usize = @intCast(@max(0, start_val.int));
    const len: usize = @intCast(@max(0, len_val.int));
    const str = str_val.string;

    if (start >= str.len) return Value{ .string = "" };
    const end = @min(start + len, str.len);

    return Value{ .string = try allocator.dupe(u8, str[start..end]) };
}

fn builtinConcatStrings(eval_ctx: ?*eval.Evaluator, io: std.Io, allocator: std.mem.Allocator, args: []Value) !Value {
    _ = io;
    if (args.len != 1) return error.InvalidArgCount;
    const evaluator = eval_ctx orelse return error.TypeError;
    const list_val = try evaluator.force(args[0]);
    if (list_val != .list) return error.TypeError;

    var total_len: usize = 0;
    for (list_val.list) |item_raw| {
        const item = try evaluator.force(item_raw);
        if (item != .string) return error.TypeError;
        total_len += item.string.len;
    }

    const result = try allocator.alloc(u8, total_len);
    var idx: usize = 0;
    for (list_val.list) |item_raw| {
        const item = try evaluator.force(item_raw);
        @memcpy(result[idx .. idx + item.string.len], item.string);
        idx += item.string.len;
    }

    return Value{ .string = result };
}

fn builtinConcatStringsSep(eval_ctx: ?*eval.Evaluator, io: std.Io, allocator: std.mem.Allocator, args: []Value) !Value {
    _ = io;
    if (args.len != 2) return error.InvalidArgCount;
    const evaluator = eval_ctx orelse return error.TypeError;
    const sep_val = try evaluator.force(args[0]);
    const list_val = try evaluator.force(args[1]);
    if (sep_val != .string) return error.TypeError;
    if (list_val != .list) return error.TypeError;

    const sep = sep_val.string;
    const list = list_val.list;

    if (list.len == 0) return Value{ .string = "" };

    var total_len: usize = sep.len * (list.len - 1);
    for (list) |item_raw| {
        const item = try evaluator.force(item_raw);
        if (item != .string) return error.TypeError;
        total_len += item.string.len;
    }

    const result = try allocator.alloc(u8, total_len);
    var idx: usize = 0;

    for (list, 0..) |item_raw, i| {
        const item = try evaluator.force(item_raw);
        if (i > 0) {
            @memcpy(result[idx .. idx + sep.len], sep);
            idx += sep.len;
        }
        @memcpy(result[idx .. idx + item.string.len], item.string);
        idx += item.string.len;
    }

    return Value{ .string = result };
}

fn builtinReplaceStrings(eval_ctx: ?*eval.Evaluator, io: std.Io, allocator: std.mem.Allocator, args: []Value) !Value {
    _ = io;
    if (args.len != 3) return error.InvalidArgCount;
    const evaluator = eval_ctx orelse return error.TypeError;
    const from_list = try evaluator.force(args[0]);
    const to_list = try evaluator.force(args[1]);
    const str_val = try evaluator.force(args[2]);
    if (from_list != .list) return error.TypeError;
    if (to_list != .list) return error.TypeError;
    if (str_val != .string) return error.TypeError;

    var result = try allocator.dupe(u8, str_val.string);

    for (from_list.list, 0..) |from_raw, i| {
        const from = try evaluator.force(from_raw);
        if (from != .string) return error.TypeError;
        if (i >= to_list.list.len) break;
        const to = try evaluator.force(to_list.list[i]);
        if (to != .string) return error.TypeError;

        // Simple replacement (could be more efficient)
        var new_result: std.ArrayList(u8) = .empty;
        var j: usize = 0;
        while (j < result.len) {
            if (j + from.string.len <= result.len and
                std.mem.eql(u8, result[j .. j + from.string.len], from.string))
            {
                try new_result.appendSlice(allocator, to.string);
                j += from.string.len;
            } else {
                try new_result.append(allocator, result[j]);
                j += 1;
            }
        }
        allocator.free(result);
        result = try new_result.toOwnedSlice(allocator);
    }

    return Value{ .string = result };
}

fn builtinSplit(eval_ctx: ?*eval.Evaluator, io: std.Io, allocator: std.mem.Allocator, args: []Value) !Value {
    _ = io;
    if (args.len != 2) return error.InvalidArgCount;
    const evaluator = eval_ctx orelse return error.TypeError;
    const sep_val = try evaluator.force(args[0]);
    const str_val = try evaluator.force(args[1]);
    if (sep_val != .string) return error.TypeError;
    if (str_val != .string) return error.TypeError;

    // Simplified split - not regex
    const sep = sep_val.string;
    const str = str_val.string;

    var parts: std.ArrayList(Value) = .empty;
    var iter = std.mem.splitSequence(u8, str, sep);
    while (iter.next()) |part| {
        try parts.append(allocator, Value{ .string = try allocator.dupe(u8, part) });
    }

    return Value{ .list = try parts.toOwnedSlice(allocator) };
}

// ============== Type checking functions ==============

fn builtinIsNull(eval_ctx: ?*eval.Evaluator, io: std.Io, allocator: std.mem.Allocator, args: []Value) !Value {
    _ = io;
    _ = allocator;
    if (args.len != 1) return error.InvalidArgCount;
    const evaluator = eval_ctx orelse return error.TypeError;
    const val = try evaluator.force(args[0]);
    return Value{ .bool = val == .null_val };
}

fn builtinIsFunction(eval_ctx: ?*eval.Evaluator, io: std.Io, allocator: std.mem.Allocator, args: []Value) !Value {
    _ = io;
    _ = allocator;
    if (args.len != 1) return error.InvalidArgCount;
    const evaluator = eval_ctx orelse return error.TypeError;
    const val = try evaluator.force(args[0]);
    return Value{ .bool = val == .lambda or val == .builtin };
}

fn builtinIsList(eval_ctx: ?*eval.Evaluator, io: std.Io, allocator: std.mem.Allocator, args: []Value) !Value {
    _ = io;
    _ = allocator;
    if (args.len != 1) return error.InvalidArgCount;
    const evaluator = eval_ctx orelse return error.TypeError;
    const val = try evaluator.force(args[0]);
    return Value{ .bool = val == .list };
}

fn builtinIsAttrs(eval_ctx: ?*eval.Evaluator, io: std.Io, allocator: std.mem.Allocator, args: []Value) !Value {
    _ = io;
    _ = allocator;
    if (args.len != 1) return error.InvalidArgCount;
    const evaluator = eval_ctx orelse return error.TypeError;
    const val = try evaluator.force(args[0]);
    return Value{ .bool = val == .attrs };
}

fn builtinIsString(eval_ctx: ?*eval.Evaluator, io: std.Io, allocator: std.mem.Allocator, args: []Value) !Value {
    _ = io;
    _ = allocator;
    if (args.len != 1) return error.InvalidArgCount;
    const evaluator = eval_ctx orelse return error.TypeError;
    const val = try evaluator.force(args[0]);
    return Value{ .bool = val == .string };
}

fn builtinIsInt(eval_ctx: ?*eval.Evaluator, io: std.Io, allocator: std.mem.Allocator, args: []Value) !Value {
    _ = io;
    _ = allocator;
    if (args.len != 1) return error.InvalidArgCount;
    const evaluator = eval_ctx orelse return error.TypeError;
    const val = try evaluator.force(args[0]);
    return Value{ .bool = val == .int };
}

fn builtinIsBool(eval_ctx: ?*eval.Evaluator, io: std.Io, allocator: std.mem.Allocator, args: []Value) !Value {
    _ = io;
    _ = allocator;
    if (args.len != 1) return error.InvalidArgCount;
    const evaluator = eval_ctx orelse return error.TypeError;
    const val = try evaluator.force(args[0]);
    return Value{ .bool = val == .bool };
}

fn builtinIsPath(eval_ctx: ?*eval.Evaluator, io: std.Io, allocator: std.mem.Allocator, args: []Value) !Value {
    _ = io;
    _ = allocator;
    if (args.len != 1) return error.InvalidArgCount;
    const evaluator = eval_ctx orelse return error.TypeError;
    const val = try evaluator.force(args[0]);
    return Value{ .bool = val == .path };
}

// ============== Derivation functions ==============

fn builtinDerivation(eval_ctx: ?*eval.Evaluator, io: std.Io, allocator: std.mem.Allocator, args: []Value) !Value {
    _ = io;
    if (args.len != 1) return error.InvalidArgCount;
    const evaluator = eval_ctx orelse return error.TypeError;
    const val = try evaluator.force(args[0]);
    if (val != .attrs) return error.TypeError;

    const input_attrs = val.attrs;

    // Extract required attributes
    const name_raw = input_attrs.bindings.get("name") orelse return error.MissingAttribute;
    const system_raw = input_attrs.bindings.get("system") orelse return error.MissingAttribute;
    const builder_raw = input_attrs.bindings.get("builder") orelse return error.MissingAttribute;

    const name = try evaluator.force(name_raw);
    const system = try evaluator.force(system_raw);
    const builder = try evaluator.force(builder_raw);

    if (name != .string) return error.TypeError;
    if (system != .string) return error.TypeError;
    if (builder != .string and builder != .path) return error.TypeError;

    // Create derivation
    var drv = store.Derivation.init(allocator);
    drv.name = name.string;
    drv.system = system.string;
    drv.builder = if (builder == .string) builder.string else builder.path;

    // Extract args if present
    if (input_attrs.bindings.get("args")) |args_val| {
        if (args_val == .list) {
            const drv_args = try allocator.alloc([]const u8, args_val.list.len);
            for (args_val.list, 0..) |arg, i| {
                if (arg == .string) {
                    drv_args[i] = arg.string;
                } else {
                    drv_args[i] = "";
                }
            }
            drv.args = drv_args;
        }
    }

    // Compute store path
    const store_path = try drv.computeStorePath(allocator);
    const out_path = try store_path.toPath(allocator);

    // Build result attrset
    var result_bindings = std.StringHashMap(Value).init(allocator);
    try result_bindings.put("type", Value{ .string = "derivation" });
    try result_bindings.put("name", name);
    try result_bindings.put("system", system);
    try result_bindings.put("builder", builder);
    try result_bindings.put("outPath", Value{ .path = out_path });
    try result_bindings.put("drvPath", Value{ .path = out_path });

    // Copy through other attributes
    var iter = input_attrs.bindings.iterator();
    while (iter.next()) |entry| {
        if (!result_bindings.contains(entry.key_ptr.*)) {
            try result_bindings.put(entry.key_ptr.*, entry.value_ptr.*);
        }
    }

    return Value{ .attrs = .{ .bindings = result_bindings } };
}

fn builtinPlaceholder(eval_ctx: ?*eval.Evaluator, io: std.Io, allocator: std.mem.Allocator, args: []Value) !Value {
    _ = io;
    if (args.len != 1) return error.InvalidArgCount;
    const evaluator = eval_ctx orelse return error.TypeError;
    const val = try evaluator.force(args[0]);
    if (val != .string) return error.TypeError;
    // Return a placeholder string that will be replaced during build
    return Value{ .string = try std.fmt.allocPrint(allocator, "/nix/store/placeholder-{s}", .{val.string}) };
}

// ============== Path functions ==============
// NOTE: Path functions are currently stubbed as they require IO handle
// which the builtins API doesn't support yet

fn builtinPathExists(eval_ctx: ?*eval.Evaluator, io: std.Io, allocator: std.mem.Allocator, args: []Value) !Value {
    _ = io;
    _ = allocator;
    if (args.len != 1) return error.InvalidArgCount;
    const evaluator = eval_ctx orelse return error.TypeError;
    const val = try evaluator.force(args[0]);
    _ = switch (val) {
        .path => |p| p,
        .string => |s| s,
        else => return error.TypeError,
    };

    // TODO: Implement with proper IO handle
    return Value{ .bool = false };
}

fn builtinReadFile(eval_ctx: ?*eval.Evaluator, io: std.Io, allocator: std.mem.Allocator, args: []Value) !Value {
    if (args.len != 1) return error.InvalidArgCount;
    const evaluator = eval_ctx orelse return error.TypeError;
    const val = try evaluator.force(args[0]);
    const path = switch (val) {
        .path => |p| p,
        .string => |s| s,
        else => return error.TypeError,
    };

    const file = Dir.openFile(.cwd(), io, path, .{}) catch return error.FileNotFound;
    defer file.close(io);

    const len = file.length(io) catch return error.FileNotFound;
    var read_buf: [8192]u8 = undefined;
    var reader = file.reader(io, &read_buf);
    const contents = reader.interface.readAlloc(allocator, @intCast(len)) catch return error.FileNotFound;
    return Value{ .string = contents };
}

fn builtinReadDir(eval_ctx: ?*eval.Evaluator, io: std.Io, allocator: std.mem.Allocator, args: []Value) !Value {
    if (args.len != 1) return error.InvalidArgCount;
    const evaluator = eval_ctx orelse return error.TypeError;
    const val = try evaluator.force(args[0]);
    const path = switch (val) {
        .path => |p| p,
        .string => |s| s,
        else => return error.TypeError,
    };

    var dir = Dir.openDir(.cwd(), io, path, .{ .iterate = true }) catch return Value{ .attrs = .{ .bindings = std.StringHashMap(Value).init(allocator) } };
    defer dir.close(io);

    var bindings = std.StringHashMap(Value).init(allocator);
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        const name = try allocator.dupe(u8, entry.name);
        const file_type: []const u8 = switch (entry.kind) {
            .directory => "directory",
            .sym_link => "symlink",
            else => "regular",
        };
        try bindings.put(name, Value{ .string = file_type });
    }
    return Value{ .attrs = .{ .bindings = bindings } };
}

fn builtinToPath(eval_ctx: ?*eval.Evaluator, io: std.Io, allocator: std.mem.Allocator, args: []Value) !Value {
    _ = io;
    _ = allocator;
    if (args.len != 1) return error.InvalidArgCount;
    const evaluator = eval_ctx orelse return error.TypeError;
    const val = try evaluator.force(args[0]);
    if (val != .string) return error.TypeError;
    return Value{ .path = val.string };
}

fn builtinBaseNameOf(eval_ctx: ?*eval.Evaluator, io: std.Io, allocator: std.mem.Allocator, args: []Value) !Value {
    _ = io;
    _ = allocator;
    if (args.len != 1) return error.InvalidArgCount;
    const evaluator = eval_ctx orelse return error.TypeError;
    const val = try evaluator.force(args[0]);
    const path = switch (val) {
        .path => |p| p,
        .string => |s| s,
        else => return error.TypeError,
    };

    const basename = std.fs.path.basename(path);
    return Value{ .string = basename };
}

fn builtinDirOf(eval_ctx: ?*eval.Evaluator, io: std.Io, allocator: std.mem.Allocator, args: []Value) !Value {
    _ = io;
    if (args.len != 1) return error.InvalidArgCount;
    const evaluator = eval_ctx orelse return error.TypeError;
    const val = try evaluator.force(args[0]);
    const path = switch (val) {
        .path => |p| p,
        .string => |s| s,
        else => return error.TypeError,
    };

    const dirname = std.fs.path.dirname(path) orelse ".";
    return Value{ .path = try allocator.dupe(u8, dirname) };
}

// ============== JSON functions ==============

fn builtinToJSON(eval_ctx: ?*eval.Evaluator, io: std.Io, allocator: std.mem.Allocator, args: []Value) !Value {
    _ = io;
    if (args.len != 1) return error.InvalidArgCount;
    const evaluator = eval_ctx orelse return error.TypeError;
    const val = try evaluator.force(args[0]);

    var result: std.ArrayList(u8) = .empty;
    try valueToJson(allocator, val, &result);

    return Value{ .string = try result.toOwnedSlice(allocator) };
}

fn valueToJson(allocator: std.mem.Allocator, value: Value, result: *std.ArrayList(u8)) !void {
    switch (value) {
        .null_val => try result.appendSlice(allocator, "null"),
        .bool => |b| try result.appendSlice(allocator, if (b) "true" else "false"),
        .int => |i| {
            var buf: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{}", .{i}) catch unreachable;
            try result.appendSlice(allocator, s);
        },
        .float => |f| {
            var buf: [64]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d}", .{f}) catch unreachable;
            try result.appendSlice(allocator, s);
        },
        .string, .path => |s| {
            try result.append(allocator, '"');
            for (s) |c| {
                switch (c) {
                    '"' => try result.appendSlice(allocator, "\\\""),
                    '\\' => try result.appendSlice(allocator, "\\\\"),
                    '\n' => try result.appendSlice(allocator, "\\n"),
                    '\r' => try result.appendSlice(allocator, "\\r"),
                    '\t' => try result.appendSlice(allocator, "\\t"),
                    else => try result.append(allocator, c),
                }
            }
            try result.append(allocator, '"');
        },
        .list => |l| {
            try result.append(allocator, '[');
            for (l, 0..) |item, i| {
                if (i > 0) try result.append(allocator, ',');
                try valueToJson(allocator, item, result);
            }
            try result.append(allocator, ']');
        },
        .attrs => |a| {
            try result.append(allocator, '{');
            var iter = a.bindings.iterator();
            var first = true;
            while (iter.next()) |entry| {
                if (!first) try result.append(allocator, ',');
                first = false;
                try result.append(allocator, '"');
                try result.appendSlice(allocator, entry.key_ptr.*);
                try result.appendSlice(allocator, "\":");
                try valueToJson(allocator, entry.value_ptr.*, result);
            }
            try result.append(allocator, '}');
        },
        .lambda, .builtin, .thunk => try result.appendSlice(allocator, "null"),
    }
}

fn builtinFromJSON(eval_ctx: ?*eval.Evaluator, io: std.Io, allocator: std.mem.Allocator, args: []Value) !Value {
    _ = io;
    if (args.len != 1) return error.InvalidArgCount;
    const evaluator = eval_ctx orelse return error.TypeError;
    const val = try evaluator.force(args[0]);
    if (val != .string) return error.TypeError;

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, val.string, .{});
    defer parsed.deinit();

    return try jsonToValue(allocator, parsed.value);
}

fn jsonToValue(allocator: std.mem.Allocator, json: std.json.Value) !Value {
    return switch (json) {
        .null => Value{ .null_val = {} },
        .bool => |b| Value{ .bool = b },
        .integer => |i| Value{ .int = i },
        .float => |f| Value{ .float = f },
        .string => |s| Value{ .string = try allocator.dupe(u8, s) },
        .array => |arr| {
            const values = try allocator.alloc(Value, arr.items.len);
            for (arr.items, 0..) |item, i| {
                values[i] = try jsonToValue(allocator, item);
            }
            return Value{ .list = values };
        },
        .object => |obj| {
            var bindings = std.StringHashMap(Value).init(allocator);
            var iter = obj.iterator();
            while (iter.next()) |entry| {
                try bindings.put(
                    try allocator.dupe(u8, entry.key_ptr.*),
                    try jsonToValue(allocator, entry.value_ptr.*),
                );
            }
            return Value{ .attrs = .{ .bindings = bindings } };
        },
        else => Value{ .null_val = {} },
    };
}

// ============== Math functions ==============

fn builtinAdd(eval_ctx: ?*eval.Evaluator, io: std.Io, allocator: std.mem.Allocator, args: []Value) !Value {
    _ = io;
    _ = allocator;
    if (args.len != 2) return error.InvalidArgCount;
    const evaluator = eval_ctx orelse return error.TypeError;
    const a = try evaluator.force(args[0]);
    const b = try evaluator.force(args[1]);
    if (a == .int and b == .int) {
        return Value{ .int = a.int + b.int };
    }
    return error.TypeError;
}

fn builtinSub(eval_ctx: ?*eval.Evaluator, io: std.Io, allocator: std.mem.Allocator, args: []Value) !Value {
    _ = io;
    _ = allocator;
    if (args.len != 2) return error.InvalidArgCount;
    const evaluator = eval_ctx orelse return error.TypeError;
    const a = try evaluator.force(args[0]);
    const b = try evaluator.force(args[1]);
    if (a == .int and b == .int) {
        return Value{ .int = a.int - b.int };
    }
    return error.TypeError;
}

fn builtinMul(eval_ctx: ?*eval.Evaluator, io: std.Io, allocator: std.mem.Allocator, args: []Value) !Value {
    _ = io;
    _ = allocator;
    if (args.len != 2) return error.InvalidArgCount;
    const evaluator = eval_ctx orelse return error.TypeError;
    const a = try evaluator.force(args[0]);
    const b = try evaluator.force(args[1]);
    if (a == .int and b == .int) {
        return Value{ .int = a.int * b.int };
    }
    return error.TypeError;
}

fn builtinDiv(eval_ctx: ?*eval.Evaluator, io: std.Io, allocator: std.mem.Allocator, args: []Value) !Value {
    _ = io;
    _ = allocator;
    if (args.len != 2) return error.InvalidArgCount;
    const evaluator = eval_ctx orelse return error.TypeError;
    const a = try evaluator.force(args[0]);
    const b = try evaluator.force(args[1]);
    if (a == .int and b == .int) {
        if (b.int == 0) return error.DivisionByZero;
        return Value{ .int = @divTrunc(a.int, b.int) };
    }
    return error.TypeError;
}

// ============== Misc functions ==============

fn builtinSeq(eval_ctx: ?*eval.Evaluator, io: std.Io, allocator: std.mem.Allocator, args: []Value) !Value {
    _ = io;
    _ = allocator;
    if (args.len != 2) return error.InvalidArgCount;
    const evaluator = eval_ctx orelse return error.TypeError;
    // seq forces evaluation of first arg, then returns second
    _ = try evaluator.force(args[0]);
    return args[1];
}

fn builtinDeepSeq(eval_ctx: ?*eval.Evaluator, io: std.Io, allocator: std.mem.Allocator, args: []Value) !Value {
    _ = io;
    _ = allocator;
    if (args.len != 2) return error.InvalidArgCount;
    const evaluator = eval_ctx orelse return error.TypeError;
    // Deep-force first arg, then return second
    _ = try evaluator.force(args[0]);
    return args[1];
}

fn builtinTrace(eval_ctx: ?*eval.Evaluator, io: std.Io, allocator: std.mem.Allocator, args: []Value) !Value {
    _ = io;
    _ = allocator;
    if (args.len != 2) return error.InvalidArgCount;
    const evaluator = eval_ctx orelse return error.TypeError;
    const msg = try evaluator.force(args[0]);

    // Print the trace message
    switch (msg) {
        .string => |s| std.debug.print("trace: {s}\n", .{s}),
        else => std.debug.print("trace: {any}\n", .{msg}),
    }

    return args[1];
}

fn builtinThrow(eval_ctx: ?*eval.Evaluator, io: std.Io, allocator: std.mem.Allocator, args: []Value) !Value {
    _ = io;
    _ = allocator;
    if (args.len != 1) return error.InvalidArgCount;
    const evaluator = eval_ctx orelse return error.TypeError;
    const val = try evaluator.force(args[0]);
    if (val != .string) return error.TypeError;

    std.debug.print("error: {s}\n", .{val.string});
    return error.ThrownError;
}

fn builtinAbort(eval_ctx: ?*eval.Evaluator, io: std.Io, allocator: std.mem.Allocator, args: []Value) !Value {
    _ = io;
    _ = allocator;
    if (args.len != 1) return error.InvalidArgCount;
    const evaluator = eval_ctx orelse return error.TypeError;
    const val = try evaluator.force(args[0]);
    if (val != .string) return error.TypeError;

    std.debug.print("abort: {s}\n", .{val.string});
    return error.Aborted;
}

fn builtinTryEval(eval_ctx: ?*eval.Evaluator, io: std.Io, allocator: std.mem.Allocator, args: []Value) !Value {
    _ = io;
    if (args.len != 1) return error.InvalidArgCount;
    const evaluator = eval_ctx orelse return error.TypeError;

    // Try to force the argument, catching evaluation errors
    const value = evaluator.force(args[0]) catch {
        var bindings = std.StringHashMap(Value).init(allocator);
        try bindings.put("success", Value{ .bool = false });
        try bindings.put("value", Value{ .bool = false });
        return Value{ .attrs = .{ .bindings = bindings } };
    };

    var bindings = std.StringHashMap(Value).init(allocator);
    try bindings.put("success", Value{ .bool = true });
    try bindings.put("value", value);

    return Value{ .attrs = .{ .bindings = bindings } };
}

fn builtinFetchurl(eval_ctx: ?*eval.Evaluator, io: std.Io, allocator: std.mem.Allocator, args: []Value) !Value {
    _ = eval_ctx;
    _ = io;
    _ = io;
    _ = allocator;
    if (args.len != 1) return error.InvalidArgCount;

    std.debug.print("TODO: fetchurl (stubbed)\n", .{});
    return Value{ .path = "/tmp/stub-fetchurl" };
}

fn builtinFetchTarball(eval_ctx: ?*eval.Evaluator, io: std.Io, allocator: std.mem.Allocator, args: []Value) !Value {
    _ = eval_ctx;
    _ = io;
    _ = io;
    _ = allocator;
    if (args.len != 1) return error.InvalidArgCount;

    std.debug.print("TODO: fetchTarball (stubbed)\n", .{});
    return Value{ .path = "/tmp/stub-fetchtarball" };
}

fn builtinFetchGit(eval_ctx: ?*eval.Evaluator, io: std.Io, allocator: std.mem.Allocator, args: []Value) !Value {
    _ = eval_ctx;
    _ = io;
    _ = io;
    _ = allocator;
    if (args.len != 1) return error.InvalidArgCount;

    std.debug.print("TODO: fetchGit (stubbed)\n", .{});
    return Value{ .path = "/tmp/stub-fetchgit" };
}

// ============== Additional builtins for nixpkgs lib ==============

fn builtinCompareVersions(eval_ctx: ?*eval.Evaluator, io: std.Io, allocator: std.mem.Allocator, args: []Value) !Value {
    _ = io;
    _ = allocator;
    if (args.len != 2) return error.InvalidArgCount;
    const evaluator = eval_ctx orelse return error.TypeError;
    const a_val = try evaluator.force(args[0]);
    const b_val = try evaluator.force(args[1]);
    if (a_val != .string or b_val != .string) return error.TypeError;
    const a = a_val.string;
    const b = b_val.string;

    // Simple version comparison: split by '.', compare each part
    var ai = std.mem.splitScalar(u8, a, '.');
    var bi = std.mem.splitScalar(u8, b, '.');

    while (true) {
        const ap = ai.next();
        const bp = bi.next();
        if (ap == null and bp == null) return Value{ .int = 0 };
        if (ap == null) return Value{ .int = -1 };
        if (bp == null) return Value{ .int = 1 };

        const an = std.fmt.parseInt(i64, ap.?, 10) catch 0;
        const bn = std.fmt.parseInt(i64, bp.?, 10) catch 0;
        if (an < bn) return Value{ .int = -1 };
        if (an > bn) return Value{ .int = 1 };
    }
}

fn builtinSplitVersion(eval_ctx: ?*eval.Evaluator, io: std.Io, allocator: std.mem.Allocator, args: []Value) !Value {
    _ = io;
    if (args.len != 1) return error.InvalidArgCount;
    const evaluator = eval_ctx orelse return error.TypeError;
    const val = try evaluator.force(args[0]);
    if (val != .string) return error.TypeError;

    var parts = std.ArrayList(Value).empty;
    defer parts.deinit(allocator);

    var iter = std.mem.splitScalar(u8, val.string, '.');
    while (iter.next()) |part| {
        try parts.append(allocator, Value{ .string = part });
    }

    return Value{ .list = try parts.toOwnedSlice(allocator) };
}

fn builtinMatch(eval_ctx: ?*eval.Evaluator, io: std.Io, allocator: std.mem.Allocator, args: []Value) !Value {
    _ = io;
    _ = allocator;
    if (args.len != 2) return error.InvalidArgCount;
    const evaluator = eval_ctx orelse return error.TypeError;
    _ = try evaluator.force(args[0]);
    _ = try evaluator.force(args[1]);
    // builtins.match regex string - stubbed, returns null (no match)
    return Value{ .null_val = {} };
}

fn builtinGetEnv(eval_ctx: ?*eval.Evaluator, io: std.Io, allocator: std.mem.Allocator, args: []Value) !Value {
    _ = io;
    _ = allocator;
    if (args.len != 1) return error.InvalidArgCount;
    const evaluator = eval_ctx orelse return error.TypeError;
    const val = try evaluator.force(args[0]);
    if (val != .string) return error.TypeError;
    // In pure evaluation mode, getEnv always returns ""
    return Value{ .string = "" };
}

fn builtinFunctionArgs(eval_ctx: ?*eval.Evaluator, io: std.Io, allocator: std.mem.Allocator, args: []Value) !Value {
    _ = io;
    if (args.len != 1) return error.InvalidArgCount;
    const evaluator = eval_ctx orelse return error.TypeError;
    const val = try evaluator.force(args[0]);
    var result = std.StringHashMap(Value).init(allocator);
    if (val == .lambda) {
        switch (val.lambda.param) {
            .pattern => |p| {
                for (p.formals) |formal| {
                    try result.put(formal.name, Value{ .bool = formal.default != null });
                }
            },
            .ident => {},
        }
    }
    return Value{ .attrs = .{ .bindings = result } };
}

fn builtinIsFloat(eval_ctx: ?*eval.Evaluator, io: std.Io, allocator: std.mem.Allocator, args: []Value) !Value {
    _ = io;
    _ = allocator;
    if (args.len != 1) return error.InvalidArgCount;
    const evaluator = eval_ctx orelse return error.TypeError;
    const val = try evaluator.force(args[0]);
    return Value{ .bool = val == .float };
}

fn builtinAll(eval_ctx: ?*eval.Evaluator, io: std.Io, allocator: std.mem.Allocator, args: []Value) !Value {
    _ = io;
    _ = allocator;
    if (args.len != 2) return error.InvalidArgCount;
    const evaluator = eval_ctx orelse return error.TypeError;
    const func = try evaluator.force(args[0]);
    const list_val = try evaluator.force(args[1]);
    if (list_val != .list) return error.TypeError;
    for (list_val.list) |item| {
        const r = try evaluator.force(try evaluator.apply(func, item));
        if (r == .bool and !r.bool) return Value{ .bool = false };
    }
    return Value{ .bool = true };
}

fn builtinAny(eval_ctx: ?*eval.Evaluator, io: std.Io, allocator: std.mem.Allocator, args: []Value) !Value {
    _ = io;
    _ = allocator;
    if (args.len != 2) return error.InvalidArgCount;
    const evaluator = eval_ctx orelse return error.TypeError;
    const func = try evaluator.force(args[0]);
    const list_val = try evaluator.force(args[1]);
    if (list_val != .list) return error.TypeError;
    for (list_val.list) |item| {
        const r = try evaluator.force(try evaluator.apply(func, item));
        if (r == .bool and r.bool) return Value{ .bool = true };
    }
    return Value{ .bool = false };
}

fn builtinElem(eval_ctx: ?*eval.Evaluator, io: std.Io, allocator: std.mem.Allocator, args: []Value) !Value {
    _ = io;
    _ = allocator;
    if (args.len != 2) return error.InvalidArgCount;
    const evaluator = eval_ctx orelse return error.TypeError;
    const target = try evaluator.force(args[0]);
    const list_val = try evaluator.force(args[1]);
    if (list_val != .list) return error.TypeError;
    for (list_val.list) |item| {
        const forced = try evaluator.force(item);
        if (try evaluator.equal(target, forced)) return Value{ .bool = true };
    }
    return Value{ .bool = false };
}

fn builtinSort(eval_ctx: ?*eval.Evaluator, io: std.Io, allocator: std.mem.Allocator, args: []Value) !Value {
    _ = io;
    if (args.len != 2) return error.InvalidArgCount;
    const evaluator = eval_ctx orelse return error.TypeError;
    const comparator = try evaluator.force(args[0]);
    const list_val = try evaluator.force(args[1]);
    if (list_val != .list) return error.TypeError;
    const list = list_val.list;

    // Copy the list for sorting
    const result = try allocator.alloc(Value, list.len);
    @memcpy(result, list);

    // Simple insertion sort (stable, works with Nix comparator)
    var i: usize = 1;
    while (i < result.len) : (i += 1) {
        const key = result[i];
        var j: usize = i;
        while (j > 0) {
            const cmp = try evaluator.apply(comparator, result[j - 1]);
            const cmp_result = try evaluator.force(try evaluator.apply(cmp, key));
            if (cmp_result == .bool and cmp_result.bool) break;
            result[j] = result[j - 1];
            j -= 1;
        }
        result[j] = key;
    }

    return Value{ .list = result };
}

fn builtinCatAttrs(eval_ctx: ?*eval.Evaluator, io: std.Io, allocator: std.mem.Allocator, args: []Value) !Value {
    _ = io;
    if (args.len != 2) return error.InvalidArgCount;
    const evaluator = eval_ctx orelse return error.TypeError;
    const name_val = try evaluator.force(args[0]);
    const list_val = try evaluator.force(args[1]);
    if (name_val != .string) return error.TypeError;
    if (list_val != .list) return error.TypeError;

    const attr_name = name_val.string;
    var result = std.ArrayList(Value).empty;
    defer result.deinit(allocator);

    for (list_val.list) |item| {
        const forced = try evaluator.force(item);
        if (forced == .attrs) {
            if (forced.attrs.bindings.get(attr_name)) |val| {
                try result.append(allocator, val);
            }
        }
    }

    return Value{ .list = try result.toOwnedSlice(allocator) };
}

fn builtinConcatMap(eval_ctx: ?*eval.Evaluator, io: std.Io, allocator: std.mem.Allocator, args: []Value) !Value {
    _ = io;
    if (args.len != 2) return error.InvalidArgCount;
    const evaluator = eval_ctx orelse return error.TypeError;
    const func = try evaluator.force(args[0]);
    const list_val = try evaluator.force(args[1]);
    if (list_val != .list) return error.TypeError;

    var result = std.ArrayList(Value).empty;
    defer result.deinit(allocator);

    for (list_val.list) |item| {
        const mapped = try evaluator.force(try evaluator.apply(func, item));
        if (mapped == .list) {
            for (mapped.list) |elem| {
                try result.append(allocator, elem);
            }
        } else {
            return error.TypeError;
        }
    }

    return Value{ .list = try result.toOwnedSlice(allocator) };
}

fn builtinLessThan(eval_ctx: ?*eval.Evaluator, io: std.Io, allocator: std.mem.Allocator, args: []Value) !Value {
    _ = io;
    _ = allocator;
    if (args.len != 2) return error.InvalidArgCount;
    const evaluator = eval_ctx orelse return error.TypeError;
    const a = try evaluator.force(args[0]);
    const b = try evaluator.force(args[1]);
    if (a == .int and b == .int) {
        return Value{ .bool = a.int < b.int };
    }
    return error.TypeError;
}

fn builtinGroupBy(eval_ctx: ?*eval.Evaluator, io: std.Io, allocator: std.mem.Allocator, args: []Value) !Value {
    _ = io;
    if (args.len != 2) return error.InvalidArgCount;
    const evaluator = eval_ctx orelse return error.TypeError;
    const func = try evaluator.force(args[0]);
    const list_val = try evaluator.force(args[1]);
    if (list_val != .list) return error.TypeError;

    var groups = std.StringHashMap(std.ArrayList(Value)).init(allocator);
    defer {
        var it = groups.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        groups.deinit();
    }

    for (list_val.list) |item| {
        const key_val = try evaluator.force(try evaluator.apply(func, item));
        if (key_val != .string) return error.TypeError;
        const gop = try groups.getOrPut(key_val.string);
        if (!gop.found_existing) {
            gop.value_ptr.* = std.ArrayList(Value).empty;
        }
        try gop.value_ptr.append(allocator, item);
    }

    var result = std.StringHashMap(Value).init(allocator);
    var it = groups.iterator();
    while (it.next()) |entry| {
        try result.put(entry.key_ptr.*, Value{ .list = try entry.value_ptr.toOwnedSlice(allocator) });
    }

    return Value{ .attrs = .{ .bindings = result } };
}

fn builtinPartition(eval_ctx: ?*eval.Evaluator, io: std.Io, allocator: std.mem.Allocator, args: []Value) !Value {
    _ = io;
    if (args.len != 2) return error.InvalidArgCount;
    const evaluator = eval_ctx orelse return error.TypeError;
    const func = try evaluator.force(args[0]);
    const list_val = try evaluator.force(args[1]);
    if (list_val != .list) return error.TypeError;

    var right_list = std.ArrayList(Value).empty;
    defer right_list.deinit(allocator);
    var wrong_list = std.ArrayList(Value).empty;
    defer wrong_list.deinit(allocator);

    for (list_val.list) |item| {
        const r = try evaluator.force(try evaluator.apply(func, item));
        if (r == .bool and r.bool) {
            try right_list.append(allocator, item);
        } else {
            try wrong_list.append(allocator, item);
        }
    }

    var result = std.StringHashMap(Value).init(allocator);
    try result.put("right", Value{ .list = try right_list.toOwnedSlice(allocator) });
    try result.put("wrong", Value{ .list = try wrong_list.toOwnedSlice(allocator) });
    return Value{ .attrs = .{ .bindings = result } };
}

fn builtinGenericClosure(eval_ctx: ?*eval.Evaluator, io: std.Io, allocator: std.mem.Allocator, args: []Value) !Value {
    _ = io;
    if (args.len != 1) return error.InvalidArgCount;
    const evaluator = eval_ctx orelse return error.TypeError;
    const val = try evaluator.force(args[0]);
    if (val != .attrs) return error.TypeError;

    const start_set_val = val.attrs.bindings.get("startSet") orelse return error.MissingAttribute;
    const operator_val = val.attrs.bindings.get("operator") orelse return error.MissingAttribute;
    const start_set = try evaluator.force(start_set_val);
    const operator = try evaluator.force(operator_val);

    if (start_set != .list) return error.TypeError;

    var result = std.ArrayList(Value).empty;
    defer result.deinit(allocator);
    var work_list = std.ArrayList(Value).empty;
    defer work_list.deinit(allocator);

    // Initialize work list with startSet
    for (start_set.list) |item| {
        try work_list.append(allocator, item);
    }

    // Simple genericClosure - may not handle all edge cases
    var seen_keys = std.StringHashMap(void).init(allocator);
    defer seen_keys.deinit();

    while (work_list.items.len > 0) {
        const item = work_list.orderedRemove(0);
        const forced_item = try evaluator.force(item);
        if (forced_item != .attrs) continue;

        // Get key for dedup
        const key_val = forced_item.attrs.bindings.get("key") orelse continue;
        const forced_key = try evaluator.force(key_val);
        const key_str = switch (forced_key) {
            .string => forced_key.string,
            .int => blk: {
                var buf: [20]u8 = undefined;
                const slice = std.fmt.bufPrint(&buf, "{}", .{forced_key.int}) catch break :blk "0";
                const owned = try allocator.alloc(u8, slice.len);
                @memcpy(owned, slice);
                break :blk owned;
            },
            else => continue,
        };

        if (seen_keys.contains(key_str)) continue;
        try seen_keys.put(key_str, {});
        try result.append(allocator, item);

        // Apply operator
        const new_items = try evaluator.force(try evaluator.apply(operator, item));
        if (new_items == .list) {
            for (new_items.list) |new_item| {
                try work_list.append(allocator, new_item);
            }
        }
    }

    return Value{ .list = try result.toOwnedSlice(allocator) };
}

fn builtinZipAttrsWith(eval_ctx: ?*eval.Evaluator, io: std.Io, allocator: std.mem.Allocator, args: []Value) !Value {
    _ = io;
    if (args.len != 2) return error.InvalidArgCount;
    const evaluator = eval_ctx orelse return error.TypeError;
    const func = try evaluator.force(args[0]);
    const list_val = try evaluator.force(args[1]);
    if (list_val != .list) return error.TypeError;

    // Collect all key-value pairs grouped by key
    var grouped = std.StringHashMap(std.ArrayList(Value)).init(allocator);
    defer {
        var it = grouped.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        grouped.deinit();
    }

    for (list_val.list) |attrs_val| {
        const forced = try evaluator.force(attrs_val);
        if (forced != .attrs) continue;
        var it = forced.attrs.bindings.iterator();
        while (it.next()) |entry| {
            const gop = try grouped.getOrPut(entry.key_ptr.*);
            if (!gop.found_existing) {
                gop.value_ptr.* = std.ArrayList(Value).empty;
            }
            try gop.value_ptr.append(allocator, entry.value_ptr.*);
        }
    }

    // Apply function to each group
    var result = std.StringHashMap(Value).init(allocator);
    var it = grouped.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        const values = Value{ .list = try entry.value_ptr.toOwnedSlice(allocator) };
        const applied = try evaluator.apply(func, Value{ .string = name });
        const final = try evaluator.apply(applied, values);
        try result.put(name, final);
    }

    return Value{ .attrs = .{ .bindings = result } };
}

fn builtinAddErrorContext(eval_ctx: ?*eval.Evaluator, io: std.Io, allocator: std.mem.Allocator, args: []Value) !Value {
    _ = eval_ctx;
    _ = io;
    _ = allocator;
    if (args.len != 2) return error.InvalidArgCount;
    // addErrorContext is a no-op for now - just return the second arg
    return args[1];
}

fn builtinUnsafeGetAttrPos(eval_ctx: ?*eval.Evaluator, io: std.Io, allocator: std.mem.Allocator, args: []Value) !Value {
    _ = eval_ctx;
    _ = io;
    _ = allocator;
    if (args.len != 2) return error.InvalidArgCount;
    // Returns null for now - position info not tracked
    return Value{ .null_val = {} };
}

fn builtinUnsafeDiscardStringContext(eval_ctx: ?*eval.Evaluator, io: std.Io, allocator: std.mem.Allocator, args: []Value) !Value {
    _ = io;
    _ = allocator;
    if (args.len != 1) return error.InvalidArgCount;
    const evaluator = eval_ctx orelse return error.TypeError;
    // No string context tracking - just return the string as-is
    return try evaluator.force(args[0]);
}

fn builtinHasContext(eval_ctx: ?*eval.Evaluator, io: std.Io, allocator: std.mem.Allocator, args: []Value) !Value {
    _ = eval_ctx;
    _ = io;
    _ = allocator;
    if (args.len != 1) return error.InvalidArgCount;
    // No string context tracking
    return Value{ .bool = false };
}

fn builtinGetContext(eval_ctx: ?*eval.Evaluator, io: std.Io, allocator: std.mem.Allocator, args: []Value) !Value {
    _ = eval_ctx;
    _ = io;
    if (args.len != 1) return error.InvalidArgCount;
    // No string context tracking - return empty attrset
    return Value{ .attrs = .{ .bindings = std.StringHashMap(Value).init(allocator) } };
}

fn builtinParseDrvName(eval_ctx: ?*eval.Evaluator, io: std.Io, allocator: std.mem.Allocator, args: []Value) !Value {
    _ = io;
    if (args.len != 1) return error.InvalidArgCount;
    const evaluator = eval_ctx orelse return error.TypeError;
    const val = try evaluator.force(args[0]);
    if (val != .string) return error.TypeError;
    const name = val.string;

    // Find the last '-' followed by a digit
    var split_pos: ?usize = null;
    var i: usize = name.len;
    while (i > 0) {
        i -= 1;
        if (name[i] == '-' and i + 1 < name.len and std.ascii.isDigit(name[i + 1])) {
            split_pos = i;
            break;
        }
    }

    var result = std.StringHashMap(Value).init(allocator);
    if (split_pos) |pos| {
        try result.put("name", Value{ .string = name[0..pos] });
        try result.put("version", Value{ .string = name[pos + 1 ..] });
    } else {
        try result.put("name", Value{ .string = name });
        try result.put("version", Value{ .string = "" });
    }
    return Value{ .attrs = .{ .bindings = result } };
}

fn builtinWarn(eval_ctx: ?*eval.Evaluator, io: std.Io, allocator: std.mem.Allocator, args: []Value) !Value {
    _ = io;
    _ = allocator;
    if (args.len != 2) return error.InvalidArgCount;
    const evaluator = eval_ctx orelse return error.TypeError;
    const msg = try evaluator.force(args[0]);
    if (msg == .string) {
        std.debug.print("warning: {s}\n", .{msg.string});
    }
    return args[1];
}

fn builtinReadFileType(eval_ctx: ?*eval.Evaluator, io: std.Io, allocator: std.mem.Allocator, args: []Value) !Value {
    _ = allocator;
    if (args.len != 1) return error.InvalidArgCount;
    const evaluator = eval_ctx orelse return error.TypeError;
    const val = try evaluator.force(args[0]);
    if (val != .string and val != .path) return error.TypeError;
    const path = if (val == .string) val.string else val.path;

    const stat = Dir.statFile(.cwd(), io, path, .{}) catch return Value{ .string = "unknown" };
    if (stat.kind == .directory) return Value{ .string = "directory" };
    if (stat.kind == .sym_link) return Value{ .string = "symlink" };
    return Value{ .string = "regular" };
}
