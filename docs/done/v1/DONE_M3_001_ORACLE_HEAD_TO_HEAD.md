# M3_001 — Oracle Head-to-Head: usezombie vs nullclaw

> **Generated**: 2026-03-04  
> **Oracle model**: GPT-5.2 (via Amp oracle tool)  
> **Purpose**: Comparative Zig code review across 10 reliability/operability dimensions.  
> **Status**: ✅ DONE (Mar 05, 2026)  
> **Action**: This spec is a reference for agents planning M3+ work. No code changes in this thread.

---

## Codebases compared

| | **usezombie** | **nullclaw** |
|---|---|---|
| Files | 12 `.zig` files | ~140 `.zig` files |
| Maturity | M1 — functional MVP | Production — multi-channel, multi-provider |
| Architecture | HTTP server + sequential worker + Postgres | Event bus + reliable providers + observer framework |

---

## Dimension summary

| # | Dimension | Severity | usezombie status | nullclaw reference pattern |
|---|-----------|----------|------------------|----------------------------|
| 1 | Memory leaks | **Medium** | Good defer hygiene; subprocess lifecycle gaps | ResourceBundle pattern, errdefer at boundaries |
| 2 | Allocation best practices | **Medium** | Single GPA for worker; many manual frees | Per-run ArenaAllocator; bounded buffers |
| 3 | Async / API performance | **High** | Sequential single-thread worker | Multi-worker + concurrent dispatch |
| 4 | Event bus / actor dispatch | **Medium** | Ad-hoc log lines only | Ring-buffer MPSC bus (`bus.zig`) |
| 5 | Reliability & retry | **Critical** | Pipeline-level retry only | `reliable.zig` + outbox + dead-letter |
| 6 | Rate limiting | **High** | None | Token bucket per tenant/provider |
| 7 | Backoff | **Critical** | Fixed poll interval; no backoff on errors | Exponential + jitter + Retry-After parsing |
| 8 | Logging (.env / agent-friendly) | **Medium** | Compile-time level; unstructured text | Runtime `LOG_LEVEL`; key=value structured logs |
| 9 | Logging on errors | **High** | Many `catch {}`; generic error names | Classification + context + correlation IDs |
| 10 | Error code classification | **Critical** | Generic `INTERNAL_ERROR` / `AGENT_CRASH` | `error_classify.zig`: rate_limited / context_exhausted / auth / server_error |

---

## 1. Memory leaks — arena usage, defer hygiene, errdefer patterns

### What nullclaw does well
- Explicit ownership conventions with consistent "caller owns" vs "borrowed" APIs
- Defensive `errdefer` cleanup at all boundaries (tools, providers, observers)
- Lifecycle bundling: components constructed/deconstructed as a unit (provider + observer + rate limiter)

### usezombie gaps

| File | Line | Issue |
|------|------|-------|
| `src/git/ops.zig` | 28–52 | `run()` spawns child process — no `child.deinit()`, no timeout, no forced pipe close on error |
| `src/pipeline/agents.zig` | 292–358 | Manual tool list building with `alloc.create` + `errdefer` loops — duplicated across `buildEchoTools` and `buildWardenTools` |

### Recommendation: ResourceBundle pattern

```zig
const ResourceBundle = struct {
    child: std.process.Child,
    stdout: ?[]u8 = null,
    stderr: ?[]u8 = null,
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator, argv: []const []const u8, cwd: ?[]const u8) !ResourceBundle {
        var child = std.process.Child.init(argv, alloc);
        child.cwd = cwd;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        try child.spawn();
        return .{ .child = child, .alloc = alloc };
    }

    pub fn deinit(self: *ResourceBundle) void {
        if (self.stdout) |b| self.alloc.free(b);
        if (self.stderr) |b| self.alloc.free(b);
        self.child.deinit();
    }
};
```

---

## 2. Allocation best practices — GPA vs arena vs fixed-buffer

### What nullclaw does well
- Purpose-fit allocators: arena for per-request scratch, long-lived for caches, bounded buffers for serialization
- Bounded memory patterns for reliability components (outbox, bus ring buffers)

### usezombie gaps

| File | Line | Issue |
|------|------|-------|
| `src/pipeline/worker.zig` | 54–56 | Single GPA for entire worker thread lifetime |
| `src/pipeline/worker.zig` | 104–175 | Many small `dupe`/`allocPrint` with manual `defer alloc.free` |
| `src/http/handler.zig` | 22–33 | JSON buffer overflow falls through to `{}` silently |

### Recommendation: per-run ArenaAllocator

```zig
fn executeRun(...) !void {
    var run_arena = std.heap.ArenaAllocator.init(alloc);
    defer run_arena.deinit();
    const a = run_arena.allocator();
    // All per-run strings allocated from arena — no manual frees needed
    const branch = try std.fmt.allocPrint(a, "zombie/run-{s}", .{ctx.run_id});
}
```

---

## 3. Async / API performance — concurrent dispatch

### What nullclaw does well
- Concurrent tool/provider dispatch with cancellation boundaries
- `dispatcher.zig` architecture supports parallelism

### usezombie gaps

| File | Line | Issue |
|------|------|-------|
| `src/pipeline/worker.zig` | 4–5 | Explicitly sequential: "one spec at a time for M1" |
| `src/pipeline/worker.zig` | 70–75 | Fixed-sleep poll loop, single thread |
| `src/pipeline/agents.zig` | 130, 202, 276 | Blocking `agent.runSingle()` calls |
| `src/git/ops.zig` | 28–52, 206–212 | Blocking subprocess + curl calls |

### Recommendation: multi-worker threads (simplest big win)

```zig
const n = parseEnvInt("WORKER_CONCURRENCY", 1);
var threads = try alloc.alloc(std.Thread, n);
for (threads, 0..) |*t, _| {
    t.* = try std.Thread.spawn(.{}, worker.workerLoop, .{ wcfg, &wstate });
}
```

`FOR UPDATE SKIP LOCKED` is already in place, so concurrent workers are safe immediately.

---

## 4. Event bus / actor-based dispatch

### What nullclaw does well
- First-class `Bus` with bounded ring-buffer MPSC queues (`bus.zig`)
- Inbound + outbound channels decoupled from business logic
- Attach observers without modifying pipeline code

### usezombie gaps

| File | Line | Issue |
|------|------|-------|
| `src/pipeline/agents.zig` | 30–40 | `emitNullclawRunEvent` is a single `log.info` call |
| `src/state/machine.zig` | 112–117 | Transition events are direct log lines |
| `src/state/policy.zig` | 41–47 | Policy events are direct log lines |

### Recommendation: minimal MPSC event channel

```zig
// src/events/bus.zig
pub const Bus = struct {
    chan: BoundedQueue(Event, 1024),

    pub fn emit(self: *Bus, e: Event) void {
        _ = self.chan.publish(e) catch {}; // drop on overload
    }

    pub fn run(self: *Bus) void {
        while (self.chan.consume()) |e| {
            // serialize + write structured log
            // optionally: persist to events table
        }
    }
};
```

---

## 5. Reliability & retry for dispatch

### What nullclaw does well
- `ReliableProvider`: wraps any provider with retry + backoff + classification + rate limit + circuit breaker
- `VectorOutbox`: durable outbox with retry semantics + dead-letter purge
- `CircuitBreaker`: pure state machine (closed → open → half_open)

### usezombie gaps

| File | Line | Issue |
|------|------|-------|
| `src/pipeline/worker.zig` | 200–363 | Retry is pipeline-level (attempt = full Echo→Scout→Warden cycle), not API-call level |
| `src/git/ops.zig` | 172–223 | `createPullRequest` uses `curl` with no retry, no status parsing |
| `src/git/ops.zig` | 159–170 | `git push` — no retry |
| `src/git/ops.zig` | 28–52 | All subprocess calls — no timeout |

### Recommendation: `reliable_call.zig` wrapper for ALL external calls

```zig
pub fn reliableCall(comptime T: type, max_retries: u32, f: anytype) !T {
    var attempt: u32 = 0;
    while (attempt <= max_retries) : (attempt += 1) {
        const result = f() catch |err| {
            const classified = classifyError(err);
            if (!classified.retryable) return err;
            const delay = classified.retry_after_ms orelse expBackoffJitter(attempt, 500, 30_000);
            std.time.sleep(delay * std.time.ns_per_ms);
            continue;
        };
        return result;
    }
    return error.RetriesExhausted;
}
```

Also add outbox table:
```sql
CREATE TABLE IF NOT EXISTS outbox_events (
    id BIGSERIAL PRIMARY KEY,
    run_id TEXT NOT NULL,
    event_type TEXT NOT NULL,
    payload_json TEXT NOT NULL,
    status TEXT DEFAULT 'pending',
    attempts INT DEFAULT 0,
    next_attempt_at BIGINT,
    created_at BIGINT NOT NULL
);
```

---

## 6. Rate limiting

### What nullclaw does well
- Rate limit detection + API key rotation on 429
- Token bucket / leaky bucket integrated with retries

### usezombie gaps

| File | Line | Issue |
|------|------|-------|
| `src/pipeline/worker.zig` | 183–244 | No throttling before agent calls |
| `src/pipeline/worker.zig` | 43 | `tenant_id` exists in RunContext but unused for limits |

### Recommendation: token bucket per tenant + provider

```zig
pub const TokenBucket = struct {
    capacity: u32,
    tokens: f64,
    refill_per_sec: f64,
    last_ms: i64,

    pub fn allow(self: *TokenBucket, now_ms: i64, cost: f64) bool {
        const dt = @as(f64, @floatFromInt(now_ms - self.last_ms)) / 1000.0;
        self.tokens = @min(@as(f64, @floatFromInt(self.capacity)), self.tokens + dt * self.refill_per_sec);
        self.last_ms = now_ms;
        if (self.tokens >= cost) {
            self.tokens -= cost;
            return true;
        }
        return false;
    }
};
```

Key buckets by `tenant_id` (and optionally `provider/model`).

---

## 7. Backoff — backpressure, exponential backoff, Retry-After

### What nullclaw does well
- Exponential backoff with jitter
- `parseRetryAfterMs()` — parses Retry-After header from error messages
- Backpressure hooks interact with circuit breaker

### usezombie gaps

| File | Line | Issue |
|------|------|-------|
| `src/pipeline/worker.zig` | 74–75 | Fixed `poll_interval_ms` always — no adaptive backoff |
| `src/pipeline/worker.zig` | 209–363 | Retry loop has no delay between attempts |
| `src/git/ops.zig` | 206–223 | GitHub API response headers ignored |

### Recommendation: shared backoff helper

```zig
pub fn expBackoffJitter(attempt: u32, base_ms: u64, max_ms: u64) u64 {
    const pow = std.math.shl(u64, 1, @min(attempt, 12));
    var ms = base_ms * pow;
    if (ms > max_ms) ms = max_ms;
    // jitter in [50%, 100%)
    const r = @as(u64, std.crypto.random.int(u16) % 500);
    return (ms / 2) + (r * ms / 1000);
}
```

Apply in:
- `worker.zig` retry loop (between Scout→Warden attempt cycles)
- `git.createPullRequest()` (wrap with `reliableCall` that parses status)
- Worker poll loop (adaptive: shorter when busy, longer when idle)

---

## 8. Logging — .env level control, agent-friendly structured logs

### What nullclaw does well
- `observability.zig`: `Observer` vtable interface with Noop / Log / Verbose / File / Multi / Otel backends
- Runtime-configurable verbosity
- Consistent key=value structured logging with context fields

### usezombie gaps

| File | Line | Issue |
|------|------|-------|
| `src/main.zig` | 19–23 | Log level is compile-time only (`.Debug` vs `.info`) |
| `src/main.zig` | 25–48 | Custom logger: unstructured text, no JSON option |
| `src/pipeline/agents.zig` | 109–111, 177–179, 246–248 | Uses `NoopObserver` — disables nullclaw's observability hooks entirely |

### Recommendation

**Runtime log level from env:**
```zig
var g_level: std.atomic.Value(u8) = .init(@intFromEnum(std.log.Level.info));

pub fn init() void {
    if (std.process.getEnvVarOwned(alloc, "LOG_LEVEL")) |s| {
        defer alloc.free(s);
        g_level.store(@intFromEnum(parseLevel(s)), .release);
    }
}
```

**Key=value structured format:**
```
1709510400000 INF [worker] event=transition run_id=r_abc123 from=SPEC_QUEUED to=RUN_PLANNED actor=echo
```

**Wire real observer:** Replace `NoopObserver` with `LogObserver` (or `MultiObserver` with `LogObserver` + `FileObserver`).

---

## 9. Logging on errors — context, correlation, error swallowing

### What nullclaw does well
- Error logs include classification + context + correlation IDs
- Centralized error reporting avoids `catch {}` + continue silently

### usezombie gaps

| File | Line | Issue |
|------|------|-------|
| `src/pipeline/worker.zig` | 121 | `result.drain() catch {}` — silently swallowed |
| `src/pipeline/worker.zig` | 139 | Transition failure on crash path ignored |
| `src/http/handler.zig` | 25–33 | JSON stringify failure returns `{}` silently |
| `src/git/ops.zig` | 41–50 | Returns generic `GitError.CommitFailed` for all failure modes, stderr logged but not propagated |

### Recommendation: error context helper

```zig
pub fn logErr(
    comptime scope: @TypeOf(.enum_literal),
    err: anyerror,
    comptime fmt: []const u8,
    args: anytype,
) void {
    std.log.scoped(scope).err(fmt ++ " err={s}", args ++ .{@errorName(err)});
}
```

Replace all `catch {}` at critical boundaries with at least `log.warn` + context.

For git failures: include stderr + command + exit code in logs, classify retryability.

---

## 10. Error code classification — decision needed

### What nullclaw does well
- `error_classify.zig`: classifies API error payloads into `rate_limited`, `context_exhausted`, `vision_unsupported`, `other`
- Classification drives: retry decision, backoff amount, circuit breaker, user-facing reason code
- `reliable.zig`: `isNonRetryable()`, `isRateLimited()`, `isContextExhausted()`, `parseRetryAfterMs()`

### usezombie gaps

| File | Line | Issue |
|------|------|-------|
| `src/pipeline/worker.zig` | 136–140 | All errors → `AGENT_CRASH` reason code |
| `src/pipeline/worker.zig` | 209–363 | Retry driven by warden verdict, not by API error class |
| `src/http/handler.zig` | 35–46 | HTTP errors use generic codes: `INTERNAL_ERROR`, `UNAUTHORIZED`, etc. |

### Decision: YES, keep error codes AND add classification

HTTP error codes (as currently used) **are valid and useful** for API consumers. Keep them. But add internal classification for provider/external call errors.

```zig
pub const ErrorClass = enum {
    rate_limited,       // 429 / quota
    timeout,            // connection/read timeout
    context_exhausted,  // prompt too large
    auth,               // 401/403
    invalid_request,    // 400 (non-retryable)
    server_error,       // 500/502/503
    unknown,
};

pub const Classified = struct {
    class: ErrorClass,
    retryable: bool,
    retry_after_ms: ?u64 = null,
    reason_code: types.ReasonCode,
};
```

Decision matrix for worker:

| ErrorClass | Retryable? | Action |
|------------|-----------|--------|
| `rate_limited` | Yes | Backoff (Retry-After or exp) — DO NOT burn an attempt |
| `timeout` | Yes | Retry with backoff |
| `context_exhausted` | No | BLOCKED + `SPEC_MISMATCH` reason |
| `auth` | No | BLOCKED + new reason `AUTH_FAILED` |
| `invalid_request` | No | BLOCKED + `AGENT_CRASH` |
| `server_error` | Yes | Retry with backoff |
| `unknown` | No | BLOCKED + `AGENT_CRASH` |

---

## Implementation priority order

| Priority | Work item | Effort | Dimension(s) |
|----------|-----------|--------|---------------|
| **P0** | `reliable_call.zig` + `error_classify.zig` + `expBackoffJitter` | L (1–2d) | 5, 7, 10 |
| **P1** | Structured logging + runtime `LOG_LEVEL` + real Observer | M (2–4h) | 8, 9 |
| **P2** | Multi-worker concurrency (`WORKER_CONCURRENCY`) | M (2–4h) | 3 |
| **P3** | Token bucket rate limiter | M (2–4h) | 6 |
| **P4** | Event bus + outbox/dead-letter table | L (1–2d) | 4, 5 |
| **P5** | Per-run ArenaAllocator + ResourceBundle | S (1–2h) | 1, 2 |

---

## When to advance to circuit breaker + async IO

Move beyond this "simple path" when:
- Running > ~5–10 runs/hour per instance with latency pressure
- Frequent 429/503 from providers
- Need audit-grade event replay (notifications, billing, compliance)
- Distributed workers across hosts

Advanced path then adds:
- `CircuitBreaker` (nullclaw `circuit_breaker.zig`) + persistent distributed rate limits
- Async IO runtime for HTTP + providers with connection pooling
- Fully persistent event bus with replayable run orchestration

---

# Part 2 — Missed Dimensions (Oracle Round 2)

> **Generated**: 2026-03-04 (follow-up pass)  
> **Finding**: 10 additional dimensions missed in the original review.  
> **Three are Critical — must be addressed before production.**

## Extended dimension summary

| # | Dimension | Severity | Key risk |
|---|-----------|----------|----------|
| 11 | Secure execution boundary | **Critical** | Path traversal, git hooks, shell in untrusted repos |
| 12 | Graceful shutdown / signal handling | **High** | No SIGTERM handling; orphaned worktrees; leaked threads |
| 13 | Transactional correctness / exactly-once | **Critical** | Double-run claiming; state races; idempotency gaps |
| 14 | Side-effect idempotency (PR/push/commit) | **Critical** | Duplicate PRs on retry; repeated git pushes |
| 15 | Timeouts & cancellation | **High** | git/curl/agent can hang indefinitely |
| 16 | Thread safety & Zig allocator pitfalls | **High** | Shared GPA across threads; leak detection ignored |
| 17 | Schema migration safety | **High** | Naïve SQL split; non-transactional; silent failures |
| 18 | Health check depth (readiness vs liveness) | **Medium–High** | `/healthz` always returns ok even with DB down |
| 19 | Metrics / telemetry / tracing | **Medium** | NoopObserver; no counters; no correlation IDs |
| 20 | Config validation & secret hygiene | **Medium–High** | Permissive defaults; no key rotation; no fail-fast |

---

## 11. Secure execution boundary — untrusted repo content

### Severity: Critical

### Gaps

| File | Line | Issue |
|------|------|-------|
| `src/pipeline/worker.zig` | 169–174 | `spec_abs = "{wt.path}/{ctx.spec_content}"` — if `spec_file_path` contains `../` it escapes the worktree |
| `src/pipeline/agents.zig` | 165–170 | Scout gets `allTools` including shell — arbitrary command execution in untrusted repo |
| `src/pipeline/agents.zig` | 336–343 | Warden `ShellTool` — has timeout but no env scrubbing or sandbox |
| `src/git/ops.zig` | 146–155 | `git add` + `git commit` — no `--no-verify`, no hook disabling (`core.hooksPath=/dev/null`) |

### Recommendation
- Canonicalize paths and enforce "must be within worktree" before `openFileAbsolute`
- Disable git hooks: add `-c core.hooksPath=/dev/null` to all git commands
- Scrub environment for spawned processes (no long-lived secrets leaked to child)
- Consider: run agent tools inside a constrained namespace (future M4)

---

## 12. Graceful shutdown / signal handling

### Severity: High

### Gaps

| File | Line | Issue |
|------|------|-------|
| `src/main.zig` | 148–154 | Worker thread spawned but never joined; no stop path |
| `src/pipeline/worker.zig` | 70–76 | Loop checks `worker_state.running` but nothing ever sets it to `false` |
| `src/main.zig` | 80–154 | No OS signal handling (SIGTERM/SIGINT) |
| `src/pipeline/worker.zig` | 159–163 | Worktree cleanup only in `defer` — crashes leave `/tmp/zombie-wt-*` behind |

### Recommendation
```zig
// Signal handler (simplified)
fn handleSignal(_: c_int) callconv(.C) void {
    wstate.running.store(false, .release);
    zap.stop();
}

// In cmdServe():
std.posix.sigaction(std.posix.SIG.TERM, &.{ .handler = handleSignal, ... });
// After zap returns:
worker_thread.join();
pool.deinit();
```

Also: add startup cleanup of stale `/tmp/zombie-wt-*` directories.

---

## 13. Transactional correctness / exactly-once run claiming

### Severity: Critical

### Gaps

| File | Line | Issue |
|------|------|-------|
| `src/pipeline/worker.zig` | 88–99 | `SELECT ... FOR UPDATE SKIP LOCKED` — but no explicit `BEGIN`/`COMMIT`, so lock may release immediately in autocommit mode |
| `src/state/machine.zig` | 67–110 | `getRunState()` then insert then `UPDATE` — no `WHERE state = $expected` guard, no transaction |
| `src/http/handler.zig` | 113–134 | Idempotency check-then-insert race: concurrent requests can both pass the check |
| `src/http/handler.zig` | 115–117 | Idempotency key query ignores `workspace_id` — key collision across tenants |

### Recommendation
- **Claim pattern**: `BEGIN; SELECT ... FOR UPDATE SKIP LOCKED; UPDATE runs SET state='RUN_PLANNED'; COMMIT;`
- **Transition pattern**: `UPDATE runs SET state = $new WHERE run_id = $id AND state = $expected RETURNING state`
- **Idempotency**: add unique index `(workspace_id, idempotency_key)` or `(tenant_id, idempotency_key)`

---

## 14. Side-effect idempotency — PR creation, git push, artifact commits

### Severity: Critical

### Gaps

| File | Line | Issue |
|------|------|-------|
| `src/pipeline/worker.zig` | 269–296 | Always calls `git.push` + `git.createPullRequest` — no check for existing `pr_url` |
| `src/git/ops.zig` | 172–223 | GitHub PR creation via `curl` — no idempotency key, no status code handling |
| `src/git/ops.zig` | 153–155 | `git commit -m ...` fails on "nothing to commit" or creates duplicate commits |

### Recommendation
```zig
// Before PR creation:
if (existing_pr_url) |_| {
    // PR already created — skip to transition
} else {
    const pr_url = try git.createPullRequest(...);
    // Update run with pr_url
}
```

Store a side-effect ledger: `(run_id, effect_type, completed_at)` — check before repeating any external mutation.

---

## 15. Timeouts & cancellation for external calls

### Severity: High

### Gaps

| File | Line | Issue |
|------|------|-------|
| `src/git/ops.zig` | 28–52 | Subprocess runner: no timeout, no kill on hang |
| `src/git/ops.zig` | 206–212 | `curl -s` without `--max-time` or `--connect-timeout` |
| `src/pipeline/agents.zig` | 130, 202, 276 | `agent.runSingle()` blocks with no cancellation token |

### Recommendation
- Add `--max-time 120 --connect-timeout 10` to all `curl` calls
- Add a process timeout wrapper:
  ```zig
  fn runWithTimeout(alloc: Allocator, argv: []const []const u8, cwd: ?[]const u8, timeout_ms: u64) ![]const u8 {
      // spawn, then poll with deadline; kill + reap on timeout
  }
  ```
- Per-run deadline: `const deadline = now + RUN_TIMEOUT_MS`; check before each phase

---

## 16. Thread safety & Zig allocator pitfalls

### Severity: High

### Gaps

| File | Line | Issue |
|------|------|-------|
| `src/main.zig` | 131–135 | `ctx.alloc = alloc` (GPA) shared with HTTP thread — GPA is **not** thread-safe by default |
| `src/http/server.zig` | 137–140 | Zap supports multi-thread/worker config — concurrent handler access to non-thread-safe allocator |
| `src/main.zig` | 62–64 | `defer _ = gpa.deinit();` — leak detection result discarded |
| `src/pipeline/worker.zig` | 54–56 | Same: worker GPA deinit result ignored |

### Recommendation
- Force Zap to single thread/worker AND document it, OR use `std.heap.GeneralPurposeAllocator(.{ .thread_safe = true })`
- Check GPA deinit result in Debug builds:
  ```zig
  const check = gpa.deinit();
  if (check == .leak) log.err("memory leak detected", .{});
  ```

---

## 17. Schema migration safety

### Severity: High

### Gaps

| File | Line | Issue |
|------|------|-------|
| `src/main.zig` | 94–99 | Auto-runs migrations on every startup; failure only logs warning |
| `src/db/pool.zig` | 99–111 | Splits SQL on `";\n"` (breaks on triggers, functions, multi-line strings); continues on error; not transactional |

### Recommendation
- Separate `migrate` subcommand from `serve` (or require `MIGRATE_ON_START=1`)
- Use a `schema_migrations` table with ordered version files
- Run migrations inside a transaction; fail hard on error

---

## 18. Health check depth — readiness vs liveness

### Severity: Medium–High

### Gaps

| File | Line | Issue |
|------|------|-------|
| `src/http/handler.zig` | 65–71 | `/healthz` always returns `{"status":"ok"}` — no DB probe, no worker heartbeat check |

### Recommendation
- `/livez` — process alive (static, fast)
- `/readyz` — checks: DB connectivity, migrations applied, worker loop healthy, queue depth
- Include oldest-queued-run age for operational alerting

---

## 19. Metrics / telemetry / tracing

### Severity: Medium

### Gaps

| File | Line | Issue |
|------|------|-------|
| `src/pipeline/agents.zig` | 109–111, 177–179, 246–248 | `NoopObserver` — nullclaw's observability hooks disabled |
| `src/pipeline/agents.zig` | 30–40 | Single log line for "nullclaw_run" events |
| `src/http/handler.zig` | 48–53 | `request_id` generated but not propagated to worker/state transitions |

### Recommendation
- Wire `LogObserver` or `MultiObserver` instead of `NoopObserver`
- Propagate `request_id` through the full run lifecycle
- Expose `/metrics` endpoint with: runs_total, runs_completed, retries_total, agent_duration_seconds, queue_depth

---

## 20. Configuration validation & secret hygiene

### Severity: Medium–High

### Gaps

| File | Line | Issue |
|------|------|-------|
| `src/main.zig` | 83–86 | PORT parsing falls back silently to 3000 |
| `src/main.zig` | 112–114 | `GITHUB_APP_ID` defaults to `""` and continues — only `doctor` enforces |
| `src/http/handler.zig` | 56–61 | Single static API key; no rotation mechanism; no multi-key support |
| `src/secrets/crypto.zig` | 21–32 | Master key loaded from env — no rotation, no key versioning |

### Recommendation
- Fail-fast in `serve` for required config (not only `doctor`)
- Support comma-separated API keys: `API_KEY=key1,key2` — accept any valid key (rotation window)
- Add key version prefix to encrypted envelopes for rotation support

---

## Updated implementation priority (combined)

| Priority | Work item | Effort | Dimension(s) |
|----------|-----------|--------|---------------|
| **P0** | Transactional correctness (BEGIN/COMMIT, CAS transitions, idempotency index) | M (4–6h) | 13 |
| **P0** | Side-effect idempotency (PR dedupe, side-effect ledger) | M (3–4h) | 14 |
| **P0** | Secure execution boundary (path canonicalization, hook disable, env scrub) | M (3–4h) | 11 |
| **P0** | `reliable_call.zig` + `error_classify.zig` + `expBackoffJitter` | L (1–2d) | 5, 7, 10 |
| **P1** | Timeouts for subprocess + curl + agent calls | M (3–4h) | 15 |
| **P1** | Graceful shutdown (signal handler, thread join, worktree cleanup) | M (2–3h) | 12 |
| **P1** | Thread safety (force single-thread or thread-safe GPA) | S (1h) | 16 |
| **P1** | Structured logging + runtime `LOG_LEVEL` + real Observer | M (2–4h) | 8, 9 |
| **P2** | Multi-worker concurrency (`WORKER_CONCURRENCY`) | M (2–4h) | 3 |
| **P2** | Token bucket rate limiter | M (2–4h) | 6 |
| **P2** | Health check depth (`/readyz` with DB + worker probe) | S (1–2h) | 18 |
| **P3** | Schema migration safety (versioned, transactional, separate command) | M (3–4h) | 17 |
| **P3** | Config validation fail-fast + multi-key rotation | S (1–2h) | 20 |
| **P3** | Event bus + outbox/dead-letter table | L (1–2d) | 4, 5 |
| **P4** | Metrics endpoint + request_id propagation | M (3–4h) | 19 |
| **P5** | Per-run ArenaAllocator + ResourceBundle | S (1–2h) | 1, 2 |
| **P1** | Test coverage — pure logic tests + coverage tooling | M (4–6h) | 21 |
| **P3** | Comment policy enforcement (module `//!` required, strip noise) | S (1h) | 22 |

---

# Part 3 — Test Coverage & Comment Policy (Oracle Round 3)

> **Generated**: 2026-03-04 (follow-up pass)  
> **Principle**: Tests are executable documentation. Comments are tokens. Invest in guardrails, not prose.

## Extended dimension summary (continued)

| # | Dimension | Severity | Key risk |
|---|-----------|----------|----------|
| 21 | Test coverage & measurement | **Critical** | 3 test blocks across 12 files; zero coverage tooling; agents can't verify changes |
| 22 | Comment policy (agent-optimized) | **Low** | Module `//!` already good; no action needed on inline comments |

---

## 21. Test coverage — measurement and gaps

### Severity: Critical

### Current state: 3 tests across 12 files, 0% coverage measurement

| File | Tests | What's tested |
|------|-------|---------------|
| `src/types.zig` | 1 block | `RunState.label()`, `isTerminal()`, `isRetryable()` — trivial |
| `src/state/machine.zig` | 1 test | `isAllowed()` transition table — pure logic, no DB |
| `src/secrets/crypto.zig` | 1 test | `encrypt`/`decrypt` round-trip — good |
| `src/http/handler.zig` | **0** | All 6 HTTP handlers untested |
| `src/http/server.zig` | **0** | Router dispatch untested |
| `src/pipeline/worker.zig` | **0** | Worker loop, run claiming, pipeline untested |
| `src/pipeline/agents.zig` | **0** | Verdict parsing, observation extraction, prompt building untested |
| `src/db/pool.zig` | **0** | URL parsing, migration runner untested |
| `src/memory/workspace.zig` | **0** | Memory load/save untested |
| `src/git/ops.zig` | **0** | All git operations untested |
| `src/state/policy.zig` | **0** | Policy event recording untested |

**Coverage tooling**: None. CI runs `zig build test` but no coverage gate, no reporting.

### nullclaw comparison

nullclaw has extensive tests per module with production-grade patterns:
- `reliable.zig`: 15+ tests (retry, backoff, fallback, model failover, exhaustion)
- `bus.zig`: 12+ tests including multi-thread stress (10 producers × 100 messages)
- `circuit_breaker.zig`: 15+ state-machine lifecycle tests
- `outbox.zig`: 15+ tests with failure injection (`FailingEmbedding`)
- `dispatcher.zig`: XML/JSON/function-tag parsing with edge cases
- `error_classify.zig`: rate-limit, context-exhausted, vision-unsupported detection

Key patterns usezombie should adopt:
- **Mock vtables** for interface boundaries (mock `pg.Conn`, mock providers)
- **Failure injection** (fail_until counters, FailingEmbedding)
- **Stress tests** for concurrency (multi-thread producer/consumer)

### Recommendation

**Phase 1 — Pure logic tests (no DB, no IO, immediate wins):**

```zig
// db/pool.zig
test "parseUrl valid postgres URL" {
    const alloc = std.testing.allocator;
    const opts = try parseUrl(alloc, "postgres://user:pass@localhost:5432/mydb");
    // assert host, port, username, password, database
}
test "parseUrl invalid scheme returns error" { ... }
test "parseUrl missing @ returns error" { ... }

// pipeline/agents.zig
test "parseWardenVerdict PASS on explicit verdict" {
    try std.testing.expect(parseWardenVerdict("verdict: PASS\n## Summary"));
}
test "parseWardenVerdict FAIL when T1 present" {
    try std.testing.expect(!parseWardenVerdict("**PASS**\n### T1\n- critical bug"));
}
test "parseWardenVerdict FAIL when no verdict" {
    try std.testing.expect(!parseWardenVerdict("some random output"));
}
test "extractObservations returns empty for no section" {
    const alloc = std.testing.allocator;
    const r = try extractObservations(alloc, "no observations here");
    defer alloc.free(r);
    try std.testing.expectEqualStrings("", r);
}
test "extractObservations extracts section content" { ... }

// git/ops.zig
test "parseGitHubOwnerRepo https URL" {
    const alloc = std.testing.allocator;
    const r = try parseGitHubOwnerRepo(alloc, "https://github.com/org/repo.git");
    defer alloc.free(r);
    try std.testing.expectEqualStrings("org/repo", r);
}
test "parseGitHubOwnerRepo ssh URL" { ... }
test "parseGitHubOwnerRepo invalid URL" { ... }

// state/machine.zig — extend existing
test "transition to terminal state is rejected" { ... }
test "invalid transition returns error" { ... }

// types.zig — extend existing
test "RunState.fromStr round-trip all variants" { ... }
test "ReasonCode.label matches tagName" { ... }
```

**Phase 2 — Coverage tooling (Makefile + CI):**

```makefile
# make/test.mk — add coverage target
_test_coverage:
	@echo "→ Running tests with coverage..."
	@mkdir -p coverage
	zig build test 2>&1 | tee coverage/test-output.txt
	@echo "→ Coverage report requires kcov (install: brew install kcov)"
	@command -v kcov >/dev/null 2>&1 && \
		kcov --include-pattern=src/ coverage/ zig-out/bin/test || \
		echo "⚠ kcov not found — skipping coverage report"
```

```yaml
# .github/workflows/ci.yml — add coverage step
- name: Test with coverage
  run: make _test_coverage
- name: Upload coverage
  uses: codecov/codecov-action@v4
  with:
    directory: coverage/
```

**Phase 3 — Mock-based tests (interface boundaries):**
- Mock `pg.Conn` for `state.transition()`, `workspace.loadForEcho()`, `policy.recordPolicyEvent()`
- Mock subprocess runner for `git.run()` error paths
- Mock `agent.runSingle()` for pipeline flow tests without LLM calls

**Target coverage**: 60%+ on pure logic, 40%+ overall within M3.

---

## 22. Comment policy — agent-optimized, tokens-conscious

### Severity: Low

### Decision: tests over comments

Agents read code structure (function names, types, imports) faster than prose. Comments add tokens. Tests are executable documentation that agents can verify against.

### Policy

| Comment type | Rule | Rationale |
|--------------|------|-----------|
| Module `//!` | **Required** on every file | 1–2 lines; saves agents from reading entire file to understand purpose |
| Function `///` | **Only on public API boundaries** | `pub fn transition(...)` deserves a one-liner; internal helpers don't |
| Inline `//` | **Only for "why", never "what"** | Good: `// result must be fully consumed before we do more queries`. Bad: `// increment counter` |
| `TODO`/`FIXME` | **Allowed with ticket ref** | `// TODO(M3_005): add retry here` — agents can search for these |
| Removed code | **Delete, don't comment out** | `// was: old_function()` is noise; git has history |

### Current state: already good

usezombie follows this naturally. All 12 files have module `//!` headers. Inline comments are sparse and purposeful (e.g., `worker.zig:120`). No action needed beyond documenting the policy for future agents.

### Anti-pattern to avoid

Do NOT add comments like:
```zig
/// Increments the attempt counter in the database.
/// Takes a connection and run_id, returns the new attempt number.
pub fn incrementAttempt(conn: *pg.Conn, run_id: []const u8) !u32 {
```
The function name + signature already says this. The `///` comment burns tokens for zero value.
