const std = @import("std");
const FlakeRef = @import("flakeref.zig").FlakeRef;
const http = @import("http.zig");

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

    fn fetchGit(self: *Fetcher, io: Io, ref: *const FlakeRef, out_alloc: std.mem.Allocator) !FetchResult {
        _ = io;
        // Git is stubbed - will use git.zig from Zig compiler sources
        const url_hash = std.hash.Wyhash.hash(0, ref.url);
        const cache_path = try std.fmt.allocPrint(
            self.allocator,
            "{s}/git/{x}",
            .{ self.cache_dir, url_hash },
        );
        std.debug.print("TODO: fetchGit for {s} (stubbed - will use git.zig)\n", .{ref.url});
        // copy cache_path into caller allocator for return
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
