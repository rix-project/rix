const std = @import("std");

const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;

/// HTTP fetcher for downloading files
pub const HttpFetcher = struct {
    allocator: std.mem.Allocator,
    client: std.http.Client,

    pub fn init(allocator: std.mem.Allocator, io: Io) HttpFetcher {
        return .{
            .allocator = allocator,
            .client = .{ .allocator = allocator, .io = io },
        };
    }

    pub fn deinit(self: *HttpFetcher) void {
        self.client.deinit();
    }

    /// Download a file from a URL to a destination path
    pub fn downloadFile(self: *HttpFetcher, io: Io, url: []const u8, dest_path: []const u8, progress_node: std.Progress.Node) !void {
        const uri = try std.Uri.parse(url);

        var request = try self.client.request(.GET, uri, .{});
        defer request.deinit();

        try request.sendBodiless();
        var redirect_buf: [2048]u8 = undefined;
        var response = try request.receiveHead(&redirect_buf);

        if (response.head.status != .ok) {
            std.debug.print("HTTP status: {} for {s}\n", .{ response.head.status, url });
            return error.HttpRequestFailed;
        }

        // Get content length for progress reporting
        const content_length: usize = if (response.head.content_length) |len| len else 0;

        const node = progress_node.start(std.fs.path.basename(dest_path), content_length);
        defer node.end();

        // Create destination file
        const file = try Dir.createFile(.cwd(), io, dest_path, .{});
        defer file.close(io);

        var write_buf: [8192]u8 = undefined;
        var writer = file.writer(io, &write_buf);

        // Read response body with progress tracking
        var transfer_buf: [65536]u8 = undefined;
        var reader = response.reader(&transfer_buf);

        var bytes_downloaded: usize = 0;
        if (content_length > 0) {
            // Known size: stream in chunks with progress
            while (bytes_downloaded < content_length) {
                const remaining = content_length - bytes_downloaded;
                const chunk = @min(remaining, 8192);
                reader.streamExact(&writer.interface, chunk) catch break;
                bytes_downloaded += chunk;
                node.setCompletedItems(bytes_downloaded);
            }
        } else {
            // Unknown size: stream everything
            bytes_downloaded = try reader.streamRemaining(&writer.interface);
            node.setCompletedItems(bytes_downloaded);
        }

        try writer.flush();
    }

    /// Download a file and return its contents as a string
    pub fn downloadString(self: *HttpFetcher, url: []const u8) ![]u8 {
        const uri = try std.Uri.parse(url);

        var request = try self.client.request(.GET, uri, .{});
        defer request.deinit();

        try request.sendBodiless();
        var redirect_buf: [2048]u8 = undefined;
        const response = try request.receiveHead(&redirect_buf);

        if (response.head.status != .ok) {
            return error.HttpRequestFailed;
        }

        // Read entire response body
        var read_buf: [8192]u8 = undefined;
        var reader = response.reader(&read_buf);

        const max_size = 100 * 1024 * 1024; // 100 MB limit
        return try reader.allocRemaining(self.allocator, .limited(max_size));
    }

    /// Extract hash from URL if present (e.g., GitHub archive URLs)
    pub fn extractHashFromUrl(url: []const u8) ?[]const u8 {
        // Look for common patterns like /archive/refs/tags/v1.0.tar.gz
        if (std.mem.indexOf(u8, url, "/archive/")) |idx| {
            const after_archive = url[idx + 9 ..];
            if (std.mem.lastIndexOf(u8, after_archive, "/")) |slash_idx| {
                const hash_part = after_archive[slash_idx + 1 ..];
                if (std.mem.indexOf(u8, hash_part, ".tar")) |tar_idx| {
                    return hash_part[0..tar_idx];
                }
            }
        }
        return null;
    }
};

/// Extract tarball from a file on disk to destination directory using std.tar
pub fn extractTarball(allocator: std.mem.Allocator, io: Io, tarball_path: []const u8, dest_dir: []const u8) !void {
    // Create destination directory
    Dir.createDirPath(.cwd(), io, dest_dir) catch {};

    // Open tarball file
    const tarball_file = try Dir.openFile(.cwd(), io, tarball_path, .{});
    defer tarball_file.close(io);

    var read_buf: [8192]u8 = undefined;
    var reader = tarball_file.reader(io, &read_buf);

    try extractTarFromReader(allocator, io, &reader.interface, tarball_path, dest_dir);
}

/// Stream-download a tarball from URL and extract directly to dest_dir without
/// writing the compressed archive to disk.
pub fn downloadAndExtractTarball(
    http_fetcher: *HttpFetcher,
    io: Io,
    url: []const u8,
    dest_dir: []const u8,
    progress_node: std.Progress.Node,
) !void {
    const uri = try std.Uri.parse(url);

    var request = try http_fetcher.client.request(.GET, uri, .{});
    defer request.deinit();

    try request.sendBodiless();
    var redirect_buf: [2048]u8 = undefined;
    var response = try request.receiveHead(&redirect_buf);

    if (response.head.status != .ok) {
        std.debug.print("HTTP status: {} for {s}\n", .{ response.head.status, url });
        return error.HttpRequestFailed;
    }

    const content_length: usize = if (response.head.content_length) |len| len else 0;
    const node = progress_node.start(std.fs.path.basename(url), content_length);
    defer node.end();

    Dir.createDirPath(.cwd(), io, dest_dir) catch {};

    var transfer_buf: [65536]u8 = undefined;
    const reader = response.reader(&transfer_buf);

    try extractTarFromReader(http_fetcher.allocator, io, reader, url, dest_dir);
}

/// Extract tar entries from an arbitrary Reader interface, auto-detecting
/// compression (.gz / .xz) from `name_hint` (a filename or URL).
fn extractTarFromReader(
    allocator: std.mem.Allocator,
    io: Io,
    reader: *std.Io.Reader,
    name_hint: []const u8,
    dest_dir: []const u8,
) !void {
    // Determine compression type from name hint
    const is_gzip = std.mem.endsWith(u8, name_hint, ".gz") or
        std.mem.endsWith(u8, name_hint, ".tgz");
    const is_xz = std.mem.endsWith(u8, name_hint, ".xz");

    if (is_gzip) {
        // Decompress gzip
        var decompress_buf: [std.compress.flate.max_window_len]u8 = undefined;
        var decompress = std.compress.flate.Decompress.init(reader, .gzip, &decompress_buf);

        var file_name_buf: [std.fs.max_path_bytes]u8 = undefined;
        var link_name_buf: [std.fs.max_path_bytes]u8 = undefined;
        var tar = std.tar.Iterator.init(&decompress.reader, .{
            .file_name_buffer = &file_name_buf,
            .link_name_buffer = &link_name_buf,
        });
        try extractTarIterator(allocator, io, &tar, dest_dir);
    } else if (is_xz) {
        // Decompress xz – buffer is heap-allocated since Decompress may resize it
        const xz_buf = try allocator.alloc(u8, 1 << 16);
        var decompress = std.compress.xz.Decompress.init(reader, allocator, xz_buf) catch {
            return error.XzDecompressionFailed;
        };

        var file_name_buf: [std.fs.max_path_bytes]u8 = undefined;
        var link_name_buf: [std.fs.max_path_bytes]u8 = undefined;
        var tar = std.tar.Iterator.init(&decompress.reader, .{
            .file_name_buffer = &file_name_buf,
            .link_name_buffer = &link_name_buf,
        });
        try extractTarIterator(allocator, io, &tar, dest_dir);
    } else {
        // Plain tar
        var file_name_buf: [std.fs.max_path_bytes]u8 = undefined;
        var link_name_buf: [std.fs.max_path_bytes]u8 = undefined;
        var tar = std.tar.Iterator.init(reader, .{
            .file_name_buffer = &file_name_buf,
            .link_name_buffer = &link_name_buf,
        });
        try extractTarIterator(allocator, io, &tar, dest_dir);
    }
}

fn extractTarIterator(
    allocator: std.mem.Allocator,
    io: Io,
    tar: anytype,
    dest_dir: []const u8,
) !void {
    while (try tar.next()) |entry| {
        const full_path = try std.fs.path.join(allocator, &.{ dest_dir, entry.name });
        defer allocator.free(full_path);

        switch (entry.kind) {
            .directory => {
                Dir.createDirPath(.cwd(), io, full_path) catch {};
            },
            .file => {
                // Ensure parent directory exists
                if (std.fs.path.dirname(full_path)) |parent| {
                    Dir.createDirPath(.cwd(), io, parent) catch {};
                }

                const file = try Dir.createFile(.cwd(), io, full_path, .{});
                defer file.close(io);

                var write_buf: [8192]u8 = undefined;
                var writer = file.writer(io, &write_buf);

                // Stream file data from tar to file
                try tar.streamRemaining(entry, &writer.interface);
                try writer.flush();
            },
            .sym_link => {
                // Create symlink (ignore errors)
                Dir.symLink(.cwd(), io, entry.link_name, full_path, .{}) catch {};
            },
        }
    }
}

/// Compute SHA-256 hash of a file
pub fn computeFileHash(allocator: std.mem.Allocator, io: Io, path: []const u8) ![]u8 {
    const file = try Dir.openFile(.cwd(), io, path, .{});
    defer file.close(io);

    var read_buf: [8192]u8 = undefined;
    var reader = file.reader(io, &read_buf);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [8192]u8 = undefined;

    while (true) {
        const bytes_read = try reader.interface.read(&buffer);
        if (bytes_read == 0) break;
        hasher.update(buffer[0..bytes_read]);
    }

    var hash: [32]u8 = undefined;
    hasher.final(&hash);

    // Convert to hex string
    const hex_chars = "0123456789abcdef";
    var result = try allocator.alloc(u8, 64);
    for (hash, 0..) |byte, i| {
        result[i * 2] = hex_chars[byte >> 4];
        result[i * 2 + 1] = hex_chars[byte & 0xF];
    }

    return result;
}

test "extract hash from GitHub URL" {
    const url = "https://github.com/owner/repo/archive/refs/tags/v1.2.3.tar.gz";
    const hash = HttpFetcher.extractHashFromUrl(url);
    try std.testing.expect(hash != null);
    try std.testing.expectEqualStrings("v1.2.3", hash.?);
}
