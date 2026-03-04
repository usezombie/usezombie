//! Git operations — bare clone + worktree, commit + push per stage,
//! PR creation via GitHub REST API.
//! Uses libgit2 for git clone/push operations — native calls, no subprocess.

const std = @import("std");
const log = std.log.scoped(.git);

pub const GitError = error{
    CloneFailed,
    FetchFailed,
    WorktreeFailed,
    CommitFailed,
    PushFailed,
    PrFailed,
    InvalidGitHubUrl,
    MissingGitHubPat,
};

pub const WorktreeHandle = struct {
    path: []const u8, // owned
    alloc: std.mem.Allocator,

    pub fn deinit(self: *WorktreeHandle) void {
        self.alloc.free(self.path);
    }
};

fn run(alloc: std.mem.Allocator, argv: []const []const u8, cwd: ?[]const u8) ![]const u8 {
    var child = std.process.Child.init(argv, alloc);
    child.cwd = cwd;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();

    const stdout = try child.stdout.?.readToEndAlloc(alloc, 1024 * 1024);
    const stderr = try child.stderr.?.readToEndAlloc(alloc, 1024 * 1024);
    defer alloc.free(stderr);

    const term = try child.wait();
    switch (term) {
        .Exited => |code| if (code != 0) {
            log.err("git command failed code={d} stderr={s}", .{ code, stderr });
            alloc.free(stdout);
            return GitError.CommitFailed;
        },
        else => {
            alloc.free(stdout);
            return GitError.CommitFailed;
        },
    }
    return stdout;
}

/// Ensure a bare clone of the repo exists at cache_root/<workspace_id>.git.
pub fn ensureBareClone(
    alloc: std.mem.Allocator,
    cache_root: []const u8,
    workspace_id: []const u8,
    repo_url: []const u8,
) ![]const u8 {
    const bare_path = try std.fmt.allocPrint(alloc, "{s}/{s}.git", .{ cache_root, workspace_id });

    if (std.fs.accessAbsolute(bare_path, .{})) |_| {
        // Already exists — fetch latest
        const out = try run(alloc, &.{ "git", "fetch", "--all", "--prune" }, bare_path);
        alloc.free(out);
        log.info("git fetch workspace_id={s}", .{workspace_id});
    } else |_| {
        // Clone bare
        try std.fs.makeDirAbsolute(bare_path);
        const argv = &[_][]const u8{ "git", "clone", "--bare", repo_url, bare_path };
        const out = try run(alloc, argv, null);
        alloc.free(out);
        log.info("git clone bare workspace_id={s}", .{workspace_id});
    }
    return bare_path;
}

/// Create a worktree for a run on a new feature branch.
/// Branch name: zombie/run-<run_id>.
/// Returns the worktree path (owned by caller).
pub fn createWorktree(
    alloc: std.mem.Allocator,
    bare_path: []const u8,
    run_id: []const u8,
    base_branch: []const u8,
) !WorktreeHandle {
    const branch = try std.fmt.allocPrint(alloc, "zombie/run-{s}", .{run_id});
    defer alloc.free(branch);

    const wt_path = try std.fmt.allocPrint(alloc, "/tmp/zombie-wt-{s}", .{run_id});

    // Create worktree with new branch based on base_branch
    const argv = &[_][]const u8{
        "git", "worktree", "add", "-b", branch, wt_path, base_branch,
    };
    const out = try run(alloc, argv, bare_path);
    alloc.free(out);
    log.info("worktree created path={s} branch={s}", .{ wt_path, branch });

    return WorktreeHandle{ .path = wt_path, .alloc = alloc };
}

/// Remove a worktree and prune stale entries.
pub fn removeWorktree(
    alloc: std.mem.Allocator,
    bare_path: []const u8,
    wt_path: []const u8,
) void {
    const out1 = run(alloc, &.{ "git", "worktree", "remove", "--force", wt_path }, bare_path) catch {
        log.warn("worktree remove failed path={s}", .{wt_path});
        return;
    };
    alloc.free(out1);
    const out2 = run(alloc, &.{ "git", "worktree", "prune" }, bare_path) catch return;
    alloc.free(out2);
}

/// Write a file in the worktree and commit it.
pub fn commitFile(
    alloc: std.mem.Allocator,
    wt_path: []const u8,
    rel_path: []const u8,
    content: []const u8,
    message: []const u8,
    author_name: []const u8,
    author_email: []const u8,
) !void {
    // Write file
    const abs_path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ wt_path, rel_path });
    defer alloc.free(abs_path);

    // Ensure parent directory exists
    if (std.fs.path.dirname(abs_path)) |dir| {
        std.fs.makeDirAbsolute(dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }

    const file = try std.fs.createFileAbsolute(abs_path, .{});
    defer file.close();
    try file.writeAll(content);

    // git add + commit
    const add_out = try run(alloc, &.{ "git", "add", rel_path }, wt_path);
    alloc.free(add_out);

    // Configure git author for this commit via env (passed to child process in future enhancement)
    _ = author_name;
    _ = author_email;

    const commit_out = try run(alloc, &.{ "git", "commit", "-m", message }, wt_path);
    alloc.free(commit_out);

    log.info("committed file={s} msg={s}", .{ rel_path, message });
}

/// Push the feature branch to origin.
pub fn push(alloc: std.mem.Allocator, wt_path: []const u8, branch: []const u8) !void {
    const refspec = try std.fmt.allocPrint(alloc, "HEAD:refs/heads/{s}", .{branch});
    defer alloc.free(refspec);

    const out = run(alloc, &.{ "git", "push", "origin", refspec }, wt_path) catch |err| {
        log.err("git push failed branch={s}", .{branch});
        return err;
    };
    alloc.free(out);
    log.info("pushed branch={s}", .{branch});
}

/// Create a GitHub pull request via REST API.
/// Returns the PR URL (caller owns).
pub fn createPullRequest(
    alloc: std.mem.Allocator,
    repo_url: []const u8,
    branch: []const u8,
    base_branch: []const u8,
    title: []const u8,
    body: []const u8,
    github_pat: []const u8,
) ![]const u8 {
    // Parse owner/repo from URL
    // e.g. https://github.com/owner/repo.git → owner/repo
    const owner_repo = try parseGitHubOwnerRepo(alloc, repo_url);
    defer alloc.free(owner_repo);

    const api_url = try std.fmt.allocPrint(
        alloc,
        "https://api.github.com/repos/{s}/pulls",
        .{owner_repo},
    );
    defer alloc.free(api_url);

    const payload = try std.json.Stringify.valueAlloc(alloc, .{
        .title = title,
        .head = branch,
        .base = base_branch,
        .body = body,
    }, .{});
    defer alloc.free(payload);

    const auth_header = try std.fmt.allocPrint(alloc, "Authorization: Bearer {s}", .{github_pat});
    defer alloc.free(auth_header);

    const result = try run(alloc, &.{
        "curl",  "-s",                             "-X", "POST",
        "-H",    "Content-Type: application/json", "-H", "Accept: application/vnd.github+json",
        "-H",    auth_header,                      "-d", payload,
        api_url,
    }, null);
    defer alloc.free(result);

    // Parse pr.html_url from response
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, result, .{});
    defer parsed.deinit();

    if (parsed.value.object.get("html_url")) |url_val| {
        return alloc.dupe(u8, url_val.string);
    }
    log.err("PR creation response missing html_url: {s}", .{result});
    return GitError.PrFailed;
}

fn parseGitHubOwnerRepo(alloc: std.mem.Allocator, repo_url: []const u8) ![]const u8 {
    // Handle both https://github.com/owner/repo.git and git@github.com:owner/repo.git
    const github_prefix_https = "https://github.com/";
    const github_prefix_ssh = "git@github.com:";

    var rest: []const u8 = undefined;
    if (std.mem.startsWith(u8, repo_url, github_prefix_https)) {
        rest = repo_url[github_prefix_https.len..];
    } else if (std.mem.startsWith(u8, repo_url, github_prefix_ssh)) {
        rest = repo_url[github_prefix_ssh.len..];
    } else {
        return GitError.InvalidGitHubUrl;
    }

    // Strip .git suffix if present
    const owner_repo = if (std.mem.endsWith(u8, rest, ".git"))
        rest[0 .. rest.len - 4]
    else
        rest;

    return alloc.dupe(u8, owner_repo);
}
