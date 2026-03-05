//! Zap HTTP server setup and request routing.
//! Thread 1 — all endpoint handlers run here. Never blocks on agent execution.

const std = @import("std");
const zap = @import("zap");
const handler = @import("handler.zig");
const log = std.log.scoped(.http);

pub const ServerConfig = struct {
    port: u16 = 3000,
    interface: []const u8 = "0.0.0.0",
    threads: i16 = 1,
    workers: i16 = 1,
};

/// Single global context pointer used by the Zap callbacks.
/// Zap's C event loop doesn't support closures, so we use a module-level var.
var g_ctx: *handler.Context = undefined;

// ── Request dispatch ──────────────────────────────────────────────────────

/// Top-level request handler — dispatches based on method + path prefix.
fn dispatch(r: zap.Request) !void {
    const path = r.path orelse {
        r.setStatus(.bad_request);
        r.sendBody("") catch {};
        return;
    };

    // Health check (no auth)
    if (std.mem.eql(u8, path, "/healthz")) {
        handler.handleHealthz(g_ctx, r);
        return;
    }
    if (std.mem.eql(u8, path, "/readyz")) {
        handler.handleReadyz(g_ctx, r);
        return;
    }
    if (std.mem.eql(u8, path, "/metrics")) {
        handler.handleMetrics(g_ctx, r);
        return;
    }

    // Route: /v1/github/callback
    if (std.mem.eql(u8, path, "/v1/github/callback")) {
        if (r.methodAsEnum() == .GET) {
            handler.handleGitHubCallback(g_ctx, r);
        } else {
            r.setStatus(.method_not_allowed);
            r.sendBody("") catch {};
        }
        return;
    }

    // Route: /v1/runs
    if (std.mem.eql(u8, path, "/v1/runs")) {
        if (r.methodAsEnum() == .POST) {
            handler.handleStartRun(g_ctx, r);
        } else {
            r.setStatus(.method_not_allowed);
            r.sendBody("") catch {};
        }
        return;
    }

    // Route: /v1/specs
    if (std.mem.eql(u8, path, "/v1/specs")) {
        if (r.methodAsEnum() == .GET) {
            handler.handleListSpecs(g_ctx, r);
        } else {
            r.setStatus(.method_not_allowed);
            r.sendBody("") catch {};
        }
        return;
    }

    // Route: /v1/runs/:run_id:retry
    if (std.mem.startsWith(u8, path, "/v1/runs/") and
        std.mem.endsWith(u8, path, ":retry"))
    {
        if (r.methodAsEnum() == .POST) {
            const inner = path["/v1/runs/".len .. path.len - ":retry".len];
            handler.handleRetryRun(g_ctx, r, inner);
        } else {
            r.setStatus(.method_not_allowed);
            r.sendBody("") catch {};
        }
        return;
    }

    // Route: /v1/runs/:run_id
    if (std.mem.startsWith(u8, path, "/v1/runs/")) {
        const run_id = path["/v1/runs/".len..];
        if (run_id.len > 0 and !std.mem.containsAtLeast(u8, run_id, 1, "/")) {
            if (r.methodAsEnum() == .GET) {
                handler.handleGetRun(g_ctx, r, run_id);
            } else {
                r.setStatus(.method_not_allowed);
                r.sendBody("") catch {};
            }
            return;
        }
    }

    // Route: /v1/workspaces/:workspace_id:pause
    if (std.mem.startsWith(u8, path, "/v1/workspaces/") and
        std.mem.endsWith(u8, path, ":pause"))
    {
        if (r.methodAsEnum() == .POST) {
            const inner = path["/v1/workspaces/".len .. path.len - ":pause".len];
            handler.handlePauseWorkspace(g_ctx, r, inner);
        } else {
            r.setStatus(.method_not_allowed);
            r.sendBody("") catch {};
        }
        return;
    }

    // Route: /v1/workspaces/:workspace_id:sync
    if (std.mem.startsWith(u8, path, "/v1/workspaces/") and
        std.mem.endsWith(u8, path, ":sync"))
    {
        if (r.methodAsEnum() == .POST) {
            const inner = path["/v1/workspaces/".len .. path.len - ":sync".len];
            handler.handleSyncSpecs(g_ctx, r, inner);
        } else {
            r.setStatus(.method_not_allowed);
            r.sendBody("") catch {};
        }
        return;
    }

    r.setStatus(.not_found);
    r.sendBody(
        \\{"error":{"code":"NOT_FOUND","message":"No such route"}}
    ) catch {};
}

// ── Server lifecycle ──────────────────────────────────────────────────────

/// Start the Zap HTTP server. Blocks until zap.stop() is called.
pub fn serve(ctx: *handler.Context, cfg: ServerConfig) !void {
    g_ctx = ctx;

    var listener = zap.HttpListener.init(.{
        .port = cfg.port,
        .on_request = dispatch,
        .log = false,
        .max_clients = 1024,
        .max_body_size = 2 * 1024 * 1024, // 2MB
    });
    try listener.listen();

    log.info("listening on 0.0.0.0:{d}", .{cfg.port});

    zap.start(.{
        .threads = cfg.threads,
        .workers = cfg.workers,
    });
}

pub fn stop() void {
    zap.stop();
}
