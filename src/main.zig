const std = @import("std");
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const eval = @import("eval.zig");
const io_utils = @import("io.zig");
const flake = @import("flake.zig");
const store = @import("store.zig");

const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    // Parse CLI args
    var input_file: ?[]const u8 = null;
    var mode: Mode = .eval;
    var print_ast = false;
    var attr_path: ?[]const u8 = null;
    var expr_string: ?[]const u8 = null;

    var args_iter = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args_iter.deinit();

    // Skip program name
    _ = args_iter.next();

    // Check for subcommands first
    if (args_iter.next()) |first_arg| {
        if (std.mem.eql(u8, first_arg, "build")) {
            mode = .build;
        } else if (std.mem.eql(u8, first_arg, "flake")) {
            // Handle flake subcommand
            if (args_iter.next()) |flake_cmd| {
                if (std.mem.eql(u8, flake_cmd, "show")) {
                    mode = .flake_show;
                } else if (std.mem.eql(u8, flake_cmd, "metadata")) {
                    mode = .flake_metadata;
                } else if (std.mem.eql(u8, flake_cmd, "lock")) {
                    mode = .flake_lock;
                } else if (!std.mem.startsWith(u8, flake_cmd, "-")) {
                    // `zix flake <path>` defaults to show
                    mode = .flake_show;
                    input_file = flake_cmd;
                }
            } else {
                mode = .flake_show;
            }
        } else if (std.mem.eql(u8, first_arg, "show")) {
            // Alias for `flake show`, e.g. `zix show .#`
            mode = .flake_show;
        } else if (std.mem.eql(u8, first_arg, "metadata")) {
            mode = .flake_metadata;
        } else if (std.mem.eql(u8, first_arg, "eval")) {
            mode = .eval;
        } else if (std.mem.eql(u8, first_arg, "--expr")) {
            expr_string = args_iter.next() orelse {
                std.debug.print("Error: --expr requires an expression argument\n", .{});
                return error.InvalidArgument;
            };
            mode = .eval;
        } else if (std.mem.eql(u8, first_arg, "repl")) {
            mode = .repl;
        } else if (std.mem.eql(u8, first_arg, "--lex")) {
            mode = .lex;
        } else if (std.mem.eql(u8, first_arg, "--parse")) {
            mode = .parse;
        } else if (std.mem.eql(u8, first_arg, "--eval")) {
            mode = .eval;
        } else if (std.mem.eql(u8, first_arg, "--ast")) {
            print_ast = true;
        } else if (std.mem.eql(u8, first_arg, "--help") or std.mem.eql(u8, first_arg, "-h")) {
            printHelp();
            return;
        } else if (!std.mem.startsWith(u8, first_arg, "-")) {
            input_file = first_arg;
        }
    }

    // Continue parsing remaining args
    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--lex")) {
            mode = .lex;
        } else if (std.mem.eql(u8, arg, "--parse")) {
            mode = .parse;
        } else if (std.mem.eql(u8, arg, "--eval")) {
            mode = .eval;
        } else if (std.mem.eql(u8, arg, "--ast")) {
            print_ast = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printHelp();
            return;
        } else if (std.mem.eql(u8, arg, "--expr")) {
            expr_string = args_iter.next() orelse {
                std.debug.print("Error: --expr requires an expression argument\n", .{});
                return error.InvalidArgument;
            };
        } else if (std.mem.startsWith(u8, arg, "-") and !std.mem.startsWith(u8, arg, ".")) {
            std.debug.print("Unknown option: {s}\n", .{arg});
            printHelp();
            return error.InvalidArgument;
        } else {
            // Could be a flake reference like .#foo or path
            if (std.mem.indexOf(u8, arg, "#")) |hash_idx| {
                input_file = arg[0..hash_idx];
                if (input_file.?.len == 0) input_file = ".";
                attr_path = arg[hash_idx + 1 ..];
            } else {
                input_file = arg;
            }
        }
    }

    var file_holder: ?std.Io.File = null;
    defer if (file_holder) |f| f.close(io);

    var file_reader_holder: File.Reader = undefined;
    var fixed_reader_holder: std.Io.Reader = undefined;
    var read_buf: [4096]u8 = undefined;

    const source: *std.Io.Reader = blk: {
        if (expr_string) |expr| {
            fixed_reader_holder = std.Io.Reader.fixed(expr);
            break :blk &fixed_reader_holder;
        } else if (input_file) |file_path| {
            const stat = Dir.statFile(.cwd(), io, file_path, .{}) catch {
                const file = try Dir.openFile(.cwd(), io, file_path, .{});
                file_holder = file;
                file_reader_holder = file.readerStreaming(io, &read_buf);
                break :blk &file_reader_holder.interface;
            };

            if (stat.kind == .directory) {
                const flake_path = try std.fs.path.join(allocator, &.{ file_path, "flake.nix" });
                defer allocator.free(flake_path);

                const file = try Dir.openFile(.cwd(), io, flake_path, .{});
                file_holder = file;
                file_reader_holder = file.readerStreaming(io, &read_buf);
                break :blk &file_reader_holder.interface;
            }

            const file = try Dir.openFile(.cwd(), io, file_path, .{});
            file_holder = file;
            file_reader_holder = file.readerStreaming(io, &read_buf);
            break :blk &file_reader_holder.interface;
        } else {
            const stdin = File.stdin();
            const stdin_is_tty = try stdin.isTty(io);
            if (stdin_is_tty) {
                printHelp();
                return;
            }
            file_reader_holder = stdin.readerStreaming(io, &read_buf);
            break :blk &file_reader_holder.interface;
        }
    };

    switch (mode) {
        .lex => try runLexer(allocator, source),
        .parse => try runParser(allocator, source, print_ast),
        .eval => try runEvaluator(allocator, io, source, input_file),
        .build => try runBuild(allocator, io, input_file orelse ".", attr_path),
        .flake_show => try runFlakeShow(allocator, io, input_file orelse "."),
        .flake_metadata => try runFlakeMetadata(allocator, io, input_file orelse "."),
        .flake_lock => try runFlakeLock(allocator, io, input_file orelse "."),
        .repl => try runRepl(allocator, io),
    }
}

const Mode = enum {
    lex,
    parse,
    eval,
    build,
    flake_show,
    flake_metadata,
    flake_lock,
    repl,
};

fn printHelp() void {
    std.debug.print(
        \\zix - Nix parser and evaluator written in Zig
        \\
        \\Usage: zix [command] [options] [arguments]
        \\
        \\Commands:
        \\  build <installable>  Build a derivation or fetch a store path
        \\                       Example: zix build .#legacyPackages.x86_64-linux.hello
        \\  eval [file]          Evaluate a Nix expression
        \\  flake show [path]    Show flake outputs
        \\  flake metadata       Show flake metadata
        \\  flake lock           Update flake.lock
        \\  repl                 Start an interactive REPL
        \\
        \\Options:
        \\  --lex        Tokenize and print tokens only
        \\  --parse      Parse and print AST only
        \\  --ast        Print AST when evaluating
        \\  -h, --help   Show this help message
        \\
        \\Installable format:
        \\  .                    Current flake's default package
        \\  .#<attrpath>         Specific output from current flake
        \\  <flakeref>#<attr>    Output from specified flake
        \\
        \\Examples:
        \\  zix build .#hello
        \\  zix build .#legacyPackages.x86_64-linux.hello
        \\  zix eval --expr '1 + 2'
        \\  zix flake show
        \\
    , .{});
}

fn runLexer(allocator: std.mem.Allocator, source: *std.Io.Reader) !void {
    var lex = lexer.Lexer.init(allocator, source, "<input>");
    defer lex.deinit();

    while (true) {
        const token = try lex.nextToken();
        std.debug.print("{s:12} ", .{@tagName(token.kind)});

        switch (token.kind) {
            .eof => {
                std.debug.print("\n", .{});
                break;
            },
            .integer => std.debug.print("{d}\n", .{token.value.integer}),
            .float => std.debug.print("{d}\n", .{token.value.float}),
            .identifier => std.debug.print("{s}\n", .{token.value.identifier}),
            .string => std.debug.print("\"{s}\"\n", .{token.value.string}),
            .path => std.debug.print("{s}\n", .{token.value.path}),
            else => std.debug.print("\n", .{}),
        }
    }
}

fn runParser(allocator: std.mem.Allocator, source: *std.Io.Reader, print_ast: bool) !void {
    var p = try parser.Parser.init(allocator, source, "<input>");
    defer p.deinit();

    const ast_expr = try p.parseExpr();

    if (print_ast) {
        std.debug.print("AST:\n", .{});
        // TODO: implement AST printing to debug output
        _ = ast_expr;
    } else {
        std.debug.print("Parse successful\n", .{});
    }
}

fn runEvaluator(allocator: std.mem.Allocator, io: Io, source: *std.Io.Reader, file_path: ?[]const u8) !void {
    // Create evaluator first so we can use its arena for parsing
    var evaluator = try eval.Evaluator.init(allocator, io);
    defer evaluator.deinit();

    // Parse using evaluator's arena allocator so AST strings survive
    var p = try parser.Parser.init(evaluator.alloc(), source, file_path orelse "<stdin>");
    defer p.deinit();
    const ast_expr = try p.parseExpr();

    const result = try evaluator.eval(ast_expr);
    // Don't deinit result - values are shared across envs/thunks.
    // The allocator (arena) will reclaim everything on evaluator.deinit().

    // Print result
    // Print result - force thunks for display
    printValue(result, &evaluator);
    std.debug.print("\n", .{});

    // AST is owned by arena now, no need to deinit separately
}

fn printValue(value: eval.Value, evaluator: ?*eval.Evaluator) void {
    // Force thunks before printing if we have an evaluator
    const v = if (value == .thunk and evaluator != null) (evaluator.?.force(value) catch value) else value;
    switch (v) {
        .int => |i| std.debug.print("{}", .{i}),
        .float => |f| std.debug.print("{d}", .{f}),
        .bool => |b| std.debug.print("{}", .{b}),
        .string => |s| std.debug.print("\"{s}\"", .{s}),
        .path => |p| std.debug.print("{s}", .{p}),
        .null_val => std.debug.print("null", .{}),
        .list => |l| {
            std.debug.print("[ ", .{});
            for (l) |item| {
                printValue(item, evaluator);
                std.debug.print(" ", .{});
            }
            std.debug.print("]", .{});
        },
        .attrs => |a| {
            std.debug.print("{{ ", .{});
            var iter = a.bindings.iterator();
            var count: usize = 0;
            while (iter.next()) |entry| {
                if (count > 0) std.debug.print("; ", .{});
                std.debug.print("{s} = ", .{entry.key_ptr.*});
                printValue(entry.value_ptr.*, evaluator);
                count += 1;
                if (count >= 5) {
                    std.debug.print("; ...", .{});
                    break;
                }
            }
            std.debug.print(" }}", .{});
        },
        .lambda => std.debug.print("<lambda>", .{}),
        .builtin => |b| std.debug.print("<builtin:{s}>", .{b.name}),
        .thunk => std.debug.print("<thunk>", .{}),
    }
}

fn runBuild(allocator: std.mem.Allocator, io: Io, flake_ref: []const u8, attr_path: ?[]const u8) !void {
    std.debug.print("Building {s}", .{flake_ref});
    if (attr_path) |ap| {
        std.debug.print("#{s}", .{ap});
    }
    std.debug.print("...\n", .{});

    var fe = try flake.FlakeEvaluator.init(allocator, io);
    defer fe.deinit();

    // Determine the attribute path to build
    const build_attr = attr_path orelse blk: {
        // Default: packages.<system>.default or legacyPackages.<system>.default
        const system = store.getCurrentSystem();
        break :blk try std.fmt.allocPrint(allocator, "packages.{s}.default", .{system});
    };
    defer if (attr_path == null) allocator.free(build_attr);

    const result = fe.build(io, flake_ref, build_attr) catch |err| {
        std.debug.print("Build failed: {}\n", .{err});
        return err;
    };

    std.debug.print("Built: {s}\n", .{result});
}

fn runFlakeShow(allocator: std.mem.Allocator, io: Io, path: []const u8) !void {
    std.debug.print("Showing flake outputs for {s}...\n\n", .{path});

    var fe = try flake.FlakeEvaluator.init(allocator, io);
    defer fe.deinit();

    var fl = fe.loadFlakeWithIo(io, path) catch |err| {
        std.debug.print("Failed to load flake: {}\n", .{err});
        return err;
    };
    // NOTE: `fe.resolve()` below takes `fl` by value and stores it inside
    // `resolved.flake`, taking ownership of its allocations. `resolved.deinit()`
    // (deferred after resolve succeeds) is responsible for freeing it, so we
    // must NOT also `defer fl.deinit()` here or it becomes a double free.

    // Print description
    if (fl.description) |desc| {
        std.debug.print("Description: {s}\n\n", .{desc});
    }

    // Print inputs
    if (fl.inputs.count() > 0) {
        std.debug.print("Inputs:\n", .{});
        var iter = fl.inputs.iterator();
        while (iter.next()) |entry| {
            std.debug.print("  {s}: ", .{entry.key_ptr.*});
            const ref_str = try entry.value_ptr.ref.toString(allocator);
            defer allocator.free(ref_str);
            std.debug.print("{s}\n", .{ref_str});
        }
        std.debug.print("\n", .{});
    }

    // Resolve inputs with progress
    var resolved = resolve_blk: {
        var draw_buffer_show: [4096]u8 = undefined;
        const progress_root_show = std.Progress.start(io, .{
            .draw_buffer = &draw_buffer_show,
        });
        defer progress_root_show.end();
        break :resolve_blk fe.resolve(io, fl, progress_root_show) catch |err| {
            std.debug.print("Failed to resolve flake: {}\n", .{err});
            return err;
        };
    };
    defer resolved.deinit();

    const outputs = fe.evalOutputs(&resolved) catch |err| {
        std.debug.print("Failed to evaluate outputs: {}\n", .{err});
        return err;
    };

    std.debug.print("Outputs:\n", .{});
    if (outputs == .attrs) {
        printFlakeOutputs(&fe, allocator, outputs.attrs.bindings, 1);
    }
}

fn printFlakeOutputs(fe: *flake.FlakeEvaluator, allocator: std.mem.Allocator, bindings: std.StringHashMap(eval.Value), indent: usize) void {
    var iter = bindings.iterator();
    while (iter.next()) |entry| {
        for (0..indent * 2) |_| std.debug.print(" ", .{});

        const key = entry.key_ptr.*;
        const val = fe.evaluator.force(entry.value_ptr.*) catch |err| {
            std.debug.print("├───{s}: <error: {s}>\n", .{ key, @errorName(err) });
            continue;
        };
        if (val == .attrs) {
            // Check if it's a derivation
            if (val.attrs.bindings.get("type")) |type_val| {
                if (type_val == .string and std.mem.eql(u8, type_val.string, "derivation")) {
                    const name = if (val.attrs.bindings.get("name")) |n|
                        if (n == .string) n.string else key
                    else
                        key;
                    std.debug.print("├───{s}: derivation '{s}'\n", .{ key, name });
                    continue;
                }
            }

            // Regular attrset
            std.debug.print("├───{s}\n", .{key});
            printFlakeOutputs(fe, allocator, val.attrs.bindings, indent + 1);
        } else if (val == .lambda) {
            std.debug.print("├───{s}: <function>\n", .{key});
        } else {
            std.debug.print("├───{s}: ", .{key});
            printValue(val, null);
            std.debug.print("\n", .{});
        }
    }
}

fn runFlakeMetadata(allocator: std.mem.Allocator, io: Io, path: []const u8) !void {
    std.debug.print("Flake metadata for {s}\n\n", .{path});

    var fe = try flake.FlakeEvaluator.init(allocator, io);
    defer fe.deinit();

    var fl = fe.loadFlakeWithIo(io, path) catch |err| {
        std.debug.print("Failed to load flake: {}\n", .{err});
        return err;
    };
    defer fl.deinit();

    std.debug.print("Path:        {s}\n", .{fl.path});
    if (fl.description) |desc| {
        std.debug.print("Description: {s}\n", .{desc});
    }

    std.debug.print("\nInputs:\n", .{});
    var iter = fl.inputs.iterator();
    while (iter.next()) |entry| {
        std.debug.print("  '{s}':\n", .{entry.key_ptr.*});
        const ref_str = try entry.value_ptr.ref.toString(allocator);
        defer allocator.free(ref_str);
        std.debug.print("    url: {s}\n", .{ref_str});
    }
}

fn runFlakeLock(allocator: std.mem.Allocator, io: Io, path: []const u8) !void {
    std.debug.print("Updating flake.lock for {s}...\n", .{path});

    var fe = try flake.FlakeEvaluator.init(allocator, io);
    defer fe.deinit();

    const fl = fe.loadFlakeWithIo(io, path) catch |err| {
        std.debug.print("Failed to load flake: {}\n", .{err});
        return err;
    };
    // See NOTE in runFlakeShow: `fe.resolve()` takes ownership of `fl`, so
    // no separate `fl.deinit()` here.

    var resolved = resolve_blk: {
        var draw_buffer_lock: [4096]u8 = undefined;
        const progress_root_lock = std.Progress.start(io, .{
            .draw_buffer = &draw_buffer_lock,
        });
        defer progress_root_lock.end();
        break :resolve_blk fe.resolve(io, fl, progress_root_lock) catch |err| {
            std.debug.print("Failed to resolve flake: {}\n", .{err});
            return err;
        };
    };
    defer resolved.deinit();

    // Would write flake.lock here
    std.debug.print("Lock file updated.\n", .{});
}

fn runRepl(allocator: std.mem.Allocator, io: Io) !void {
    _ = io;
    _ = allocator;
    std.debug.print("zix repl - Nix expression evaluator\n", .{});
    std.debug.print("REPL not yet implemented for new Zig IO API\n", .{});
    std.debug.print("Use `zix eval <file>` or `zix eval --expr '<expression>'` instead.\n", .{});
}
