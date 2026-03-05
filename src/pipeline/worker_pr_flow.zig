const std = @import("std");
const git = @import("../git/ops.zig");

pub const PushFailureAction = enum {
    lookup_remote_branch,
};

pub const PrCreateFailureAction = enum {
    retry,
    lookup_existing_pr,
    fail,
};

pub fn onPushFailure() PushFailureAction {
    return .lookup_remote_branch;
}

pub fn onPrCreateFailure(err: anyerror, detail: ?[]const u8) PrCreateFailureAction {
    _ = detail;
    return switch (err) {
        git.GitError.PrRateLimited, git.GitError.PrServerError => .retry,
        git.GitError.PrInvalidRequest, git.GitError.PrFailed => .lookup_existing_pr,
        else => .fail,
    };
}

pub fn indicatesClosedOrDeleted(detail: ?[]const u8) bool {
    const d = detail orelse return false;
    return containsIgnoreCase(d, "closed") or
        containsIgnoreCase(d, "deleted") or
        containsIgnoreCase(d, "no commits between") or
        containsIgnoreCase(d, "head sha can't be blank") or
        containsIgnoreCase(d, "head ref must be a branch");
}

pub fn indicatesNothingToCommit(detail: ?[]const u8) bool {
    const d = detail orelse return false;
    return containsIgnoreCase(d, "nothing to commit") or
        containsIgnoreCase(d, "working tree clean");
}

pub fn indicatesDirtyWorktree(detail: ?[]const u8) bool {
    const d = detail orelse return false;
    return containsIgnoreCase(d, "changes not staged") or
        containsIgnoreCase(d, "unmerged paths") or
        containsIgnoreCase(d, "please commit your changes");
}

pub fn indicatesPushRejected(detail: ?[]const u8) bool {
    const d = detail orelse return false;
    return containsIgnoreCase(d, "non-fast-forward") or
        containsIgnoreCase(d, "[rejected]") or
        containsIgnoreCase(d, "failed to push some refs");
}

pub fn indicatesPrConflict(detail: ?[]const u8) bool {
    const d = detail orelse return false;
    return containsIgnoreCase(d, "merge conflict") or
        containsIgnoreCase(d, "has conflicts") or
        containsIgnoreCase(d, "not mergeable");
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;

    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

test "onPushFailure asks to verify remote branch for concurrency races" {
    try std.testing.expectEqual(PushFailureAction.lookup_remote_branch, onPushFailure());
}

test "onPrCreateFailure retries transient GitHub failures" {
    try std.testing.expectEqual(PrCreateFailureAction.retry, onPrCreateFailure(git.GitError.PrRateLimited, null));
    try std.testing.expectEqual(PrCreateFailureAction.retry, onPrCreateFailure(git.GitError.PrServerError, null));
}

test "onPrCreateFailure looks up existing PR for invalid request races" {
    try std.testing.expectEqual(PrCreateFailureAction.lookup_existing_pr, onPrCreateFailure(git.GitError.PrInvalidRequest, "already exists"));
    try std.testing.expectEqual(PrCreateFailureAction.lookup_existing_pr, onPrCreateFailure(git.GitError.PrFailed, "unknown"));
}

test "onPrCreateFailure fails closed on auth failures" {
    try std.testing.expectEqual(PrCreateFailureAction.fail, onPrCreateFailure(git.GitError.PrAuthFailed, null));
}

test "indicatesClosedOrDeleted catches closed/deleted/empty-diff false positives" {
    try std.testing.expect(indicatesClosedOrDeleted("Pull request is closed"));
    try std.testing.expect(indicatesClosedOrDeleted("branch was deleted"));
    try std.testing.expect(indicatesClosedOrDeleted("No commits between base and head"));
    try std.testing.expect(!indicatesClosedOrDeleted("rate limit exceeded"));
}

test "detects commit and worktree edge cases from stderr/http details" {
    try std.testing.expect(indicatesNothingToCommit("nothing to commit, working tree clean"));
    try std.testing.expect(indicatesDirtyWorktree("error: Committing is not possible because you have unmerged files."));
    try std.testing.expect(indicatesPushRejected("! [rejected] HEAD -> branch (non-fast-forward)"));
}

test "detects PR conflict markers and avoids false positives" {
    try std.testing.expect(indicatesPrConflict("This pull request has conflicts"));
    try std.testing.expect(!indicatesPrConflict("pull request created successfully"));
}
