const std = @import("std");

/// A flake reference - identifies a flake source
pub const FlakeRef = struct {
    type: Type,
    url: []const u8,
    rev: ?[]const u8,
    ref: ?[]const u8,
    dir: ?[]const u8,
    allocator: std.mem.Allocator,

    pub const Type = enum {
        path,
        git,
        github,
        gitlab,
        tarball,
        indirect,
    };

    pub fn init(allocator: std.mem.Allocator) FlakeRef {
        return FlakeRef{
            .type = .path,
            .url = "",
            .rev = null,
            .ref = null,
            .dir = null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *FlakeRef) void {
        if (self.url.len > 0) {
            self.allocator.free(@constCast(self.url));
        }
        if (self.rev) |r| self.allocator.free(@constCast(r));
        if (self.ref) |r| self.allocator.free(@constCast(r));
        if (self.dir) |d| self.allocator.free(@constCast(d));
    }

    /// Parse a flake reference string like:
    /// - "." or "./path" or "/absolute/path" (path)
    /// - "github:owner/repo" or "github:owner/repo/rev"
    /// - "git+https://..." or "git+ssh://..."
    /// - "https://..." (tarball)
    /// - "nixpkgs" (indirect, resolved via registry)
    pub fn parse(allocator: std.mem.Allocator, input: []const u8) !FlakeRef {
        var ref = FlakeRef.init(allocator);
        errdefer ref.deinit();

        // Path references
        if (input.len == 0 or input[0] == '.' or input[0] == '/') {
            ref.type = .path;
            ref.url = try allocator.dupe(u8, if (input.len == 0) "." else input);
            var _sum: u32 = 0;
            for (ref.url) |c| _sum += @as(u32, c);
            std.debug.print("[flakeref] parse.path -> url (len={d} sum={d} ptr={*})\n", .{ ref.url.len, _sum, ref.url.ptr });
            return ref;
        }

        // github:owner/repo[/...][?rev=...&ref=...&dir=...]
        if (std.mem.startsWith(u8, input, "github:")) {
            ref.type = .github;
            const rest = input["github:".len..];

            // Parse owner and repo
            var parts = std.mem.splitScalar(u8, rest, '/');
            const owner = parts.next() orelse return error.InvalidFlakeRef;
            const repo = parts.next() orelse return error.InvalidFlakeRef;

            // Remaining path components (if any) are part of the ref/dir
            const remaining = parts.rest();
            if (remaining.len > 0) {
                // Check for query params in the remaining segment
                if (std.mem.indexOf(u8, remaining, "?")) |q_idx| {
                    const maybe_ref = remaining[0..q_idx];
                    if (maybe_ref.len > 0) ref.ref = try allocator.dupe(u8, maybe_ref);

                    const query = remaining[q_idx + 1 ..];
                    var params = std.mem.splitScalar(u8, query, '&');
                    while (params.next()) |param| {
                        if (std.mem.indexOf(u8, param, "=")) |eq_idx| {
                            const key = param[0..eq_idx];
                            const value = param[eq_idx + 1 ..];
                            if (std.mem.eql(u8, key, "rev")) {
                                ref.rev = try allocator.dupe(u8, value);
                            } else if (std.mem.eql(u8, key, "ref")) {
                                ref.ref = try allocator.dupe(u8, value);
                            } else if (std.mem.eql(u8, key, "dir")) {
                                ref.dir = try allocator.dupe(u8, value);
                            }
                        }
                    }
                } else {
                    // No query params: treat the entire remaining path as the ref
                    ref.ref = try allocator.dupe(u8, remaining);
                }
            }

            // Base URL is just owner/repo
            ref.url = try std.fmt.allocPrint(allocator, "https://github.com/{s}/{s}", .{ owner, repo });
            if (ref.ref) |r| {
                var _sum_ref: u32 = 0;
                for (r) |c| _sum_ref += @as(u32, c);
                std.debug.print("[flakeref] parse.github -> ref (len={d} sum={d} ptr={*})\n", .{ r.len, _sum_ref, r.ptr });
            }
            return ref;
        }

        // gitlab:owner/repo
        if (std.mem.startsWith(u8, input, "gitlab:")) {
            ref.type = .gitlab;
            const rest = input["gitlab:".len..];
            var parts = std.mem.splitScalar(u8, rest, '/');
            const owner = parts.next() orelse return error.InvalidFlakeRef;
            const repo = parts.next() orelse return error.InvalidFlakeRef;
            ref.url = try std.fmt.allocPrint(allocator, "https://gitlab.com/{s}/{s}", .{ owner, repo });
            var _sum_url: u32 = 0;
            for (ref.url) |c| _sum_url += @as(u32, c);
            std.debug.print("[flakeref] parse.gitlab -> url (len={d} sum={d} ptr={*})\n", .{ ref.url.len, _sum_url, ref.url.ptr });
            return ref;
        }

        // git+https:// or git+ssh://
        if (std.mem.startsWith(u8, input, "git+")) {
            ref.type = .git;
            const url_part = input["git+".len..];

            // Check for query params
            if (std.mem.indexOf(u8, url_part, "?")) |q_idx| {
                ref.url = try allocator.dupe(u8, url_part[0..q_idx]);
                var _sum_url_part: u32 = 0;
                for (ref.url) |c| _sum_url_part += @as(u32, c);
                std.debug.print("[flakeref] parse.git -> url (len={d} sum={d} ptr={*})\n", .{ ref.url.len, _sum_url_part, ref.url.ptr });
                const query = url_part[q_idx + 1 ..];
                var params = std.mem.splitScalar(u8, query, '&');
                while (params.next()) |param| {
                    if (std.mem.indexOf(u8, param, "=")) |eq_idx| {
                        const key = param[0..eq_idx];
                        const value = param[eq_idx + 1 ..];
                        if (std.mem.eql(u8, key, "rev")) {
                            ref.rev = try allocator.dupe(u8, value);
                        } else if (std.mem.eql(u8, key, "ref")) {
                            ref.ref = try allocator.dupe(u8, value);
                        } else if (std.mem.eql(u8, key, "dir")) {
                            ref.dir = try allocator.dupe(u8, value);
                        }
                    }
                }
            } else {
                ref.url = try allocator.dupe(u8, url_part);
                var _sum_url_part2: u32 = 0;
                for (ref.url) |c| _sum_url_part2 += @as(u32, c);
                std.debug.print("[flakeref] parse.git -> url (len={d} sum={d} ptr={*})\n", .{ ref.url.len, _sum_url_part2, ref.url.ptr });
            }
            return ref;
        }

        // https:// tarball
        if (std.mem.startsWith(u8, input, "https://") or std.mem.startsWith(u8, input, "http://")) {
            ref.type = .tarball;
            ref.url = try allocator.dupe(u8, input);
            var _sum_tarball: u32 = 0;
            for (ref.url) |c| _sum_tarball += @as(u32, c);
            std.debug.print("[flakeref] parse.tarball -> url (len={d} sum={d} ptr={*})\n", .{ ref.url.len, _sum_tarball, ref.url.ptr });
            return ref;
        }

        // Indirect reference (e.g., "nixpkgs")
        ref.type = .indirect;
        ref.url = try allocator.dupe(u8, input);
        var _sum_indirect: u32 = 0;
        for (ref.url) |c| _sum_indirect += @as(u32, c);
        std.debug.print("[flakeref] parse.indirect -> url (len={d} sum={d} ptr={*})\n", .{ ref.url.len, _sum_indirect, ref.url.ptr });
        return ref;
    }

    /// Convert back to string representation
    pub fn toString(self: *const FlakeRef, allocator: std.mem.Allocator) ![]u8 {
        var result: std.ArrayList(u8) = .empty;

        switch (self.type) {
            .path => try result.appendSlice(allocator, self.url),
            .github => {
                try result.appendSlice(allocator, "github:");
                // Extract owner/repo from URL
                if (std.mem.indexOf(u8, self.url, "github.com/")) |idx| {
                    try result.appendSlice(allocator, self.url[idx + "github.com/".len ..]);
                }
            },
            .gitlab => {
                try result.appendSlice(allocator, "gitlab:");
                if (std.mem.indexOf(u8, self.url, "gitlab.com/")) |idx| {
                    try result.appendSlice(allocator, self.url[idx + "gitlab.com/".len ..]);
                }
            },
            .git => {
                try result.appendSlice(allocator, "git+");
                try result.appendSlice(allocator, self.url);
            },
            .tarball => try result.appendSlice(allocator, self.url),
            .indirect => try result.appendSlice(allocator, self.url),
        }

        // Add query params
        var has_query = false;
        if (self.rev) |rev| {
            try result.append(allocator, if (has_query) '&' else '?');
            try result.appendSlice(allocator, "rev=");
            try result.appendSlice(allocator, rev);
            has_query = true;
        }
        if (self.ref) |ref| {
            try result.append(allocator, if (has_query) '&' else '?');
            try result.appendSlice(allocator, "ref=");
            try result.appendSlice(allocator, ref);
            has_query = true;
        }
        if (self.dir) |dir| {
            try result.append(allocator, if (has_query) '&' else '?');
            try result.appendSlice(allocator, "dir=");
            try result.appendSlice(allocator, dir);
        }

        return result.toOwnedSlice(allocator);
    }

    /// Resolve the flake reference to an absolute path
    pub fn resolve(self: *const FlakeRef, allocator: std.mem.Allocator, base_path: []const u8) ![]u8 {
        switch (self.type) {
            .path => {
                if (self.url.len > 0 and self.url[0] == '/') {
                    return allocator.dupe(u8, self.url);
                }
                // Relative path
                return std.fs.path.join(allocator, &.{ base_path, self.url });
            },
            else => {
                // Would need to fetch
                return error.NotImplemented;
            },
        }
    }
};

/// Registry for resolving indirect flake references
pub const Registry = struct {
    entries: std.StringHashMap(FlakeRef),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Registry {
        return Registry{
            .entries = std.StringHashMap(FlakeRef).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Registry) void {
        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            @constCast(entry.value_ptr).deinit();
        }
        self.entries.deinit();
    }

    /// Load the default registry with common flake mappings
    pub fn loadDefaults(self: *Registry) !void {
        // nixpkgs -> github:NixOS/nixpkgs
        const nixpkgs = try FlakeRef.parse(self.allocator, "github:NixOS/nixpkgs");
        try self.entries.put("nixpkgs", nixpkgs);

        // flake-utils -> github:numtide/flake-utils
        const flake_utils = try FlakeRef.parse(self.allocator, "github:numtide/flake-utils");
        try self.entries.put("flake-utils", flake_utils);

        // home-manager -> github:nix-community/home-manager
        const home_manager = try FlakeRef.parse(self.allocator, "github:nix-community/home-manager");
        try self.entries.put("home-manager", home_manager);
    }

    /// Resolve an indirect reference
    pub fn resolve(self: *const Registry, name: []const u8) ?FlakeRef {
        return self.entries.get(name);
    }
};

test "parse path flake ref" {
    const allocator = std.testing.allocator;

    var ref = try FlakeRef.parse(allocator, ".");
    defer ref.deinit();

    try std.testing.expectEqual(FlakeRef.Type.path, ref.type);
    try std.testing.expectEqualStrings(".", ref.url);
}

test "parse github flake ref" {
    const allocator = std.testing.allocator;

    var ref = try FlakeRef.parse(allocator, "github:NixOS/nixpkgs");
    defer ref.deinit();

    try std.testing.expectEqual(FlakeRef.Type.github, ref.type);
    try std.testing.expect(std.mem.indexOf(u8, ref.url, "github.com") != null);
}

test "parse github flake ref with rev" {
    const allocator = std.testing.allocator;

    var ref = try FlakeRef.parse(allocator, "github:NixOS/nixpkgs?rev=abc123");
    defer ref.deinit();

    try std.testing.expectEqual(FlakeRef.Type.github, ref.type);
    try std.testing.expectEqualStrings("abc123", ref.rev.?);
}

test "parse indirect flake ref" {
    const allocator = std.testing.allocator;

    var ref = try FlakeRef.parse(allocator, "nixpkgs");
    defer ref.deinit();

    try std.testing.expectEqual(FlakeRef.Type.indirect, ref.type);
    try std.testing.expectEqualStrings("nixpkgs", ref.url);
}
