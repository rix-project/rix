const std = @import("std");
const FlakeRef = @import("flakeref.zig").FlakeRef;

/// A locked flake input with pinned revision info
pub const LockedInput = struct {
    original: FlakeRef,
    locked: FlakeRef,
    last_modified: ?i64,
    nar_hash: ?[]const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *LockedInput) void {
        self.original.deinit();
        self.locked.deinit();
        if (self.nar_hash) |h| self.allocator.free(h);
    }
};

/// A node in the lock file dependency tree
pub const LockNode = struct {
    inputs: std.StringHashMap(InputRef),
    allocator: std.mem.Allocator,

    pub const InputRef = union(enum) {
        /// Direct reference to another node by name
        node: []const u8,
        /// Path through other inputs (e.g., ["nixpkgs", "flake-utils"])
        follows: []const []const u8,
    };

    pub fn init(allocator: std.mem.Allocator) LockNode {
        return LockNode{
            .inputs = std.StringHashMap(InputRef).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *LockNode) void {
        self.inputs.deinit();
    }
};

/// The complete lock file structure (flake.lock)
pub const LockFile = struct {
    version: u32,
    root: []const u8,
    nodes: std.StringHashMap(LockFileNode),
    allocator: std.mem.Allocator,

    pub const LockFileNode = struct {
        flake_ref: ?FlakeRef,
        inputs: std.StringHashMap(LockNode.InputRef),
        locked: ?LockedInfo,
        original: ?OriginalInfo,

        pub const LockedInfo = struct {
            last_modified: ?i64,
            nar_hash: []const u8,
            owner: ?[]const u8,
            repo: ?[]const u8,
            rev: ?[]const u8,
            ref: ?[]const u8,
            type: []const u8,
        };

        pub const OriginalInfo = struct {
            owner: ?[]const u8,
            repo: ?[]const u8,
            ref: ?[]const u8,
            type: []const u8,
        };
    };

    pub fn init(allocator: std.mem.Allocator) !LockFile {
        return LockFile{
            .version = 7,
            .root = try allocator.dupe(u8, "root"),
            .nodes = std.StringHashMap(LockFileNode).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *LockFile) void {
        self.allocator.free(self.root);
        self.nodes.deinit();
    }

    /// Parse a flake.lock file (JSON format)
    pub fn parse(allocator: std.mem.Allocator, content: []const u8) !LockFile {
        var lock = try LockFile.init(allocator);
        errdefer lock.deinit();

        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) return error.InvalidLockFile;

        // Version
        if (root.object.get("version")) |v| {
            if (v == .integer) {
                lock.version = @intCast(v.integer);
            }
        }

        // Root reference
        if (root.object.get("root")) |r| {
            if (r == .string) {
                allocator.free(lock.root);
                lock.root = try allocator.dupe(u8, r.string);
            }
        }

        // Nodes
        if (root.object.get("nodes")) |nodes_val| {
            if (nodes_val == .object) {
                var iter = nodes_val.object.iterator();
                while (iter.next()) |entry| {
                    const name = entry.key_ptr.*;
                    const node_val = entry.value_ptr.*;

                    if (node_val == .object) {
                        var node = LockFileNode{
                            .flake_ref = null,
                            .inputs = std.StringHashMap(LockNode.InputRef).init(allocator),
                            .locked = null,
                            .original = null,
                        };

                        // Parse inputs
                        if (node_val.object.get("inputs")) |inputs_val| {
                            if (inputs_val == .object) {
                                var inp_iter = inputs_val.object.iterator();
                                while (inp_iter.next()) |inp_entry| {
                                    const inp_name = inp_entry.key_ptr.*;
                                    const inp_val = inp_entry.value_ptr.*;

                                    if (inp_val == .string) {
                                        try node.inputs.put(
                                            try allocator.dupe(u8, inp_name),
                                            .{ .node = try allocator.dupe(u8, inp_val.string) },
                                        );
                                    } else if (inp_val == .array) {
                                        var follows: std.ArrayList([]const u8) = .empty;
                                        for (inp_val.array.items) |item| {
                                            if (item == .string) {
                                                try follows.append(allocator, try allocator.dupe(u8, item.string));
                                            }
                                        }
                                        try node.inputs.put(
                                            try allocator.dupe(u8, inp_name),
                                            .{ .follows = try follows.toOwnedSlice(allocator) },
                                        );
                                    }
                                }
                            }
                        }

                        // Parse locked info
                        if (node_val.object.get("locked")) |locked_val| {
                            if (locked_val == .object) {
                                node.locked = .{
                                    .last_modified = if (locked_val.object.get("lastModified")) |lm|
                                        if (lm == .integer) lm.integer else null
                                    else
                                        null,
                                    .nar_hash = if (locked_val.object.get("narHash")) |nh|
                                        if (nh == .string) try allocator.dupe(u8, nh.string) else ""
                                    else
                                        "",
                                    .owner = if (locked_val.object.get("owner")) |o|
                                        if (o == .string) try allocator.dupe(u8, o.string) else null
                                    else
                                        null,
                                    .repo = if (locked_val.object.get("repo")) |r|
                                        if (r == .string) try allocator.dupe(u8, r.string) else null
                                    else
                                        null,
                                    .rev = if (locked_val.object.get("rev")) |r|
                                        if (r == .string) try allocator.dupe(u8, r.string) else null
                                    else
                                        null,
                                    .ref = if (locked_val.object.get("ref")) |r|
                                        if (r == .string) try allocator.dupe(u8, r.string) else null
                                    else
                                        null,
                                    .type = if (locked_val.object.get("type")) |t|
                                        if (t == .string) try allocator.dupe(u8, t.string) else "path"
                                    else
                                        "path",
                                };
                            }
                        }

                        try lock.nodes.put(try allocator.dupe(u8, name), node);
                    }
                }
            }
        }

        return lock;
    }

    /// Serialize to JSON
    pub fn serialize(self: *const LockFile, allocator: std.mem.Allocator) ![]u8 {
        var result = std.ArrayList(u8).init(allocator);
        const writer = result.writer();

        try writer.writeAll("{\n");
        try writer.print("  \"version\": {},\n", .{self.version});
        try writer.print("  \"root\": \"{s}\",\n", .{self.root});
        try writer.writeAll("  \"nodes\": {\n");

        var first_node = true;
        var iter = self.nodes.iterator();
        while (iter.next()) |entry| {
            if (!first_node) try writer.writeAll(",\n");
            first_node = false;

            try writer.print("    \"{s}\": {{\n", .{entry.key_ptr.*});

            // Inputs
            if (entry.value_ptr.inputs.count() > 0) {
                try writer.writeAll("      \"inputs\": {\n");
                var first_input = true;
                var inp_iter = entry.value_ptr.inputs.iterator();
                while (inp_iter.next()) |inp_entry| {
                    if (!first_input) try writer.writeAll(",\n");
                    first_input = false;

                    switch (inp_entry.value_ptr.*) {
                        .node => |n| try writer.print("        \"{s}\": \"{s}\"", .{ inp_entry.key_ptr.*, n }),
                        .follows => |f| {
                            try writer.print("        \"{s}\": [", .{inp_entry.key_ptr.*});
                            for (f, 0..) |part, i| {
                                if (i > 0) try writer.writeAll(", ");
                                try writer.print("\"{s}\"", .{part});
                            }
                            try writer.writeAll("]");
                        },
                    }
                }
                try writer.writeAll("\n      }");
            }

            // Locked info
            if (entry.value_ptr.locked) |locked| {
                if (entry.value_ptr.inputs.count() > 0) try writer.writeAll(",\n");
                try writer.writeAll("      \"locked\": {\n");
                try writer.print("        \"type\": \"{s}\"", .{locked.type});
                if (locked.owner) |o| try writer.print(",\n        \"owner\": \"{s}\"", .{o});
                if (locked.repo) |r| try writer.print(",\n        \"repo\": \"{s}\"", .{r});
                if (locked.rev) |r| try writer.print(",\n        \"rev\": \"{s}\"", .{r});
                if (locked.ref) |r| try writer.print(",\n        \"ref\": \"{s}\"", .{r});
                if (locked.last_modified) |lm| try writer.print(",\n        \"lastModified\": {}", .{lm});
                try writer.print(",\n        \"narHash\": \"{s}\"\n", .{locked.nar_hash});
                try writer.writeAll("      }");
            }

            try writer.writeAll("\n    }");
        }

        try writer.writeAll("\n  }\n}\n");

        return result.toOwnedSlice();
    }
};

test "parse empty lock file" {
    const allocator = std.testing.allocator;
    const content =
        \\{
        \\  "version": 7,
        \\  "root": "root",
        \\  "nodes": {}
        \\}
    ;

    var lock = try LockFile.parse(allocator, content);
    defer lock.deinit();

    try std.testing.expectEqual(@as(u32, 7), lock.version);
}
