const std = @import("std");
const FlakeRef = @import("flakeref.zig").FlakeRef;
const http = @import("http.zig");
const git = @import("vendor/git.zig");

const Io = std.Io;
const Dir = Io.Dir;

pub const FetchResult = struct {
    path: []const u8,
    rev: ?[]const u8,
    last_modified: ?i64,
    nar_hash: ?[]const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *FetchResult) void {
        self.allocator.free(self.path);
        if (self.rev) |r| self.allocator.free(r);
        if (self.nar_hash) |h| self.allocator.free(h);
    }
};

pub const Fetcher = struct {
    allocator: std.mem.Allocator,
    cache_dir: []const u8,
    http_fetcher: http.HttpFetcher,

    pub fn init(allocator: std.mem.Allocator, io: Io) Fetcher {
        return .{
            .allocator = allocator,
            .cache_dir = ".zix-cache",
            .http_fetcher = http.HttpFetcher.init(allocator, io),
        };
    }

    pub fn deinit(self: *Fetcher) void {
        self.http_fetcher.deinit();
    }

    pub fn fetch(self: *Fetcher, io: Io, ref: *const FlakeRef, base_path: []const u8, progress_node: std.Progress.Node, out_alloc: std.mem.Allocator) !FetchResult {
        return switch (ref.type) {
            .path => try self.fetchPath(ref, base_path, out_alloc),
            .github => try self.fetchGitHub(io, ref, progress_node, out_alloc),
            .gitlab => try self.fetchGitLab(io, ref, progress_node, out_alloc),
            .git => try self.fetchGit(io, ref, out_alloc),
            .tarball => try self.fetchTarball(io, ref, progress_node, out_alloc),
            .indirect => return error.IndirectNotSupported,
        };
    }

    fn fetchPath(self: *Fetcher, ref: *const FlakeRef, base_path: []const u8, out_alloc: std.mem.Allocator) !FetchResult {
        const resolved = try ref.resolve(self.allocator, base_path);
        // Ensure returned path is owned by the caller allocator
        const path_copy = try out_alloc.dupe(u8, resolved);
        return FetchResult{
            .path = path_copy,
            .rev = null,
            .last_modified = null,
            .nar_hash = null,
            .allocator = out_alloc,
        };
    }

    /// Fetch a plain git repository using the vendored git wire-protocol
    /// client (`vendor/git.zig`, taken from the Zig compiler's package
    /// fetcher). Performs a shallow (depth 1) fetch of the requested ref
    /// or the default branch, then checks the tree out into the cache.
    fn fetchGit(self: *Fetcher, io: Io, ref: *const FlakeRef, out_alloc: std.mem.Allocator) !FetchResult {
        const url_hash = std.hash.Wyhash.hash(0, ref.url);
        const want_ref = ref.rev orelse ref.ref orelse "HEAD";
        const cache_path = try std.fmt.allocPrint(
            self.allocator,
            "{s}/git/{x}",
            .{ self.cache_dir, url_hash },
        );
        defer self.allocator.free(cache_path);

        const already_cached = Dir.statFile(.cwd(), io, cache_path, .{}) catch null;
        if (already_cached == null) {
            try Dir.createDirPath(.cwd(), io, self.cache_dir);
            gitClone(self.allocator, io, ref.url, want_ref, cache_path) catch |err| {
                std.debug.print("git fetch failed for {s} ({s}): {s}\n", .{ ref.url, want_ref, @errorName(err) });
                return err;
            };
        }

        const returned = try out_alloc.dupe(u8, cache_path);
        return FetchResult{
            .path = returned,
            .rev = if (ref.rev) |r| try out_alloc.dupe(u8, r) else null,
            .last_modified = null,
            .nar_hash = null,
            .allocator = out_alloc,
        };
    }

    fn fetchGitHub(self: *Fetcher, io: Io, ref: *const FlakeRef, progress_node: std.Progress.Node, out_alloc: std.mem.Allocator) !FetchResult {
        // Extract owner/repo from URL: https://github.com/owner/repo
        const github_prefix = "https://github.com/";
        if (!std.mem.startsWith(u8, ref.url, github_prefix)) {
            return error.InvalidGitHubUrl;
        }

        const owner_repo = ref.url[github_prefix.len..];
        var parts = std.mem.splitScalar(u8, owner_repo, '/');
        const owner = parts.next() orelse return error.InvalidGitHubUrl;
        const repo = parts.rest();
        if (repo.len == 0) return error.InvalidGitHubUrl;

        const rev = ref.rev orelse ref.ref orelse "HEAD";

        // Create cache path
        const cache_path = try std.fmt.allocPrint(
            self.allocator,
            "{s}/github/{s}/{s}/{s}",
            .{ self.cache_dir, owner, repo, rev },
        );

        // Check if already cached
        _ = Dir.statFile(.cwd(), io, cache_path, .{}) catch {
            // Not cached, download and extract
            // Try common archive URL forms. Some repositories require the
            // refs/heads or refs/tags path prefixes for branch/tag downloads.
            const base = "https://github.com/";
            const form1 = try std.fmt.allocPrint(self.allocator, "{s}{s}/{s}/archive/{s}.tar.gz", .{ base, owner, repo, rev });
            defer self.allocator.free(form1);

            const form2 = try std.fmt.allocPrint(self.allocator, "{s}{s}/{s}/archive/refs/heads/{s}.tar.gz", .{ base, owner, repo, rev });
            defer self.allocator.free(form2);

            const form3 = try std.fmt.allocPrint(self.allocator, "{s}{s}/{s}/archive/refs/tags/{s}.tar.gz", .{ base, owner, repo, rev });
            defer self.allocator.free(form3);

            const tarball_path = try std.fmt.allocPrint(self.allocator, "{s}/github-{s}-{s}.tar.gz", .{ self.cache_dir, owner, repo });
            defer self.allocator.free(tarball_path);

            try Dir.createDirPath(.cwd(), io, self.cache_dir);

            const downloaded = try_download_blk: {
                // try form1
                const ok1 = try_form1_blk: {
                    self.http_fetcher.downloadFile(io, form1, tarball_path, progress_node) catch {
                        break :try_form1_blk false;
                    };
                    break :try_form1_blk true;
                };
                if (ok1) break :try_download_blk true;

                // try form2
                const ok2 = try_form2_blk: {
                    self.http_fetcher.downloadFile(io, form2, tarball_path, progress_node) catch {
                        break :try_form2_blk false;
                    };
                    break :try_form2_blk true;
                };
                if (ok2) break :try_download_blk true;

                // try form3
                const ok3 = try_form3_blk: {
                    self.http_fetcher.downloadFile(io, form3, tarball_path, progress_node) catch {
                        break :try_form3_blk false;
                    };
                    break :try_form3_blk true;
                };
                if (ok3) break :try_download_blk true;

                // none succeeded
                break :try_download_blk false;
            };

            if (!downloaded) return error.HttpRequestFailed;

            const extract_dir = try std.fmt.allocPrint(self.allocator, "{s}/extract-github-{s}-{s}", .{ self.cache_dir, owner, repo });
            defer self.allocator.free(extract_dir);

            Dir.createDirPath(.cwd(), io, extract_dir) catch {};
            try http.extractTarball(self.allocator, io, tarball_path, extract_dir);

            // Find extracted directory (GitHub creates repo-rev/)
            var extract_dir_handle = try Dir.openDir(.cwd(), io, extract_dir, .{ .iterate = true });
            defer extract_dir_handle.close(io);

            var iter = extract_dir_handle.iterate();
            const extracted_name = while (try iter.next(io)) |entry| {
                if (entry.kind == .directory) break entry.name;
            } else return error.NoExtractedDirectory;

            const extracted_path = try std.fs.path.join(
                self.allocator,
                &.{ extract_dir, extracted_name },
            );
            defer self.allocator.free(extracted_path);

            // Ensure parent directory exists
            if (std.fs.path.dirname(cache_path)) |parent| {
                try Dir.createDirPath(.cwd(), io, parent);
            }

            // Rename to final cache location
            try Dir.rename(.cwd(), extracted_path, .cwd(), cache_path, io);

            // Cleanup
            Dir.deleteFile(.cwd(), io, tarball_path) catch {};
            Dir.deleteTree(.cwd(), io, extract_dir) catch {};
        };

        // copy the final cache_path into caller allocator for safe ownership
        const returned = try out_alloc.dupe(u8, cache_path);
        // Also log the original cached string allocated on fetcher allocator
        return FetchResult{
            .path = returned,
            .rev = if (ref.rev) |r| try out_alloc.dupe(u8, r) else null,
            .last_modified = null,
            .nar_hash = null,
            .allocator = out_alloc,
        };
    }

    fn fetchGitLab(self: *Fetcher, io: Io, ref: *const FlakeRef, progress_node: std.Progress.Node, out_alloc: std.mem.Allocator) !FetchResult {
        // Extract owner/repo from URL: https://gitlab.com/owner/repo
        const gitlab_prefix = "https://gitlab.com/";
        if (!std.mem.startsWith(u8, ref.url, gitlab_prefix)) {
            return error.InvalidGitLabUrl;
        }

        const owner_repo = ref.url[gitlab_prefix.len..];
        var parts = std.mem.splitScalar(u8, owner_repo, '/');
        const owner = parts.next() orelse return error.InvalidGitLabUrl;
        const repo = parts.rest();
        if (repo.len == 0) return error.InvalidGitLabUrl;

        const rev = ref.rev orelse ref.ref orelse "HEAD";

        const cache_path = try std.fmt.allocPrint(
            self.allocator,
            "{s}/gitlab/{s}/{s}/{s}",
            .{ self.cache_dir, owner, repo, rev },
        );

        _ = Dir.statFile(.cwd(), io, cache_path, .{}) catch {
            const archive_url = try std.fmt.allocPrint(
                self.allocator,
                "https://gitlab.com/{s}/{s}/-/archive/{s}/{s}-{s}.tar.gz",
                .{ owner, repo, rev, repo, rev },
            );
            defer self.allocator.free(archive_url);

            try Dir.createDirPath(.cwd(), io, self.cache_dir);

            const tarball_path = try std.fmt.allocPrint(
                self.allocator,
                "{s}/gitlab-{s}-{s}.tar.gz",
                .{ self.cache_dir, owner, repo },
            );
            defer self.allocator.free(tarball_path);

            try self.http_fetcher.downloadFile(io, archive_url, tarball_path, progress_node);

            const extract_dir = try std.fmt.allocPrint(
                self.allocator,
                "{s}/extract-gitlab-{s}-{s}",
                .{ self.cache_dir, owner, repo },
            );
            defer self.allocator.free(extract_dir);

            Dir.createDirPath(.cwd(), io, extract_dir) catch {};
            try http.extractTarball(self.allocator, io, tarball_path, extract_dir);

            var extract_dir_handle = try Dir.openDir(.cwd(), io, extract_dir, .{ .iterate = true });
            defer extract_dir_handle.close(io);

            var iter = extract_dir_handle.iterate();
            const extracted_name = while (try iter.next(io)) |entry| {
                if (entry.kind == .directory) break entry.name;
            } else return error.NoExtractedDirectory;

            const extracted_path = try std.fs.path.join(
                self.allocator,
                &.{ extract_dir, extracted_name },
            );
            defer self.allocator.free(extracted_path);

            if (std.fs.path.dirname(cache_path)) |parent| {
                try Dir.createDirPath(.cwd(), io, parent);
            }

            try Dir.rename(.cwd(), extracted_path, .cwd(), cache_path, io);
            Dir.deleteFile(.cwd(), io, tarball_path) catch {};
            Dir.deleteTree(.cwd(), io, extract_dir) catch {};
        };

        const returned = try out_alloc.dupe(u8, cache_path);
        return FetchResult{
            .path = returned,
            .rev = if (ref.rev) |r| try out_alloc.dupe(u8, r) else null,
            .last_modified = null,
            .nar_hash = null,
            .allocator = out_alloc,
        };
    }

    fn fetchTarball(self: *Fetcher, io: Io, ref: *const FlakeRef, progress_node: std.Progress.Node, out_alloc: std.mem.Allocator) !FetchResult {
        // Hash URL to create cache key
        const url_hash = std.hash.Wyhash.hash(0, ref.url);
        const cache_subdir = try std.fmt.allocPrint(
            self.allocator,
            "{s}/tarball/{x}",
            .{ self.cache_dir, url_hash },
        );

        _ = Dir.statFile(.cwd(), io, cache_subdir, .{}) catch {
            const extract_temp = try std.fmt.allocPrint(
                self.allocator,
                "{s}/tarball/{x}-extract",
                .{ self.cache_dir, url_hash },
            );
            defer self.allocator.free(extract_temp);

            // Stream-download and extract directly (no intermediate file)
            try http.downloadAndExtractTarball(
                &self.http_fetcher,
                io,
                ref.url,
                extract_temp,
                progress_node,
            );

            // Tarballs usually have a single top-level directory; hoist it up
            var extract_dir = try Dir.openDir(.cwd(), io, extract_temp, .{ .iterate = true });
            defer extract_dir.close(io);

            var iter = extract_dir.iterate();
            const extracted_name = while (try iter.next(io)) |entry| {
                if (entry.kind == .directory) break entry.name;
            } else {
                // No subdirectory – the temp dir IS the content
                try Dir.rename(.cwd(), extract_temp, .cwd(), cache_subdir, io);
                const returned = try out_alloc.dupe(u8, cache_subdir);
                return FetchResult{
                    .path = returned,
                    .rev = null,
                    .last_modified = null,
                    .nar_hash = null,
                    .allocator = out_alloc,
                };
            };

            const extracted_path = try std.fs.path.join(self.allocator, &.{ extract_temp, extracted_name });
            defer self.allocator.free(extracted_path);

            try Dir.rename(.cwd(), extracted_path, .cwd(), cache_subdir, io);
            Dir.deleteTree(.cwd(), io, extract_temp) catch {};
        };

        const returned = try out_alloc.dupe(u8, cache_subdir);
        return FetchResult{
            .path = returned,
            .rev = null,
            .last_modified = null,
            .nar_hash = null,
            .allocator = out_alloc,
        };
    }
};

/// Clone (shallow, depth 1) a git repository over HTTP(S) using the git
/// wire protocol v2, writing the checked-out worktree to `dest_dir`.
///
/// This is a thin driver over the vendored `vendor/git.zig` module (sourced
/// from the Zig compiler's package fetcher, which implements the smart
/// HTTP protocol, packfile indexing, and tree checkout using only
/// `std.http.Client` and `std.Io`).
fn gitClone(
    allocator: std.mem.Allocator,
    io: Io,
    url: []const u8,
    want_ref: []const u8,
    dest_dir: []const u8,
) !void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const uri = try std.Uri.parse(url);

    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    var session_buf: [git.Packet.max_data_length]u8 = undefined;
    var session = try git.Session.init(arena, &client, uri, &session_buf);

    // Resolve `want_ref` (a rev, branch, or tag) to a concrete OID by
    // listing refs and matching against known ref name forms. If it already
    // looks like a raw OID, use it directly as a "want" line.
    const want_oid_str = resolve_ref: {
        if (git.Oid.parseAny(want_ref)) |_| {
            break :resolve_ref try arena.dupe(u8, want_ref);
        } else |_| {}

        var ref_it: git.Session.RefIterator = undefined;
        var list_buf: [git.Packet.max_data_length]u8 = undefined;
        try session.listRefs(&ref_it, .{
            .ref_prefixes = &.{ "HEAD", "refs/heads/", "refs/tags/" },
            .include_symrefs = true,
            .buffer = &list_buf,
        });
        defer ref_it.deinit();

        var found: ?[]u8 = null;
        while (try ref_it.next()) |r| {
            if (std.mem.eql(u8, r.name, want_ref) or std.mem.endsWith(u8, r.name, want_ref)) {
                var buf: [git.Oid.max_formatted_length]u8 = undefined;
                const s = try std.fmt.bufPrint(&buf, "{f}", .{r.oid});
                found = try arena.dupe(u8, s);
            }
            if (std.mem.eql(u8, want_ref, "HEAD") and r.symref_target != null) {
                var buf: [git.Oid.max_formatted_length]u8 = undefined;
                const s = try std.fmt.bufPrint(&buf, "{f}", .{r.oid});
                found = try arena.dupe(u8, s);
            }
        }
        break :resolve_ref found orelse return error.RefNotFound;
    };

    const oid = try git.Oid.parse(session.object_format, want_oid_str);

    var fetch_stream: git.Session.FetchStream = undefined;
    var fetch_buf: [git.Packet.max_data_length]u8 = undefined;
    try session.fetch(&fetch_stream, &.{want_oid_str}, &fetch_buf);
    defer fetch_stream.deinit();

    // Write the received packfile to a temporary file, then index it.
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}-fetch-tmp", .{dest_dir});
    defer allocator.free(tmp_path);
    var tmp_dir = try Dir.createDirPathOpen(.cwd(), io, tmp_path, .{});
    var made_dir = true;
    errdefer if (made_dir) Dir.deleteTree(.cwd(), io, tmp_path) catch {};

    var pack_file = try tmp_dir.createFile(io, "pack", .{ .read = true });
    defer pack_file.close(io);
    {
        var write_buf: [65536]u8 = undefined;
        var pack_writer = pack_file.writer(io, &write_buf);
        _ = try fetch_stream.reader.streamRemaining(&pack_writer.interface);
        try pack_writer.interface.flush();
    }

    var pack_read_buf: [65536]u8 = undefined;
    var pack_reader = pack_file.reader(io, &pack_read_buf);

    var index_file = try tmp_dir.createFile(io, "idx", .{ .read = true });
    defer index_file.close(io);
    {
        var idx_write_buf: [65536]u8 = undefined;
        var idx_writer = index_file.writer(io, &idx_write_buf);
        try git.indexPack(allocator, session.object_format, &pack_reader, &idx_writer);
    }

    var idx_read_buf: [65536]u8 = undefined;
    var idx_reader = index_file.reader(io, &idx_read_buf);

    var repository: git.Repository = undefined;
    try repository.init(allocator, session.object_format, &pack_reader, &idx_reader);
    defer repository.deinit();

    var worktree = try Dir.createDirPathOpen(.cwd(), io, dest_dir, .{});
    defer worktree.close(io);

    var diagnostics: git.Diagnostics = .{ .allocator = allocator };
    defer diagnostics.deinit();
    try repository.checkout(io, worktree, oid, &diagnostics);

    tmp_dir.close(io);
    Dir.deleteTree(.cwd(), io, tmp_path) catch {};
    made_dir = false;

    if (diagnostics.errors.items.len > 0) {
        std.debug.print("git checkout produced {d} diagnostics for {s}\n", .{ diagnostics.errors.items.len, url });
    }
}
