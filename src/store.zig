const std = @import("std");
const builtin = @import("builtin");

/// A Nix store path like /nix/store/<hash>-<name>
pub const StorePath = struct {
    hash: [32]u8,
    name: []const u8,
    allocator: std.mem.Allocator,

    const STORE_DIR = "/nix/store";
    const HASH_LEN = 32;

    pub fn init(allocator: std.mem.Allocator, hash: [32]u8, name: []const u8) !StorePath {
        return StorePath{
            .hash = hash,
            .name = try allocator.dupe(u8, name),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *StorePath) void {
        self.allocator.free(self.name);
    }

    pub fn toPath(self: StorePath, allocator: std.mem.Allocator) ![]u8 {
        return self.toPathIn(allocator, STORE_DIR);
    }

    /// Same as `toPath` but rooted at an arbitrary store directory instead
    /// of the hard-coded `/nix/store`.
    pub fn toPathIn(self: StorePath, allocator: std.mem.Allocator, store_dir: []const u8) ![]u8 {
        // Base32 encode the hash (Nix uses a custom base32)
        var hash_str: [52]u8 = undefined;
        encodeBase32(&self.hash, &hash_str);
        return std.fmt.allocPrint(allocator, "{s}/{s}-{s}", .{ store_dir, hash_str, self.name });
    }

    /// Nix's custom base32 encoding
    fn encodeBase32(input: *const [32]u8, output: *[52]u8) void {
        const alphabet = "0123456789abcdfghijklmnpqrsvwxyz";
        var bits: u64 = 0;
        var bit_count: u6 = 0;
        var out_idx: usize = 51;

        for (input) |byte| {
            bits |= @as(u64, byte) << bit_count;
            bit_count += 8;

            while (bit_count >= 5) {
                output[out_idx] = alphabet[@as(usize, @truncate(bits & 0x1f))];
                if (out_idx > 0) out_idx -= 1;
                bits >>= 5;
                bit_count -= 5;
            }
        }

        if (bit_count > 0) {
            output[out_idx] = alphabet[@as(usize, @truncate(bits & 0x1f))];
        }
    }
};

/// A derivation - a build recipe
pub const Derivation = struct {
    name: []const u8,
    system: []const u8,
    builder: []const u8,
    args: []const []const u8,
    env: std.StringHashMap([]const u8),
    input_drvs: std.StringHashMap([]const []const u8),
    input_srcs: std.ArrayList([]const u8),
    outputs: std.StringHashMap(DerivationOutput),
    allocator: std.mem.Allocator,

    pub const DerivationOutput = struct {
        path: ?[]const u8,
        hash_algo: ?[]const u8,
        hash: ?[]const u8,
    };

    pub fn init(allocator: std.mem.Allocator) Derivation {
        return Derivation{
            .name = "",
            .system = "",
            .builder = "",
            .args = &.{},
            .env = std.StringHashMap([]const u8).init(allocator),
            .input_drvs = std.StringHashMap([]const []const u8).init(allocator),
            .input_srcs = .empty,
            .outputs = std.StringHashMap(DerivationOutput).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Derivation) void {
        self.env.deinit();
        self.input_drvs.deinit();
        self.input_srcs.deinit(self.allocator);
        self.outputs.deinit();
    }

    /// Serialize to ATerm format (.drv file)
    pub fn serialize(self: *const Derivation, allocator: std.mem.Allocator) ![]u8 {
        var result: std.ArrayList(u8) = .empty;

        try result.appendSlice(allocator, "Derive([");

        // Outputs
        var first = true;
        var out_iter = self.outputs.iterator();
        while (out_iter.next()) |entry| {
            if (!first) try result.appendSlice(allocator, ",");
            first = false;
            var buf: [256]u8 = undefined;
            const s = try std.fmt.bufPrint(&buf, "(\"{s}\",\"{s}\",\"\",\"\")", .{
                entry.key_ptr.*,
                entry.value_ptr.path orelse "",
            });
            try result.appendSlice(allocator, s);
        }

        try result.appendSlice(allocator, "],[");

        // Input derivations
        first = true;
        var drv_iter = self.input_drvs.iterator();
        while (drv_iter.next()) |entry| {
            if (!first) try result.appendSlice(allocator, ",");
            first = false;
            var buf: [256]u8 = undefined;
            const prefix = try std.fmt.bufPrint(&buf, "(\"{s}\",[", .{entry.key_ptr.*});
            try result.appendSlice(allocator, prefix);
            for (entry.value_ptr.*, 0..) |out, i| {
                if (i > 0) try result.appendSlice(allocator, ",");
                const out_buf = try std.fmt.bufPrint(&buf, "\"{s}\"", .{out});
                try result.appendSlice(allocator, out_buf);
            }
            try result.appendSlice(allocator, "])");
        }

        try result.appendSlice(allocator, "],[");

        // Input sources
        for (self.input_srcs.items, 0..) |src, i| {
            if (i > 0) try result.appendSlice(allocator, ",");
            var buf: [256]u8 = undefined;
            const s = try std.fmt.bufPrint(&buf, "\"{s}\"", .{src});
            try result.appendSlice(allocator, s);
        }

        {
            var buf: [512]u8 = undefined;
            const s = try std.fmt.bufPrint(&buf, "],\"{s}\",\"{s}\",[", .{ self.system, self.builder });
            try result.appendSlice(allocator, s);
        }

        // Args
        for (self.args, 0..) |arg, i| {
            if (i > 0) try result.appendSlice(allocator, ",");
            var buf: [256]u8 = undefined;
            const s = try std.fmt.bufPrint(&buf, "\"{s}\"", .{arg});
            try result.appendSlice(allocator, s);
        }

        try result.appendSlice(allocator, "],[");

        // Environment
        first = true;
        var env_iter = self.env.iterator();
        while (env_iter.next()) |entry| {
            if (!first) try result.appendSlice(allocator, ",");
            first = false;
            var buf: [512]u8 = undefined;
            const s = try std.fmt.bufPrint(&buf, "(\"{s}\",\"{s}\")", .{ entry.key_ptr.*, entry.value_ptr.* });
            try result.appendSlice(allocator, s);
        }

        try result.appendSlice(allocator, "])");

        return result.toOwnedSlice(allocator);
    }

    /// Compute the store path for this derivation
    pub fn computeStorePath(self: *const Derivation, allocator: std.mem.Allocator) !StorePath {
        const drv_str = try self.serialize(allocator);
        defer allocator.free(drv_str);

        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(drv_str, &hash, .{});

        return StorePath.init(allocator, hash, self.name);
    }
};

/// The Nix store interface.
///
/// This is a minimal, local-filesystem implementation of a Nix-style
/// content-addressed store (inspired by nix-store / sqlite-zig's on-disk
/// layout). Fetched/derived content lives under `store_dir` in
/// `<hash>-<name>` directories, mirroring the real Nix store layout but
/// rooted at a project-local or user-local directory instead of `/nix/store`
/// so it works without root privileges.
pub const Store = struct {
    allocator: std.mem.Allocator,
    store_dir: []const u8,
    db_path: []const u8,
    owns_store_dir: bool,

    /// Default store root used when no explicit root is provided.
    pub const default_store_dir = ".zix-cache/store";

    pub fn init(allocator: std.mem.Allocator) Store {
        return Store{
            .allocator = allocator,
            .store_dir = default_store_dir,
            .db_path = ".zix-cache/store.db",
            .owns_store_dir = false,
        };
    }

    /// Create a store rooted at an explicit directory (e.g. a per-flake or
    /// XDG cache directory chosen by the caller). The returned Store owns
    /// (and will free) `store_dir`.
    pub fn initWithRoot(allocator: std.mem.Allocator, root_dir: []const u8) !Store {
        const store_dir = try std.fs.path.join(allocator, &.{ root_dir, "store" });
        const db_path = try std.fs.path.join(allocator, &.{ root_dir, "store.db" });
        return Store{
            .allocator = allocator,
            .store_dir = store_dir,
            .db_path = db_path,
            .owns_store_dir = true,
        };
    }

    pub fn deinit(self: *Store) void {
        if (self.owns_store_dir) {
            self.allocator.free(self.store_dir);
            self.allocator.free(self.db_path);
        }
    }


    /// Check if a store path exists on disk under this store's root.
    pub fn isValidPath(self: *Store, io: std.Io, path: []const u8) bool {
        _ = self;
        const Dir = std.Io.Dir;
        _ = Dir.statFile(.cwd(), io, path, .{}) catch return false;
        return true;
    }

    /// Add a path (file or directory) to the store: hash its contents,
    /// copy it into `<store_dir>/<hash>-<name>`, and return the resulting
    /// StorePath. If the destination already exists, the existing content
    /// is reused (content-addressed dedup).
    pub fn addToStore(self: *Store, io: std.Io, name: []const u8, src_path: []const u8) !StorePath {
        const Dir = std.Io.Dir;

        const stat = try Dir.statFile(.cwd(), io, src_path, .{});

        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(name);
        hasher.update(src_path);
        switch (stat.kind) {
            .file => {
                var file = try Dir.openFile(.cwd(), io, src_path, .{});
                defer file.close(io);
                var read_buf: [8192]u8 = undefined;
                var reader = file.reader(io, &read_buf);
                while (true) {
                    const chunk = reader.interface.take(read_buf.len) catch |err| switch (err) {
                        error.EndOfStream => break,
                        else => return err,
                    };
                    if (chunk.len == 0) break;
                    hasher.update(chunk);
                }
            },
            else => {
                // Directories and other kinds: hash by path/name only for now.
                // A full recursive NAR-style hash can be added later.
            },
        }
        var hash: [32]u8 = undefined;
        hasher.final(&hash);

        var store_path = try StorePath.init(self.allocator, hash, name);
        errdefer store_path.deinit();

        const dest_path = try store_path.toPathIn(self.allocator, self.store_dir);
        defer self.allocator.free(dest_path);

        if (!self.isValidPath(io, dest_path)) {
            try Dir.createDirPath(.cwd(), io, self.store_dir);
            switch (stat.kind) {
                .directory => {
                    Dir.rename(.cwd(), src_path, .cwd(), dest_path, io) catch {
                        try copyDirRecursive(io, src_path, dest_path);
                    };
                },
                else => {
                    try Dir.copyFile(.cwd(), src_path, .cwd(), dest_path, io, .{});
                },
            }
        }

        return store_path;
    }

    /// Build a derivation by invoking its builder as a subprocess with the
    /// declared environment and args, writing outputs into the store.
    pub fn buildDerivation(self: *Store, io: std.Io, drv: *const Derivation) ![]const u8 {
        // Compute output path
        const store_path = try drv.computeStorePath(self.allocator);
        defer @constCast(&store_path).deinit();

        const out_path = try store_path.toPathIn(self.allocator, self.store_dir);

        // Check if already built
        if (self.isValidPath(io, out_path)) {
            return out_path;
        }

        const Dir = std.Io.Dir;
        if (std.fs.path.dirname(out_path)) |parent| {
            try Dir.createDirPath(.cwd(), io, parent);
        }

        if (drv.builder.len == 0) {
            // Nothing to execute; just materialize an empty output directory
            // so downstream consumers have a stable path to reference.
            Dir.createDirPath(.cwd(), io, out_path) catch {};
            return out_path;
        }

        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(self.allocator);
        try argv.append(self.allocator, drv.builder);
        for (drv.args) |a| try argv.append(self.allocator, a);

        var env = std.process.Environ.Map.init(self.allocator);
        defer env.deinit();
        var env_iter = drv.env.iterator();
        while (env_iter.next()) |entry| {
            try env.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        try env.put("out", out_path);

        std.debug.print("Building {s} -> {s}\n", .{ drv.name, out_path });
        var child = std.process.spawn(io, .{
            .argv = argv.items,
            .environ_map = &env,
        }) catch |err| {
            std.debug.print("Build failed for {s}: {s}\n", .{ drv.name, @errorName(err) });
            return out_path;
        };
        _ = child.wait(io) catch |err| {
            std.debug.print("Build wait failed for {s}: {s}\n", .{ drv.name, @errorName(err) });
        };

        return out_path;
    }

    /// Query the outputs of a built derivation
    pub fn queryDerivationOutputs(self: *Store, drv_path: []const u8) ![]const []const u8 {
        _ = self;
        _ = drv_path;
        // Would query the database for output paths
        return &.{};
    }
};

/// Recursively copy a directory tree from src to dest.
fn copyDirRecursive(io: std.Io, src_path: []const u8, dest_path: []const u8) !void {
    const Dir = std.Io.Dir;
    const allocator = std.heap.page_allocator;

    try Dir.createDirPath(.cwd(), io, dest_path);
    var src_dir = try Dir.openDir(.cwd(), io, src_path, .{ .iterate = true });
    defer src_dir.close(io);

    var iter = src_dir.iterate();
    while (try iter.next(io)) |entry| {
        const child_src = try std.fs.path.join(allocator, &.{ src_path, entry.name });
        const child_dest = try std.fs.path.join(allocator, &.{ dest_path, entry.name });
        switch (entry.kind) {
            .directory => try copyDirRecursive(io, child_src, child_dest),
            .file => try Dir.copyFile(.cwd(), child_src, .cwd(), child_dest, io, .{}),
            else => {},
        }
    }
}

/// Get the current system string (e.g., "x86_64-linux")
pub fn getCurrentSystem() []const u8 {
    const arch = switch (builtin.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        .x86 => "i686",
        .arm => "armv7l",
        .riscv64 => "riscv64",
        else => "unknown",
    };

    const os = switch (builtin.os.tag) {
        .linux => "linux",
        .macos => "darwin",
        .freebsd => "freebsd",
        .windows => "windows",
        else => "unknown",
    };

    return arch ++ "-" ++ os;
}

test "store path encoding" {
    const allocator = std.testing.allocator;
    var hash: [32]u8 = undefined;
    @memset(&hash, 0xab);

    var sp = try StorePath.init(allocator, hash, "test");
    defer sp.deinit();

    const path = try sp.toPath(allocator);
    defer allocator.free(path);

    try std.testing.expect(std.mem.startsWith(u8, path, "/nix/store/"));
    try std.testing.expect(std.mem.endsWith(u8, path, "-test"));
}

test "derivation serialization" {
    const allocator = std.testing.allocator;
    var drv = Derivation.init(allocator);
    defer drv.deinit();

    drv.name = "hello";
    drv.system = "x86_64-linux";
    drv.builder = "/bin/sh";

    try drv.outputs.put("out", .{ .path = "/nix/store/xxx-hello", .hash_algo = null, .hash = null });

    const serialized = try drv.serialize(allocator);
    defer allocator.free(serialized);

    try std.testing.expect(std.mem.indexOf(u8, serialized, "Derive") != null);
}
