const std = @import("std");
const ast = @import("ast.zig");
const eval = @import("eval.zig");
const parser = @import("parser.zig");
const lexer = @import("lexer.zig");
const FlakeRef = @import("flakeref.zig").FlakeRef;
const Registry = @import("flakeref.zig").Registry;
const LockFile = @import("lockfile.zig").LockFile;
const Fetcher = @import("fetcher.zig").Fetcher;
const FetchResult = @import("fetcher.zig").FetchResult;
const store = @import("store.zig");

const Value = eval.Value;
const Env = eval.Env;
const Expr = ast.Expr;

/// A parsed flake structure
pub const Flake = struct {
    description: ?[]const u8,
    inputs: std.StringHashMap(FlakeInput),
    /// Nested follows overrides: input_name -> (sub_input_name -> follows_path)
    /// e.g. inputs.git-hooks-nix.inputs.nixpkgs.follows = "nixpkgs"
    /// becomes: input_overrides["git-hooks-nix"]["nixpkgs"] = &["nixpkgs"]
    input_overrides: std.StringHashMap(std.StringHashMap([]const []const u8)),
    outputs_expr: ?*Expr,
    path: []const u8,
    allocator: std.mem.Allocator,

    pub const FlakeInput = struct {
        ref: FlakeRef,
        follows: ?[]const []const u8,
        is_flake: bool = true,
    };

    pub fn deinit(self: *Flake) void {
        if (self.description) |d| self.allocator.free(d);
        var iter = self.inputs.iterator();
        while (iter.next()) |entry| {
            // Free the map key string allocated during parsing
            self.allocator.free(entry.key_ptr.*);
            @constCast(&entry.value_ptr.ref).deinit();
            if (entry.value_ptr.follows) |f| {
                for (f) |part| self.allocator.free(part);
                self.allocator.free(f);
            }
        }
        self.inputs.deinit();
        // Clean up input_overrides
        var ovr_iter = self.input_overrides.iterator();
        while (ovr_iter.next()) |ovr_entry| {
            // Free the override map key
            self.allocator.free(ovr_entry.key_ptr.*);
            var sub_iter = ovr_entry.value_ptr.iterator();
            while (sub_iter.next()) |sub_entry| {
                // Free sub-entry key and the stored parts array
                self.allocator.free(sub_entry.key_ptr.*);
                for (sub_entry.value_ptr.*) |part| self.allocator.free(part);
                self.allocator.free(sub_entry.value_ptr.*);
            }
            ovr_entry.value_ptr.deinit();
        }
        self.input_overrides.deinit();
        // Don't deinit outputs_expr - it's a borrowed pointer into the parse tree
        // which shares sub-expressions with other parts of the AST.
        self.allocator.free(self.path);
    }
};

/// Resolved flake with evaluated inputs
pub const ResolvedFlake = struct {
    flake: Flake,
    inputs: std.StringHashMap(ResolvedInput),
    outputs: ?Value,
    allocator: std.mem.Allocator,

    pub const ResolvedInput = struct {
        flake: ?*ResolvedFlake,
        source_path: []const u8,
        rev: ?[]const u8,
        /// Whether this input owns `flake` and is responsible for freeing
        /// it. Follows-resolution and dedup logic frequently alias the same
        /// `*ResolvedFlake` from multiple `ResolvedInput`s (e.g. a `follows`
        /// input pointing at an already-resolved sibling, or cycle/dedup
        /// reuse); only the original owner may destroy the pointer.
        owns_flake: bool = false,
    };

    pub fn deinit(self: *ResolvedFlake) void {
        self.flake.deinit();
        var iter = self.inputs.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.owns_flake) {
                if (entry.value_ptr.flake) |f| {
                    f.deinit();
                    self.allocator.destroy(f);
                }
            }
            self.allocator.free(entry.value_ptr.source_path);
            if (entry.value_ptr.rev) |r| self.allocator.free(r);
        }
        self.inputs.deinit();
    }
};

/// The flake evaluator
pub const FlakeEvaluator = struct {
    allocator: std.mem.Allocator,
    parent_allocator: std.mem.Allocator,
    fetcher: Fetcher,
    registry: Registry,
    evaluator: eval.Evaluator,
    nix_store: store.Store,
    system: []const u8,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !FlakeEvaluator {
        const evaluator = try eval.Evaluator.init(allocator, io);

        var fe = FlakeEvaluator{
            .allocator = allocator,
            .parent_allocator = allocator,
            .fetcher = Fetcher.init(std.heap.page_allocator, io),
            .registry = Registry.init(allocator),
            .evaluator = evaluator,
            .nix_store = store.Store.init(allocator),
            .system = store.getCurrentSystem(),
        };

        try fe.registry.loadDefaults();

        return fe;
    }

    pub fn deinit(self: *FlakeEvaluator) void {
        self.fetcher.deinit();
        self.registry.deinit();
        self.evaluator.deinit();
        self.nix_store.deinit();
    }

    /// Load and parse a flake.nix file
    /// NOTE: File I/O temporarily stubbed - requires IO handle
    pub fn loadFlake(self: *FlakeEvaluator, path: []const u8) !Flake {
        // TODO: Implement proper file I/O with new Zig Io API
        _ = path;

        // Return a basic empty flake for now
        const flake = Flake{
            .description = null,
            .inputs = std.StringHashMap(Flake.FlakeInput).init(self.allocator),
            .input_overrides = std.StringHashMap(std.StringHashMap([]const []const u8)).init(self.allocator),
            .outputs_expr = null,
            .path = try self.allocator.dupe(u8, "."),
            .allocator = self.allocator,
        };

        return flake;
    }

    /// Load and parse a flake.nix file (with IO handle)
    pub fn loadFlakeWithIo(self: *FlakeEvaluator, io: std.Io, path: []const u8) !Flake {
        const Dir = std.Io.Dir;

        // Duplicate the incoming path into the evaluator allocator so we
        // operate on a stable, owned buffer even if the caller later frees
        // their copy.
        const safe_input_path = try self.allocator.dupe(u8, path);
        defer self.allocator.free(safe_input_path);

        // Determine the actual flake.nix file to read. If `path` refers to a
        // directory, join it with "flake.nix". If it refers to an existing
        // file, use it directly. If stat fails, try path + "/flake.nix" as a
        // fallback.
        var flake_path: ?[]const u8 = null;
        var need_free: bool = false;

        const stat_res = Dir.statFile(.cwd(), io, safe_input_path, .{}) catch null;
        if (stat_res) |st| {
            if (st.kind == .directory) {
                flake_path = try std.fs.path.join(self.allocator, &.{ safe_input_path, "flake.nix" });
                need_free = true;
            } else {
                // Path points to a file; use as-is
                flake_path = safe_input_path;
            }
        } else {
            // stat failed; try joining with flake.nix as a fallback
            flake_path = try std.fs.path.join(self.allocator, &.{ safe_input_path, "flake.nix" });
            need_free = true;
        }

        defer if (need_free) self.allocator.free(flake_path.?);

        var file_opt: ?std.Io.File = Dir.openFile(.cwd(), io, flake_path.?, .{}) catch null;
        if (file_opt == null) {
            // Try a simple fallback: look for ./flake.nix in CWD
            const fallback = try std.fs.path.join(self.allocator, &.{ ".", "flake.nix" });
            defer self.allocator.free(fallback);
            const fb = try Dir.openFile(.cwd(), io, fallback, .{});
            file_opt = fb;
        }

        var file = file_opt.?;
        defer file.close(io);

        var read_buf: [8192]u8 = undefined;
        var reader = file.reader(io, &read_buf);

        // Parse the flake.nix using the evaluator arena so AST memory is reclaimed
        var p = try parser.Parser.init(self.evaluator.alloc(), &reader.interface, flake_path.?);
        defer p.deinit();

        const flake_expr = try p.parseExpr();

        // The flake.nix should be an attribute set
        if (flake_expr != .attrs) {
            return error.InvalidFlake;
        }

        var flake = Flake{
            .description = null,
            .inputs = std.StringHashMap(Flake.FlakeInput).init(self.allocator),
            .input_overrides = std.StringHashMap(std.StringHashMap([]const []const u8)).init(self.allocator),
            .outputs_expr = undefined,
            .path = try self.allocator.dupe(u8, safe_input_path),
            .allocator = self.allocator,
        };
        errdefer flake.deinit();

        // Extract flake attributes
        for (flake_expr.attrs.bindings) |binding| {
            const key = try self.attrPathToString(binding.key);
            defer self.allocator.free(key);

            if (std.mem.eql(u8, key, "description")) {
                if (binding.value.* == .string) {
                    flake.description = try self.allocator.dupe(u8, binding.value.string);
                }
            } else if (std.mem.eql(u8, key, "inputs")) {
                // Traditional inputs attribute set
                try self.parseInputs(&flake, binding.value.*);
            } else if (std.mem.startsWith(u8, key, "inputs.")) {
                // Flattened input attribute (e.g., "inputs.nixpkgs.url")
                // Extract the input name
                const dot_pos = std.mem.indexOf(u8, key[7..], ".") orelse key[7..].len;
                const input_name = try self.allocator.dupe(u8, key[7..][0..dot_pos]);
                errdefer self.allocator.free(input_name);

                // Get or create the input
                var input_result = try flake.inputs.getOrPut(input_name);
                if (!input_result.found_existing) {
                    input_result.value_ptr.* = Flake.FlakeInput{
                        .ref = FlakeRef.init(self.allocator),
                        .follows = null,
                    };
                }

                // Set the attribute
                const attr_name = if (dot_pos < key[7..].len) key[7 + dot_pos + 1 ..] else "";
                if (std.mem.eql(u8, attr_name, "url") and binding.value.* == .string) {
                    input_result.value_ptr.ref = try FlakeRef.parse(self.allocator, binding.value.string);
                } else if (std.mem.eql(u8, attr_name, "flake") and binding.value.* == .var_ref) {
                    input_result.value_ptr.is_flake = std.mem.eql(u8, binding.value.var_ref, "true");
                } else if (std.mem.eql(u8, attr_name, "follows") and binding.value.* == .string) {
                    var follows: std.ArrayList([]const u8) = .empty;
                    var parts = std.mem.splitScalar(u8, binding.value.string, '/');
                    while (parts.next()) |part| {
                        try follows.append(self.allocator, try self.allocator.dupe(u8, part));
                    }
                    input_result.value_ptr.follows = try follows.toOwnedSlice(self.allocator);
                } else if (std.mem.startsWith(u8, attr_name, "inputs.")) {
                    // Nested follows: inputs.X.inputs.Y.follows = "Z"
                    const sub_rest = attr_name["inputs.".len..];
                    const sub_dot = std.mem.indexOf(u8, sub_rest, ".") orelse sub_rest.len;
                    const sub_input_name = sub_rest[0..sub_dot];
                    const sub_attr = if (sub_dot < sub_rest.len) sub_rest[sub_dot + 1 ..] else "";

                    if (std.mem.eql(u8, sub_attr, "follows") and binding.value.* == .string) {
                        var ovr_result = try flake.input_overrides.getOrPut(input_name);
                        if (!ovr_result.found_existing) {
                            ovr_result.value_ptr.* = std.StringHashMap([]const []const u8).init(self.allocator);
                        }
                        var follows_list: std.ArrayList([]const u8) = .empty;
                        if (binding.value.string.len > 0) {
                            var fparts = std.mem.splitScalar(u8, binding.value.string, '/');
                            while (fparts.next()) |fpart| {
                                try follows_list.append(self.allocator, try self.allocator.dupe(u8, fpart));
                            }
                        }
                        try ovr_result.value_ptr.put(
                            try self.allocator.dupe(u8, sub_input_name),
                            try follows_list.toOwnedSlice(self.allocator),
                        );
                    }
                } else if (attr_name.len == 0 and binding.value.* == .attrs) {
                    // inputs.nixpkgs = { ... };
                    // Parse the attribute set for url, flake, follows
                    self.parseInputAttrs(input_result.value_ptr, binding.value.attrs) catch {};
                }

                // If no URL was set, use the input name as an indirect ref
                if (input_result.value_ptr.ref.url.len == 0) {
                    input_result.value_ptr.ref = try FlakeRef.parse(self.allocator, input_name);
                }
            } else if (std.mem.eql(u8, key, "outputs")) {
                flake.outputs_expr = binding.value;
            }
        }

        return flake;
    }

    fn attrPathToString(self: *FlakeEvaluator, path: Expr.AttrPath) ![]u8 {
        var result: std.ArrayList(u8) = .empty;
        for (path.parts, 0..) |part, i| {
            if (i > 0) try result.append(self.allocator, '.');
            switch (part) {
                .ident => |id| try result.appendSlice(self.allocator, id),
                .string => |s| try result.appendSlice(self.allocator, s),
                .expr => return error.DynamicAttrPath,
            }
        }
        const owned = try result.toOwnedSlice(self.allocator);
        return owned;
    }

    fn parseInputs(self: *FlakeEvaluator, flake: *Flake, expr: Expr) !void {
        if (expr != .attrs) return;

        for (expr.attrs.bindings) |binding| {
            // Handle dotted attr paths like: nixpkgs-lib.url = "...";
            // The first part is the input name, remaining parts are attributes
            if (binding.key.parts.len == 0) continue;

            const input_name = switch (binding.key.parts[0]) {
                .ident => |id| id,
                .string => |s| s,
                else => continue,
            };

            var input_result = try flake.inputs.getOrPut(try self.allocator.dupe(u8, input_name));
            if (!input_result.found_existing) {
                input_result.value_ptr.* = Flake.FlakeInput{
                    .ref = FlakeRef.init(self.allocator),
                    .follows = null,
                    .is_flake = true,
                };
            }

            if (binding.key.parts.len == 1) {
                // Simple form: nixpkgs = "..." or nixpkgs = { url = "..."; flake = false; }
                switch (binding.value.*) {
                    .string => |s| {
                        input_result.value_ptr.ref = try FlakeRef.parse(self.allocator, s);
                    },
                    .attrs => |attrs| {
                        self.parseInputAttrs(input_result.value_ptr, attrs) catch {};
                    },
                    else => {},
                }
            } else {
                // Dotted form: nixpkgs-lib.url = "..." or zig.flake = false
                const attr_name = switch (binding.key.parts[1]) {
                    .ident => |id| id,
                    .string => |s| s,
                    else => continue,
                };

                if (std.mem.eql(u8, attr_name, "url") and binding.value.* == .string) {
                    input_result.value_ptr.ref = try FlakeRef.parse(self.allocator, binding.value.string);
                } else if (std.mem.eql(u8, attr_name, "flake") and binding.value.* == .var_ref) {
                    input_result.value_ptr.is_flake = std.mem.eql(u8, binding.value.var_ref, "true");
                } else if (std.mem.eql(u8, attr_name, "follows") and binding.value.* == .string) {
                    var follows: std.ArrayList([]const u8) = .empty;
                    var parts = std.mem.splitScalar(u8, binding.value.string, '/');
                    while (parts.next()) |part| {
                        try follows.append(self.allocator, try self.allocator.dupe(u8, part));
                    }
                    input_result.value_ptr.follows = try follows.toOwnedSlice(self.allocator);
                }
            }

            // If no URL was specified, use the input name as an indirect ref
            if (input_result.value_ptr.ref.url.len == 0 and input_result.value_ptr.follows == null) {
                input_result.value_ptr.ref = try FlakeRef.parse(self.allocator, input_name);
            }
        }
    }

    fn parseInputAttrs(self: *FlakeEvaluator, input: *Flake.FlakeInput, attrs: Expr.Attrs) !void {
        for (attrs.bindings) |attr_binding| {
            const attr_key = try self.attrPathToString(attr_binding.key);
            defer self.allocator.free(attr_key);

            if (std.mem.eql(u8, attr_key, "url")) {
                if (attr_binding.value.* == .string) {
                    input.ref = try FlakeRef.parse(self.allocator, attr_binding.value.string);
                }
            } else if (std.mem.eql(u8, attr_key, "flake")) {
                if (attr_binding.value.* == .var_ref) {
                    input.is_flake = std.mem.eql(u8, attr_binding.value.var_ref, "true");
                }
            } else if (std.mem.eql(u8, attr_key, "follows")) {
                if (attr_binding.value.* == .string) {
                    var follows: std.ArrayList([]const u8) = .empty;
                    var parts = std.mem.splitScalar(u8, attr_binding.value.string, '/');
                    while (parts.next()) |part| {
                        try follows.append(self.allocator, try self.allocator.dupe(u8, part));
                    }
                    input.follows = try follows.toOwnedSlice(self.allocator);
                }
            }
        }
    }

    /// Resolve all inputs and evaluate the flake
    pub fn resolve(self: *FlakeEvaluator, io: std.Io, flake: Flake, progress_node: std.Progress.Node) !ResolvedFlake {
        return self.resolveWithParent(io, flake, progress_node, null, null, 0, null);
    }

    /// Resolve all inputs, with access to parent resolved inputs for follows
    fn resolveWithParent(
        self: *FlakeEvaluator,
        io: std.Io,
        flake: Flake,
        progress_node: std.Progress.Node,
        parent_inputs: ?*const std.StringHashMap(ResolvedFlake.ResolvedInput),
        parent_overrides: ?*const std.StringHashMap([]const []const u8),
        depth: usize,
        visited: ?*std.ArrayList([]const u8),
    ) !ResolvedFlake {
        if (depth > 32) return error.InvalidFlake;
        // Ensure we have a visited map for cycle detection. If none provided,
        // create a temporary one that lives for the duration of this call.
        var own_visited: std.ArrayList([]const u8) = .empty;
        var visited_ptr: *std.ArrayList([]const u8) = undefined;
        var created_local_visited: bool = false;
        if (visited) |v| {
            visited_ptr = v;
        } else {
            own_visited = .empty;
            visited_ptr = &own_visited;
            created_local_visited = true;
        }
        // (No global visited tracking here) — keep simple for now.
        var resolved = ResolvedFlake{
            .flake = flake,
            .inputs = std.StringHashMap(ResolvedFlake.ResolvedInput).init(self.allocator),
            .outputs = null,
            .allocator = self.allocator,
        };
        errdefer resolved.deinit();
        if (created_local_visited) {
            defer visited_ptr.deinit(self.allocator);
        }

        const fetch_node = progress_node.start("Fetching inputs", flake.inputs.count());
        defer fetch_node.end();

        // First pass: resolve non-follows inputs (ones that need fetching)
        var iter = flake.inputs.iterator();
        while (iter.next()) |entry| {
            const input_name = entry.key_ptr.*;
            const input = entry.value_ptr.*;

            // Skip follows inputs for now - resolve them in second pass
            if (input.follows != null) {
                continue;
            }

            // Resolve indirect refs through registry
            var ref = input.ref;
            if (ref.type == .indirect) {
                if (self.registry.resolve(ref.url)) |resolved_ref| {
                    ref = resolved_ref;
                }
            }

            // Fetch the input
            const fetch_result = self.fetcher.fetch(io, &ref, flake.path, fetch_node, self.allocator) catch |err| {
                std.debug.print("Failed to fetch input '{s}': {}\n", .{ input_name, err });
                fetch_node.completeOne();
                continue;
            };
            fetch_node.completeOne();

            var resolved_input = ResolvedFlake.ResolvedInput{
                .flake = null,
                .source_path = fetch_result.path,
                .rev = fetch_result.rev,
            };

            // Load as a sub-flake if it has flake.nix and is_flake is true
            if (input.is_flake) {
                const input_flake_path = std.fs.path.join(self.allocator, &.{ fetch_result.path, "flake.nix" }) catch {
                    try resolved.inputs.put(input_name, resolved_input);
                    continue;
                };
                defer self.allocator.free(input_flake_path);

                const has_flake = blk: {
                    _ = std.Io.Dir.statFile(.cwd(), io, input_flake_path, .{}) catch break :blk false;
                    break :blk true;
                };

                if (has_flake) {
                    const sub_overrides = flake.input_overrides.getPtr(input_name);

                    // If this source path is already in the visited set, avoid
                    // recursing to prevent cycles. Try to reuse an existing
                    // resolved flake from current or parent inputs instead.
                    const is_visited = std.mem.eql(u8, fetch_result.path, flake.path);
                    if (is_visited) {
                        var reused: ?*ResolvedFlake = null;
                        var piter2 = resolved.inputs.iterator();
                        while (piter2.next()) |pentry2| {
                            if (std.mem.eql(u8, pentry2.value_ptr.source_path, fetch_result.path)) {
                                reused = pentry2.value_ptr.flake;
                                break;
                            }
                        }
                        if (reused) |r| {
                            resolved_input.flake = r;
                            resolved_input.owns_flake = false;
                        } else if (parent_inputs) |pmap| {
                            var piter = pmap.iterator();
                            while (piter.next()) |pentry| {
                                if (std.mem.eql(u8, pentry.value_ptr.source_path, fetch_result.path)) {
                                    resolved_input.flake = pentry.value_ptr.flake;
                                    resolved_input.owns_flake = false;
                                    break;
                                }
                            }
                        } else {
                            // No existing resolved flake found; skip recursion.
                            resolved_input.flake = null;
                        }
                    } else {
                        const input_flake = self.loadFlakeWithIo(io, fetch_result.path) catch null;
                        if (input_flake) |fl| {
                            if (parent_inputs) |pmap| {
                                var piter = pmap.iterator();
                                var reused: ?*ResolvedFlake = null;
                                while (piter.next()) |pentry| {
                                    if (std.mem.eql(u8, pentry.value_ptr.source_path, fetch_result.path)) {
                                        reused = pentry.value_ptr.flake;
                                        break;
                                    }
                                }

                                if (reused) |r| {
                                    resolved_input.flake = r;
                                    resolved_input.owns_flake = false;
                                } else {
                                    const resolved_fl = try self.allocator.create(ResolvedFlake);
                                    resolved_fl.* = try self.resolveWithParent(io, fl, fetch_node, &resolved.inputs, sub_overrides, depth + 1, visited_ptr);
                                    resolved_input.flake = resolved_fl;
                                    resolved_input.owns_flake = true;
                                }
                            } else {
                                const resolved_fl = try self.allocator.create(ResolvedFlake);
                                resolved_fl.* = try self.resolveWithParent(io, fl, fetch_node, &resolved.inputs, sub_overrides, depth + 1, visited_ptr);
                                resolved_input.flake = resolved_fl;
                                resolved_input.owns_flake = true;
                            }
                        }
                    }
                }
            }

            try resolved.inputs.put(input_name, resolved_input);
        }

        // Second pass: resolve follows inputs
        iter = flake.inputs.iterator();
        while (iter.next()) |entry| {
            const input_name = entry.key_ptr.*;
            const input = entry.value_ptr.*;

            if (input.follows) |follows_path| {
                if (follows_path.len == 0) {
                    // Empty follows = don't include this input
                    fetch_node.completeOne();
                    continue;
                }

                // Look up the followed input
                // follows_path[0] refers to a sibling input name
                // For nested follows, we'd walk the path through resolved flakes
                if (self.resolveFollows(&resolved, parent_inputs, follows_path)) |followed| {
                    try resolved.inputs.put(input_name, ResolvedFlake.ResolvedInput{
                        .flake = followed.flake,
                        .source_path = try self.allocator.dupe(u8, followed.source_path),
                        .rev = if (followed.rev) |r| try self.allocator.dupe(u8, r) else null,
                    });
                }
                fetch_node.completeOne();
            }
        }

        // Apply parent overrides: these are follows directives from the parent flake
        // that redirect our inputs to the parent's resolved inputs
        // e.g., parent has inputs.flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs"
        // parent_overrides maps "nixpkgs-lib" -> ["nixpkgs"]
        if (parent_overrides) |overrides| {
            var po_iter = overrides.iterator();
            while (po_iter.next()) |po_entry| {
                const sub_input_name = po_entry.key_ptr.*;
                const follows_path = po_entry.value_ptr.*;

                if (follows_path.len == 0) {
                    // Empty follows = remove this input
                    _ = resolved.inputs.fetchRemove(sub_input_name);
                } else if (parent_inputs) |pi| {
                    // Resolve follows path against the parent's resolved inputs
                    if (pi.getPtr(follows_path[0])) |followed| {
                        // Walk remaining path components if any
                        var current_input = followed;
                        var found = true;
                        for (follows_path[1..]) |component| {
                            if (current_input.flake) |sub_fl| {
                                if (sub_fl.inputs.getPtr(component)) |next| {
                                    current_input = next;
                                } else {
                                    found = false;
                                    break;
                                }
                            } else {
                                found = false;
                                break;
                            }
                        }
                        if (found) {
                            try resolved.inputs.put(sub_input_name, ResolvedFlake.ResolvedInput{
                                .flake = current_input.flake,
                                .source_path = try self.allocator.dupe(u8, current_input.source_path),
                                .rev = if (current_input.rev) |r| try self.allocator.dupe(u8, r) else null,
                            });
                        }
                    }
                }
            }
        }

        // Sub-flake outputs are evaluated on demand in evalOutputs
        // when they are accessed via the inputs attrset

        return resolved;
    }
    /// Resolve a follows path to find the target resolved input
    fn resolveFollows(
        self: *FlakeEvaluator,
        resolved: *const ResolvedFlake,
        parent_inputs: ?*const std.StringHashMap(ResolvedFlake.ResolvedInput),
        follows_path: []const []const u8,
    ) ?*const ResolvedFlake.ResolvedInput {
        _ = self;
        if (follows_path.len == 0) return null;

        // Start by looking up the first component in the current flake's resolved inputs
        var current: ?*const ResolvedFlake.ResolvedInput = resolved.inputs.getPtr(follows_path[0]);

        // If not found locally, try parent inputs
        if (current == null) {
            if (parent_inputs) |pi| {
                current = pi.getPtr(follows_path[0]);
            }
        }

        if (current == null) return null;

        // Walk remaining path components through nested flakes
        for (follows_path[1..]) |component| {
            if (current.?.flake) |sub_fl| {
                current = sub_fl.inputs.getPtr(component);
                if (current == null) return null;
            } else {
                return null;
            }
        }

        return current;
    }

    /// Evaluate the flake outputs
    pub fn evalOutputs(self: *FlakeEvaluator, resolved: *ResolvedFlake) !Value {
        // Build the inputs attrset to pass to the outputs function
        // Parent must be global_env so builtins like `import` are accessible
        // Use the evaluator's arena allocator so it gets cleaned up automatically
        var inputs_env = try self.evaluator.createEnv(self.evaluator.global_env);

        // Add self
        const eval_alloc = self.evaluator.alloc();
        var self_attrs = std.StringHashMap(Value).init(eval_alloc);
        try self_attrs.put("outPath", Value{ .path = resolved.flake.path });
        try inputs_env.define("self", Value{ .attrs = .{ .bindings = self_attrs } });

        // Add each resolved input
        var iter = resolved.inputs.iterator();
        while (iter.next()) |entry| {
            const name = entry.key_ptr.*;
            const input = entry.value_ptr.*;

            var input_attrs = std.StringHashMap(Value).init(eval_alloc);
            try input_attrs.put("outPath", Value{ .path = input.source_path });
            if (input.rev) |r| {
                try input_attrs.put("rev", Value{ .string = r });
            }

            // If the input is a flake, evaluate its outputs and merge them
            if (input.flake) |fl| {
                if (fl.outputs) |outputs| {
                    // Already evaluated - merge outputs into input attrs
                    if (outputs == .attrs) {
                        var out_iter = outputs.attrs.bindings.iterator();
                        while (out_iter.next()) |out_entry| {
                            try input_attrs.put(out_entry.key_ptr.*, out_entry.value_ptr.*);
                        }
                    }
                } else {
                    // Evaluate sub-flake outputs recursively
                    const sub_outputs = self.evalOutputs(fl) catch |err| blk: {
                        std.debug.print("Warning: failed to eval outputs for sub-flake '{s}': {}\n", .{ name, err });
                        if (@errorReturnTrace()) |trace| {
                            std.debug.dumpErrorReturnTrace(trace);
                        }
                        break :blk Value{ .attrs = .{ .bindings = std.StringHashMap(Value).init(eval_alloc) } };
                    };
                    if (sub_outputs == .attrs) {
                        var out_iter = sub_outputs.attrs.bindings.iterator();
                        while (out_iter.next()) |out_entry| {
                            try input_attrs.put(out_entry.key_ptr.*, out_entry.value_ptr.*);
                        }
                    }
                }
            }

            try inputs_env.define(name, Value{ .attrs = .{ .bindings = input_attrs } });
        }

        // The outputs expression should be a lambda
        if (resolved.flake.outputs_expr) |outputs_expr| {
            const outputs_raw = try self.evaluator.evalInEnv(outputs_expr.*, inputs_env);
            const outputs_val = try self.evaluator.force(outputs_raw);

            // If it's a lambda, call it with inputs
            if (outputs_val == .lambda) {
                const inputs_val = try self.buildInputsValue(resolved);
                const result = self.evaluator.apply(outputs_val, inputs_val) catch |err| {
                    return err;
                };
                resolved.outputs = result;
                return result;
            }

            resolved.outputs = outputs_val;
            return outputs_val;
        }

        return Value{ .null_val = {} };
    }

    fn buildInputsValue(self: *FlakeEvaluator, resolved: *ResolvedFlake) !Value {
        const eval_alloc = self.evaluator.alloc();
        var inputs_attrs = std.StringHashMap(Value).init(eval_alloc);

        // Add self
        var self_attrs = std.StringHashMap(Value).init(eval_alloc);
        try self_attrs.put("outPath", Value{ .path = resolved.flake.path });
        try inputs_attrs.put("self", Value{ .attrs = .{ .bindings = self_attrs } });

        // Add each input (with sub-flake outputs merged in)
        var iter = resolved.inputs.iterator();
        while (iter.next()) |entry| {
            var input_attrs = std.StringHashMap(Value).init(eval_alloc);
            try input_attrs.put("outPath", Value{ .path = entry.value_ptr.source_path });
            if (entry.value_ptr.rev) |r| {
                try input_attrs.put("rev", Value{ .string = r });
            }

            // Merge sub-flake outputs
            if (entry.value_ptr.flake) |fl| {
                if (fl.outputs) |outputs| {
                    if (outputs == .attrs) {
                        var out_iter = outputs.attrs.bindings.iterator();
                        while (out_iter.next()) |out_entry| {
                            try input_attrs.put(out_entry.key_ptr.*, out_entry.value_ptr.*);
                        }
                    }
                }
            }

            try inputs_attrs.put(entry.key_ptr.*, Value{ .attrs = .{ .bindings = input_attrs } });
        }

        return Value{ .attrs = .{ .bindings = inputs_attrs } };
    }

    /// Select an attribute path from flake outputs
    /// e.g., "legacyPackages.x86_64-linux.hello"
    pub fn selectOutput(self: *FlakeEvaluator, outputs: Value, attr_path: []const u8) !Value {
        var current = outputs;
        var parts = std.mem.splitScalar(u8, attr_path, '.');

        while (parts.next()) |part| {
            // Force thunks
            current = try self.evaluator.force(current);

            if (current != .attrs) {
                return error.NotAnAttrSet;
            }

            if (current.attrs.bindings.get(part)) |val| {
                current = val;
            } else {
                return error.AttributeNotFound;
            }
        }

        return self.evaluator.force(current);
    }

    /// Build a package from the flake
    pub fn build(self: *FlakeEvaluator, io: std.Io, flake_ref: []const u8, attr_path: []const u8) ![]const u8 {
        // Parse the flake reference (e.g., "." or "github:NixOS/nixpkgs")
        var ref = try FlakeRef.parse(self.parent_allocator, flake_ref);
        defer ref.deinit();

        // Resolve the path (use parent allocator for temporary ref resolution)
        const flake_path = try ref.resolve(self.parent_allocator, ".");
        defer self.parent_allocator.free(flake_path);

        // Load the flake
        const fl = try self.loadFlakeWithIo(io, flake_path);

        // Resolve inputs with progress
        var resolved = resolve_blk: {
            var draw_buffer: [4096]u8 = undefined;
            const progress_root = std.Progress.start(io, .{
                .draw_buffer = &draw_buffer,
            });
            defer progress_root.end();
            break :resolve_blk try self.resolve(io, fl, progress_root);
        };
        defer resolved.deinit();

        // Evaluate outputs
        const outputs = try self.evalOutputs(&resolved);

        // Select the requested output
        const selected = try self.selectOutput(outputs, attr_path);

        // Check if it's a derivation
        if (selected == .attrs) {
            if (selected.attrs.bindings.get("type")) |type_val| {
                if (type_val == .string and std.mem.eql(u8, type_val.string, "derivation")) {
                    // Build the derivation
                    return self.buildDerivation(selected);
                }
            }

            // Check for drvPath attribute
            if (selected.attrs.bindings.get("drvPath")) |drv_path_val| {
                if (drv_path_val == .path or drv_path_val == .string) {
                    const drv_path = if (drv_path_val == .path) drv_path_val.path else drv_path_val.string;
                    std.debug.print("Would build: {s}\n", .{drv_path});
                    return try self.allocator.dupe(u8, drv_path);
                }
            }
        }

        return error.NotADerivation;
    }

    fn buildDerivation(self: *FlakeEvaluator, drv_val: Value) ![]const u8 {
        if (drv_val != .attrs) return error.NotADerivation;

        // Extract derivation attributes
        var drv = store.Derivation.init(self.allocator);
        defer drv.deinit();

        if (drv_val.attrs.bindings.get("name")) |v| {
            if (v == .string) drv.name = v.string;
        }
        if (drv_val.attrs.bindings.get("system")) |v| {
            if (v == .string) drv.system = v.string;
        }
        if (drv_val.attrs.bindings.get("builder")) |v| {
            if (v == .string or v == .path) {
                drv.builder = if (v == .string) v.string else v.path;
            }
        }

        // Build using the store
        return self.nix_store.buildDerivation(self.evaluator.io, &drv);
    }
};

test "flake evaluator init" {
    const allocator = std.testing.allocator;
    var io = std.Io.Threaded.init(allocator, .{ .environ = .empty });

    var fe = try FlakeEvaluator.init(allocator, io.io());
    defer fe.deinit();

    try std.testing.expect(fe.registry.entries.count() > 0);
}
