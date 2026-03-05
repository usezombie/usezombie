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
| 1 | Memory leaks | **Medium** | ✅ Command/process lifecycle now uses explicit resource bundling and shared tool-builder ownership patterns | ResourceBundle pattern, errdefer at boundaries |
| 2 | Allocation best practices | **Medium** | Single GPA for worker; many manual frees | Per-run ArenaAllocator; bounded buffers |
| 3 | Async / API performance | **High** | Configurable multi-worker threads via `WORKER_CONCURRENCY`; deeper async/provider concurrency still missing | Multi-worker + concurrent dispatch |
| 4 | Event bus / actor dispatch | **Medium** | Ad-hoc log lines only | Ring-buffer MPSC bus (`bus.zig`) |
| 5 | Reliability & retry | **Critical** | `reliable_call` wrappers now cover Scout/Warden + token/push/PR (with PR detail plumbing); no outbox/circuit-breaker yet | `reliable.zig` + outbox + dead-letter |
| 6 | Rate limiting | **High** | Tenant token-bucket limiter added in worker; provider-level policy still missing | Token bucket per tenant/provider |
| 7 | Backoff | **Critical** | Jittered exponential backoff added in worker loop and retry path; PR HTTP `Retry-After` is now consumed, other paths still incomplete | Exponential + jitter + Retry-After parsing |
| 8 | Logging (.env / agent-friendly) | **Medium** | Runtime `LOG_LEVEL` supported; logs still unstructured text | Runtime `LOG_LEVEL`; key=value structured logs |
| 9 | Logging on errors | **High** | Critical silent catches reduced; richer classification/context remains incomplete | Classification + context + correlation IDs |
| 10 | Error code classification | **Critical** | `error_classify.zig` wired in worker with explicit `AUTH_FAILED`/`RATE_LIMITED` reason codes; API-layer mapping still coarse | `error_classify.zig`: rate_limited / context_exhausted / auth / server_error |

### Oracle Verification Snapshot (Mar 05, 2026)

| # | Status | Missing / remaining work |
|---|---|---|
| 1 | ✅ Fixed | `src/git/ops.zig` now uses a `CommandResources` lifecycle wrapper (`spawn`/timeout/read/deinit), and agent restricted tool builders are consolidated in `src/pipeline/agents.zig` |
| 2 | ⚠️ Partial | Per-run arena added in worker, but allocator/thread model not fully normalized |
| 3 | ⚠️ Partial | Worker concurrency is now configurable with multiple threads; provider/tool dispatch is still blocking/sequential per run |
| 4 | ❌ Open | No event bus implementation yet |
| 5 | ⚠️ Partial | `reliable_call` now wraps Scout/Warden and GitHub token/push/PR paths (with PR response detail plumbing); outbox/dead-letter and circuit breaker are still missing |
| 6 | ⚠️ Partial | Tenant token-bucket throttling now gates Echo/Scout/Warden calls; provider-level quotas and distributed state are still missing |
| 7 | ⚠️ Partial | Worker loop and run retry now use exponential+jitter backoff; PR HTTP `Retry-After` is plumbed, but provider/API responses are not yet end-to-end |
| 8 | ⚠️ Partial | Runtime `LOG_LEVEL` is implemented; structured key/value logging and observer wiring are still missing |
| 9 | ⚠️ Partial | Critical silent catches on worker/http paths are reduced, but full classification/context consistency is still missing |
| 10 | ⚠️ Partial | `error_classify` drives worker failure mapping with explicit auth/quota reason codes; richer provider payload parsing and HTTP/API harmonization are still missing |
| 11 | ⚠️ Partial | Path canonicalization + hook disable done; env scrubbing/sandbox hardening still pending |
| 12 | ⚠️ Partial | Signal handling + join done; stale worktree startup cleanup still missing |
| 13 | ⚠️ Partial | Claim transaction + CAS done; idempotency conflict flow still not fully race-safe at handler level |
| 14 | ⚠️ Partial | PR dedupe and no-op commit handling done; no side-effect ledger |
| 15 | ⚠️ Partial | Git/curl timeouts done; agent-call cancellation/deadline still missing |
| 16 | ⚠️ Partial | Main allocator is now thread-safe and worker concurrency is configurable; global leak-reporting/thread-safety guardrails still need tightening |
| 17 | ⚠️ Partial | Versioned migrations + tx done; SQL splitting remains heuristic |
| 18 | ⚠️ Partial | `/healthz` + `/readyz` improved, and `/readyz` now exposes queue depth + oldest age; richer readiness policy is still missing |
| 19 | ⚠️ Partial | `/metrics` endpoint + core counters are available; observer wiring and correlation propagation are still missing |
| 20 | ⚠️ Partial | Serve now fails fast on invalid critical config and supports API key rotation; secret versioning/rotation model is still missing |
| 21 | ⚠️ Partial | Unit/integration/e2e targets added; coverage measurement and deeper module tests still missing |
| 22 | ✅ Fixed | Comment policy section exists and is aligned with current style |

---

## 1. Memory leaks — arena usage, defer hygiene, errdefer patterns
**Status (Mar 05, 2026): ✅ Fixed**

### What nullclaw does well
- Explicit ownership conventions with consistent "caller owns" vs "borrowed" APIs
- Defensive `errdefer` cleanup at all boundaries (tools, providers, observers)
- Lifecycle bundling: components constructed/deconstructed as a unit (provider + observer + rate limiter)

### usezombie fixes applied

| File | Scope | Fix |
|------|-------|-----|
| `src/git/ops.zig` | `run()` subprocess lifecycle | Added `CommandResources` wrapper with explicit `init`/`readOutput`/`deinit`; timeout path now closes pipes, kills child, waits, and always deinitializes |
| `src/pipeline/agents.zig` | Restricted tool builders | Replaced duplicated manual `alloc.create + errdefer` blocks with shared `buildRestrictedTools` + `appendTool` helpers to normalize ownership and cleanup flow |

### Outcome
- No known open leak/ownership blockers remain for this dimension in current M3 scope.

---

## 2. Allocation best practices — GPA vs arena vs fixed-buffer
**Status (Mar 05, 2026): ⚠️ Partial**

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
**Status (Mar 05, 2026): ⚠️ Partial**

### What nullclaw does well
- Concurrent tool/provider dispatch with cancellation boundaries
- `dispatcher.zig` architecture supports parallelism

### usezombie gaps

| File | Line | Issue |
|------|------|-------|
| `src/pipeline/worker.zig` | 4–5 | Per-worker execution remains sequential ("one spec at a time for M1") |
| `src/main.zig` | 198–236 | `WORKER_CONCURRENCY` adds parallel worker threads, but no dynamic autoscaling/backpressure policy exists yet |
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

### Oracle review: remaining scope after this fix
- Move from thread-level parallelism to non-blocking/provider-aware call dispatch where needed.
- Add queue-depth/backpressure metrics to tune `WORKER_CONCURRENCY` safely in production.
- Add fairness controls to prevent noisy-tenant starvation under high parallel load.

---

## 4. Event bus / actor-based dispatch
**Status (Mar 05, 2026): ❌ Open**

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
**Status (Mar 05, 2026): ⚠️ Partial**

### What nullclaw does well
- `ReliableProvider`: wraps any provider with retry + backoff + classification + rate limit + circuit breaker
- `VectorOutbox`: durable outbox with retry semantics + dead-letter purge
- `CircuitBreaker`: pure state machine (closed → open → half_open)

### usezombie gaps

| File | Line | Issue |
|------|------|-------|
| `src/reliability/reliable_call.zig` | 1–93 | Generic retry wrapper now supports detail-aware classification via `callWithDetail`, but most call sites still use error-name-only path |
| `src/pipeline/worker.zig` | 410–568 | Scout/Warden and token/push/PR are wrapped with call-level retries, but run-level reliability still lacks durable outbox/dead-letter semantics |
| `src/pipeline/worker.zig` | 214–220 | Run-level retry still applies for full pipeline failures; there is no dead-letter/outbox ledger |
| `src/git/ops.zig` | 28–52 | Core subprocess abstraction still lacks a single reusable timeout+classification contract |

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

### Oracle review: remaining scope after this fix
- Add reliable wrappers for callback/webhook network operations and any remaining external side effects.
- Add durable outbox/dead-letter tracking for side effects (push/PR/create-installation updates).
- Add circuit-breaker state for repeated provider outages to avoid retry storms.

---

## 6. Rate limiting
**Status (Mar 05, 2026): ⚠️ Partial**

### What nullclaw does well
- Rate limit detection + API key rotation on 429
- Token bucket / leaky bucket integrated with retries

### usezombie gaps

| File | Line | Issue |
|------|------|-------|
| `src/pipeline/worker.zig` | 64–116 | In-memory tenant limiter exists, but state is local to a single process (not shared across workers/hosts) |
| `src/pipeline/worker.zig` | 415–568 | Echo/Scout/Warden are throttled per tenant, but side effects (push/PR/webhook) are not rate-limited |
| `src/main.zig` | 163–170 | Limits are env-configurable, but there is no per-provider/per-model tuning |

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

### Oracle review: remaining scope after this fix
- Extend throttling to external side effects (GitHub API/webhooks) and provider-specific channels.
- Move bucket state to shared storage (Redis/Postgres) once multi-worker or multi-host execution is enabled.
- Add visibility metrics for throttling decisions and wait durations.

---

## 7. Backoff — backpressure, exponential backoff, Retry-After
**Status (Mar 05, 2026): ⚠️ Partial**

### What nullclaw does well
- Exponential backoff with jitter
- `parseRetryAfterMs()` — parses Retry-After header from error messages
- Backpressure hooks interact with circuit breaker

### usezombie gaps

| File | Line | Issue |
|------|------|-------|
| `src/pipeline/worker.zig` | 91–103 | Worker-loop adaptive backoff exists, but only from internal errors and queue idle/work states |
| `src/pipeline/worker.zig` | 569–572 | Retry delay is jittered, but only PR path currently injects external `Retry-After` detail |
| `src/reliability/error_classify.zig` | 34–46 | `Retry-After` parser is case-insensitive and active when detail payload is provided; most non-PR call sites still pass no detail |
| `src/git/ops.zig` | 264–334 | PR creation now parses HTTP status and returns typed errors, but other external calls do not expose response headers/details |

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

### Oracle review: remaining scope after this fix
- Thread provider/API response text into `reliable.call(...)` so `Retry-After` can actually govern delay.
- Normalize one backoff policy for worker loop, run loop, and external side effects.
- Add metrics for backoff events (count, wait time, class) to validate behavior under load.

---

## 8. Logging — .env level control, agent-friendly structured logs
**Status (Mar 05, 2026): ❌ Open**

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
**Status (Mar 05, 2026): ⚠️ Partial**

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
**Status (Mar 05, 2026): ⚠️ Partial**

### What nullclaw does well
- `error_classify.zig`: classifies API error payloads into `rate_limited`, `context_exhausted`, `vision_unsupported`, `other`
- Classification drives: retry decision, backoff amount, circuit breaker, user-facing reason code
- `reliable.zig`: `isNonRetryable()`, `isRateLimited()`, `isContextExhausted()`, `parseRetryAfterMs()`

### usezombie gaps

| File | Line | Issue |
|------|------|-------|
| `src/reliability/error_classify.zig` | 1–203 | Classifier now includes typed PR error mapping and explicit auth/quota reasons, but matching remains mostly string-heuristic |
| `src/pipeline/worker.zig` | 210–225 | Worker transition uses classified reason code and logs class/retryability, but not all external call sites pass detailed payload context |
| `src/http/handler.zig` | 35–46 | Public API errors are still generic and not linked to internal classifier taxonomy |
| `src/types.zig` | 62–79 | Dedicated `AUTH_FAILED` and `RATE_LIMITED` reason codes now exist, but broader HTTP/API response harmonization is pending |

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

### Oracle review: remaining scope after this fix
- Replace heuristic string matching with structured HTTP/provider error parsing where possible.
- Add/confirm explicit `ReasonCode` variants for auth and quota classes to improve operability.
- Align HTTP response mapping and worker/internal classification so operator view and API semantics stay consistent.

## Implementation priority order

| Priority | Work item | Effort | Dimension(s) |
|----------|-----------|--------|---------------|
| **P0 (remaining)** | Expand `reliable_call.zig` + `error_classify.zig` + `expBackoffJitter` coverage (`Retry-After` plumbing, agent-call wrapping, richer parsing) | M (4–6h) | 5, 7, 10 |
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
| 19 | Metrics / telemetry / tracing | **Medium** | NoopObserver and incomplete correlation propagation remain, though core counters are now exposed |
| 20 | Config validation & secret hygiene | **Medium–High** | Core fail-fast and API key rotation exist; encrypted-secret key versioning/rotation is still missing |

---

## 11. Secure execution boundary — untrusted repo content
**Status (Mar 05, 2026): ⚠️ Partial**

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
**Status (Mar 05, 2026): ⚠️ Partial**

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
**Status (Mar 05, 2026): ⚠️ Partial**

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
**Status (Mar 05, 2026): ⚠️ Partial**

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
**Status (Mar 05, 2026): ⚠️ Partial**

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
**Status (Mar 05, 2026): ⚠️ Partial**

### Severity: High

### Gaps

| File | Line | Issue |
|------|------|-------|
| `src/main.zig` | 89–97 | Main GPA is now thread-safe, but leak reporting remains permissive (deinit result not enforced) |
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

### Oracle review: remaining scope after this fix
- Enforce leak-check handling in debug builds instead of discarding `gpa.deinit()` status.
- Confirm Zap runtime thread model and document allocator expectations explicitly.
- Audit remaining shared allocators/caches for thread-safety under `WORKER_CONCURRENCY > 1`.

---

## 17. Schema migration safety
**Status (Mar 05, 2026): ⚠️ Partial**

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
**Status (Mar 05, 2026): ⚠️ Partial**

### Severity: Medium–High

### Gaps

| File | Line | Issue |
|------|------|-------|
| `src/http/handler.zig` | 95–137 | `/readyz` now includes queue depth and oldest queued age, but readiness does not yet enforce thresholds/SLO-aware gating |

### Recommendation
- `/livez` — process alive (static, fast)
- `/readyz` — checks: DB connectivity, migrations applied, worker loop healthy, queue depth
- Include oldest-queued-run age for operational alerting

### Oracle review: remaining scope after this fix
- Define readiness gating thresholds (for example queue age SLO breach) instead of pure informational queue metrics.
- Add migration-state and dependency checks to readiness beyond DB reachability.
- Surface queue health in `/metrics` for alert-driven operations.

---

## 19. Metrics / telemetry / tracing
**Status (Mar 05, 2026): ⚠️ Partial**

### Severity: Medium

### Gaps

| File | Line | Issue |
|------|------|-------|
| `src/http/server.zig` | 35–42 | `/metrics` endpoint exists and is Prometheus-scrapeable, but there is no auth/TLS boundary guidance yet |
| `src/observability/metrics.zig` | 1–168 | Core counters/gauges are present, but no histogram/latency distribution and no trace correlation IDs |
| `src/pipeline/agents.zig` | 109–111, 177–179, 246–248 | `NoopObserver` — nullclaw's observability hooks disabled |
| `src/pipeline/agents.zig` | 30–40 | Single log line for "nullclaw_run" events |
| `src/http/handler.zig` | 49–54 | `request_id` generated but not propagated to worker/state transitions |

### Recommendation
- Wire `LogObserver` or `MultiObserver` instead of `NoopObserver`
- Propagate `request_id` through the full run lifecycle
- Expose `/metrics` endpoint with: runs_total, runs_completed, retries_total, agent_duration_seconds, queue_depth

### Oracle review: remaining scope after this fix
- Add histogram-style timing metrics (agent latency, end-to-end run latency) for SLO usefulness.
- Wire NullClaw observer backends so metrics/logs/traces share correlation metadata.
- Document secure scrape pattern (network policy, auth proxy, or internal-only exposure).

---

## 20. Configuration validation & secret hygiene
**Status (Mar 05, 2026): ⚠️ Partial**

### Severity: Medium–High

### Gaps

| File | Line | Issue |
|------|------|-------|
| `src/main.zig` | 151–241 | Fail-fast checks now cover `PORT`, GitHub app env, key format, and numeric config parsing, but readiness does not yet report config drift |
| `src/http/handler.zig` | 58–74 | `API_KEY` now supports comma-separated rotation window, but key source is still static env and not vaulted per tenant |
| `src/secrets/crypto.zig` | 21–32 | Master key loaded from env still has no key version prefix and no online rotation flow |

### Recommendation
- Fail-fast in `serve` for required config (not only `doctor`)
- Support comma-separated API keys: `API_KEY=key1,key2` — accept any valid key (rotation window)
- Add key version prefix to encrypted envelopes for rotation support

### Oracle review: remaining scope after this fix
- Add versioned encryption envelope format (`kek_version`) so key rotation is operationally safe.
- Add serve-time config validation for dependency reachability (not only env format/presence).
- Move long-lived static keys from plain env to managed secret source with rotation runbook.

---

## Updated implementation priority (combined)

| Priority | Work item | Effort | Dimension(s) |
|----------|-----------|--------|---------------|
| **P0** | Transactional correctness (BEGIN/COMMIT, CAS transitions, idempotency index) | M (4–6h) | 13 |
| **P0** | Side-effect idempotency (PR dedupe, side-effect ledger) | M (3–4h) | 14 |
| **P0** | Secure execution boundary (path canonicalization, hook disable, env scrub) | M (3–4h) | 11 |
| **P0 (remaining)** | Expand `reliable_call.zig` + `error_classify.zig` + `expBackoffJitter` coverage (`Retry-After` plumbing, agent-call wrapping, richer parsing) | M (4–6h) | 5, 7, 10 |
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
**Status (Mar 05, 2026): ⚠️ Partial**

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
**Status (Mar 05, 2026): ✅ Fixed**

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
