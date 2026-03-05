# v1 Codex Handoff — Full Implementation Scope

Date: Mar 4, 2026
Status: Ready for implementation
Reviewer: Oracle (CTO lens)

## Context

UseZombie is a Zig monorepo (`zombied` binary) using NullClaw as agent runtime, Zap HTTP server, pg.zig Postgres driver. M1 is complete — the basic Echo→Scout→Warden pipeline works but has critical bugs and no external service integration.

**v1 acceptance:** `zombiectl` can take specs from `https://github.com/indykish/terraform-provider-e2e`, process them through the pipeline, and produce validated PRs with good performance and security.

---

## Important: 

Read and follow: When the Milestone is complete mark with green tick + DONE in the relevant section of the doc and the relevant M3_xxx file.
If the M3_xxx is fully done, then move it to `docs/done/v1/` and keep the original filename (no `DONE_` prefix needed).

---

## v1 Milestone Dependency Graph

```
M3_001 (Bug Fixes) ─────────────────────────────┐
M3_000 (Secrets/Schema) ────────────────────────┤
                                                ├──→ M3_004 (Redis Streams) ──→ M4_001 (zombiectl CLI)
M3_006 (Clerk Auth) ────────────────────────────┤                                    │
                                                ├──→ M4_003 (Dynamic Agent Topology) ─┘
                                                │                               M4_002 (npm publish)
M3_005 (Security Hardening) ←── depends on ─────┘
M3_007 (Website) ──── independent, parallel ──────────────────────────────────────────
```

**Execution order:**

| Step | Milestones (parallel) | What |
|------|----------------------|------|
| 1 | ✅ M3_001 + ✅ M3_000 | Critical bug fixes + secrets schema separation — DONE (Mar 05, 2026) |
| 2 | ⏳ M3_004 + M3_006 | Redis streams + Clerk auth |
| 3 | ⏳ M3_005 | Security hardening (needs Redis + schema done) |
| 4 | ⏳ M4_001 | zombiectl CLI (needs Clerk + Redis + API hardened) |
| 5 | ⏳ M4_002 | npm publish |
| ∥ | ⏳ M4_003 | Dynamic agent topology (not hard-coded Echo/Scout/Warden); start during Part 1 and finish before CLI freeze |
| ∥ | ✅ M3_007 | Website (independent, can run in parallel with any step) — DONE (Mar 05, 2026) |

---

## ✅ DONE: Step 1 — M3_001 Critical Bug Fixes

Reference: `docs/spec/v1/M3_001_ORACLE_HEAD_TO_HEAD.md` (dimensions 1, 5, 7, 10, 11-20)

### ✅ DONE: 1.1 Transaction wrapping for run claiming

**File:** `src/pipeline/worker.zig`

The `FOR UPDATE SKIP LOCKED` query runs without `BEGIN`/`COMMIT`. Fix:

```sql
BEGIN;
SELECT ... FOR UPDATE OF r SKIP LOCKED;
UPDATE runs SET state = 'RUNNING' WHERE run_id = $1 AND state = 'SPEC_QUEUED';
COMMIT;
```

Commit after claiming. All subsequent transitions use CAS guards.

### ✅ DONE: 1.2 Compare-and-set state transitions

**File:** `src/state/machine.zig`

Replace two-query `getRunState()` + `UPDATE` with single atomic:

```sql
UPDATE runs SET state = $new_state, updated_at = NOW()
WHERE run_id = $run_id AND state = $expected_state
RETURNING state
```

Zero rows = invalid transition → return error.

### ✅ DONE: 1.3 Idempotency key scoped to workspace

**File:** `schema/001_initial.sql` + `src/http/handler.zig`

Change `UNIQUE(idempotency_key)` to `UNIQUE(workspace_id, idempotency_key)`. Update `handleStartRun` idempotency check query.

### ✅ DONE: 1.4 PR dedup guard

**File:** `src/pipeline/worker.zig`

Before `git.createPullRequest()`: `SELECT pr_url FROM runs WHERE run_id = $1`. Skip if not NULL.

### ✅ DONE: 1.5 Path canonicalization

**File:** `src/pipeline/worker.zig`

After constructing `spec_abs`: resolve to absolute, verify it starts with worktree path. Reject `..` traversal.

### ✅ DONE: 1.6 Git hook disabling

**File:** `src/git/ops.zig`

Add `-c core.hooksPath=/dev/null` to every git subprocess call.

### ✅ DONE: 1.7 Subprocess timeouts

**File:** `src/git/ops.zig`

Add `--max-time 30` / `--connect-timeout 10` to curl. Implement timeout wrapper for git subprocess: kill child after N seconds (clone=120s, commit=30s, push=60s).

### ✅ DONE: 1.8 SIGTERM handler + graceful shutdown

**File:** `src/main.zig`

Install `SIGTERM`/`SIGINT` handler via `std.posix.sigaction`. Set `worker_state.running = false`. Join worker thread. Transition in-progress run to BLOCKED. Clean up worktrees.

### ✅ DONE: 1.9 Per-run ArenaAllocator

**File:** `src/pipeline/worker.zig`

Create `ArenaAllocator` at start of `executeRun()`, `defer arena.deinit()`. Pass to all functions within the run. Matches per-request arena in `handler.zig`.

### ✅ DONE: 1.10 Health check depth

**File:** `src/http/handler.zig` + `src/http/server.zig`

`/healthz`: execute `SELECT 1` — return 503 if Postgres unreachable.
`/readyz`: check DB + worker thread liveness — return 503 if either is dead.

### ✅ DONE: 1.11 Memory lifecycle cleanup in git + tool builders (Dimension 1)

**File:** `src/git/ops.zig` + `src/pipeline/agents.zig`

- `src/git/ops.zig`: added a `CommandResources` lifecycle wrapper for subprocess execution (`spawn`/timeout/read/deinit). Timeout path now closes pipes, kills, waits, and returns deterministic timeout errors.
- `src/pipeline/agents.zig`: consolidated duplicated restricted tool construction into shared helpers to standardize ownership and cleanup behavior.

### ✅ DONE: 1.12 Centralized serve runtime config loading (Dimension 20)

**File:** `src/config/runtime.zig` + `src/main.zig`

- Added `ServeConfig.load()` to centralize serve-mode env parsing and validation (`PORT`, `API_KEY`, `ENCRYPTION_MASTER_KEY`, GitHub app env, worker/rate-limit knobs).
- `cmdServe` now consumes this typed config object instead of duplicating env parsing logic inline.

### ⚠️ PARTIAL: 1.13 Structured logging + observer backend wiring (Dimension 8)

**File:** `src/main.zig` + `src/pipeline/agents.zig`

- `src/main.zig`: logger now emits structured key/value lines (`ts_ms`, `level`, `scope`, JSON-safe `msg`) under runtime `LOG_LEVEL`.
- `src/pipeline/agents.zig`: NullClaw observer is now env-selectable via `NULLCLAW_OBSERVER=log|noop|verbose` (default `log`) instead of hardcoded `NoopObserver`.
- Remaining: correlation ID propagation across all layers and durable sink policy (`MultiObserver`/collector).

### ⚠️ PARTIAL: 1.14 Minimal event bus runtime (Dimension 4)

**File:** `src/events/bus.zig` + `src/main.zig` + `src/state/machine.zig` + `src/state/policy.zig` + `src/pipeline/agents.zig`

- Added bounded in-process event bus (`CAPACITY=1024`) with background sink thread and drop accounting.
- Wired event emission from state transitions (`state_transition`), policy decisions (`policy_event`), and agent run completions (`nullclaw_run`).
- Remaining: durable outbox/replay model and distributed event fan-out.

### ⚠️ PARTIAL: 1.15 Histogram timing metrics (Dimension 19)

**File:** `src/observability/metrics.zig` + `src/pipeline/worker.zig`

- Added Prometheus histogram-style series for `zombie_agent_duration_seconds` and `zombie_run_total_wall_seconds`.
- Worker now records agent call durations and end-to-end run wall time into histogram buckets.
- Remaining: trace/correlation propagation (`request_id`/`run_id`) across all telemetry surfaces.

### ⚠️ PARTIAL: 1.16 Readiness threshold gating (Dimension 18)

**File:** `src/config/runtime.zig` + `src/http/handler.zig` + `src/main.zig`

- Added optional readiness thresholds: `READY_MAX_QUEUE_DEPTH`, `READY_MAX_QUEUE_AGE_MS`.
- `/readyz` now returns `503` when queue depth/age breaches configured limits (in addition to DB/worker checks).
- Remaining: migration/dependency-aware readiness checks beyond queue/worker/database signals.

---

## ✅ DONE: Step 1 (parallel) — M3_000 Secrets + Schema Separation

Reference: `docs/done/v1/M3_000_SECRETS_HARDENING.md`

### ✅ DONE: 1A.1 Vault schema

**File:** `schema/002_vault_schema.sql` (new)

Create `vault` schema. Create roles: `api_accessor` (public only), `worker_accessor` (public + vault), `callback_accessor` (vault only). Move secrets to `vault.secrets` with BYTEA columns.

### ✅ DONE: 1A.2 Migration runner with version tracking

**File:** `src/db/pool.zig`

Create `schema_migrations` table. Track applied versions. Run each migration once, idempotently.

### ✅ DONE: 1A.3 Split DATABASE_URL per role

**File:** `src/main.zig` + `src/db/pool.zig`

Read `DATABASE_URL_API` and `DATABASE_URL_WORKER`. Fall back to `DATABASE_URL` for local dev.

### ✅ DONE: 1A.4 GitHub App JWT authentication

**File:** `src/auth/github.zig` (new)

RS256 JWT generation from `GITHUB_APP_PRIVATE_KEY`. Exchange for installation tokens. Cache until 5 min before expiry. Use for git push + PR creation. Replace curl-based PR creation.

### ✅ DONE: 1A.5 BYTEA secrets storage

**File:** `src/secrets/crypto.zig`

Return raw bytes from `encrypt()`. Accept raw bytes in `decrypt()`. Use BYTEA parameter binding with pg.zig.

---

## ⏳ PENDING: Step 2 — M3_004 Redis Streams

Reference: `docs/spec/v1/M3_004_REDIS_STREAMS.md`

### ⏳ TODO: 2.1 Redis client (RESP protocol)

**File:** `src/queue/redis.zig` (new)

Implement minimal RESP protocol client over TCP/TLS:
- `connect(url)` — parse `redis://` or `rediss://` URL, TCP + optional TLS
- `xadd(stream, fields)` — `XADD run_queue * run_id <id> attempt <n>`
- `xreadgroup(group, consumer, stream, block_ms, count)` — blocking read
- `xack(stream, group, message_id)` — acknowledge
- `xautoclaim(stream, group, consumer, min_idle_ms)` — reclaim stale
- `xgroupCreate(stream, group)` — create group with MKSTREAM

### ⏳ TODO: 2.2 API enqueue

**File:** `src/http/handler.zig`

After `INSERT INTO runs`: `redis.xadd("run_queue", .{.run_id = id, .attempt = "0", .workspace_id = ws_id})`.

### ⏳ TODO: 2.3 Worker dequeue

**File:** `src/pipeline/worker.zig`

Replace Postgres polling loop with:
```
while (running) {
    msg = redis.xreadgroup("workers", consumer_id, "run_queue", 5000, 1);
    if (msg) { processRun(msg); redis.xack(...); }
}
```

### ⏳ TODO: 2.4 Stale message recovery

**File:** `src/pipeline/worker.zig`

Periodic (every 60s): `redis.xautoclaim("run_queue", "workers", consumer_id, 300000)`. CAS guard in Postgres prevents double-processing.

### ⏳ TODO: 2.5 docker-compose.yml

Add `redis:7-alpine` service with ACL config from `config/redis-acl.conf`.

---

## ⏳ PENDING: Step 2 (parallel) — M3_006 Clerk Authentication

Reference: `docs/spec/v1/M3_006_CLERK_AUTH.md`

### ⏳ TODO: 2A.1 JWT verification

**File:** `src/auth/clerk.zig` (new)

Fetch JWKS from `CLERK_JWKS_URL` on startup. Verify RS256 JWT signatures. Extract `sub`, `org_id`, `tenant_id`. Cache JWKS, refresh every 6 hours.

### ⏳ TODO: 2A.2 Auth middleware

**File:** `src/http/handler.zig`

Replace `API_KEY` check with Clerk JWT verification. Fall back to `API_KEY` when `CLERK_SECRET_KEY` is not set (local dev).

### ⏳ TODO: 2A.3 Workspace authorization

**File:** `src/http/handler.zig`

After JWT verification: check that requested workspace belongs to user's tenant. Return 403 if not.

### ⏳ TODO: 2A.4 GitHub callback handler

**File:** `src/http/handler.zig` + `src/http/server.zig`

Add `GET /v1/github/callback` route. Handles GitHub App installation callback: `installation_id` + `setup_action`. Creates workspace row.

---

## ⏳ PENDING: Step 3 — M3_005 Security Hardening

Reference: `docs/spec/v1/M3_005_SECURITY_HARDENING.md`

This step coordinates and verifies work from Steps 1-2:

### ⏳ TODO: 3.1 Redis ACL configuration

**File:** `config/redis-acl.conf` (new)

```
user api_user on >api_password ~run_queue +xadd +xgroup +ping
user worker_user on >worker_password ~run_queue +xreadgroup +xack +xautoclaim +xgroup +ping +xinfo
user default off
```

### ✅ DONE: 3.2 Tailscale network policy documentation

Update `docs/DEPLOYMENT.md` section 2.1 with specific ACL rules (already done).

### ⏳ TODO: 3.3 Doctor security checks

**File:** `src/main.zig` (doctor subcommand)

Add checks: Postgres role grants, Redis ACL WHOAMI, required env vars present.

---

## ⏳ PENDING: Step 4 — M4_001 zombiectl CLI

Reference: `docs/spec/v1/M4_001_CLI_ZOMBIECTL.md`

### ⏳ TODO: 4.1 Tech stack and package scaffold

- Node.js 22 + TypeScript
- Use the create-cli skill(/create-cli) and create the cli using framework and guidelines mentioned there
- Clerk SDK for device auth
- `openapi-typescript` for typed API client -- is this needed consult the create-cli skill
- `ora` for spinners, `chalk` for colors -- is this needed consult the create-cli skill

### ⏳ TODO: 4.2 Directory layout

Consult the create-cli skill and follow that guideline,.

The below if deviates from the create-cli can be skipped.

```
cli/
├── package.json
├── tsconfig.json
├── bin/zombiectl.js
├── src/
│   ├── index.ts
│   ├── commands/login.ts
│   ├── commands/logout.ts
│   ├── commands/workspace.ts
│   ├── commands/specs.ts
│   ├── commands/run.ts
│   ├── commands/runs.ts
│   ├── commands/doctor.ts
│   ├── api/client.ts
│   ├── auth/clerk.ts
│   └── config/store.ts
└── generated/api-types.ts
```

### ⏳ TODO: 4.3 Commands


```
zombiectl login                        # Clerk device auth flow
zombiectl logout                       # Clear tokens

# Is this how an end user's UI will flow as well? create workspace and attache github repo?
zombiectl workspace add <repo_url>     # Install GitHub App, create workspace
zombiectl workspace list               # List workspaces
zombiectl workspace remove <id>        # Disconnect workspace
zombiectl specs sync [path]            # Sync PENDING_*.md from local dir
zombiectl run [spec_id]                # Trigger run
zombiectl run status <run_id>          # Live polling with spinner
zombiectl runs list                    # Recent runs with status
zombiectl doctor                       # Check auth, API, workspaces
```


### ⏳ TODO: 4.4 Auth flow

Device Authorization Grant (RFC 8628):

1. POST to Clerk device auth endpoint → get `device_code` + `user_code` + `verification_uri`
2. Open browser with `verification_uri`
3. Poll Clerk token endpoint every 5s until approved
4. Store JWT + refresh token in `~/.zombie/config.json`

---

## ⏳ PENDING: Step 5 — M4_002 npm Publish

Reference: `docs/spec/v1/M4_002_PUBLISH_CLI.md`

1. Configure `package.json`: `"name": "zombiectl"`, `"bin": {"zombiectl": "./bin/zombiectl.js"}`.
2. `npm publish --provenance --access public`.
3. CI: automated publish on tag push (already in `.github/workflows/release.yml`).
4. Verify: `npx zombiectl --help` works.

---

## ⏳ PENDING: Parallel — M4_003 Dynamic Agent Topology

Reference: `docs/spec/v1/M4_003_DONT_STICK_TO_STATIC_AGENTS.md`

### ⏳ TODO: 4A.1 Agent registry abstraction

Replace static role wiring (`echo`, `scout`, `warden`) with a registry-driven stage pipeline.

### ⏳ TODO: 4A.2 Config-driven stage graph

Load stage definitions from config (`id`, `role`, `prompt`, `tools`, `retry`, `timeout`, `on_pass`, `on_fail`) and execute deterministically.

### ⏳ TODO: 4A.3 Backward-compatible defaults

If no pipeline config is provided, boot with the current 3-stage flow as default profile.

### ⏳ TODO: 4A.4 Observability and state semantics

Preserve transition/audit semantics while allowing new roles and stages to emit metrics/logs without code changes.

---

## ✅ DONE: Parallel — M3_007 Static Website

Reference: `docs/done/v1/M3_007_WEBSITE_STATIC.md`

Can be built independently of all backend work.

### ✅ DONE: Setup

```
website/
├── package.json
├── vite.config.ts
├── tailwind.config.ts
├── src/
│   ├── App.tsx
│   ├── pages/Home.tsx        # usezombie.com /
│   ├── pages/Pricing.tsx     # usezombie.com /pricing
│   └── pages/Agents.tsx      # usezombie.sh /agents
└── public/
    ├── openapi.json          # Copied from monorepo public/
    ├── agent-manifest.json
    ├── skill.md
    ├── llms.txt
    └── heartbeat
```

### ✅ DONE: Domains

- `usezombie.com` → Vercel (landing + pricing)
- `usezombie.sh` → Vercel (agent discovery + machine-readable assets)
- DNS via Cloudflare

---

## v1 Acceptance Test

**Target repo:** `https://github.com/indykish/terraform-provider-e2e`

```bash
# 1. Auth
npx zombiectl login

# 2. Connect repo
npx zombiectl workspace add https://github.com/indykish/terraform-provider-e2e

# 3. Sync specs
npx zombiectl specs sync docs/spec/

# 4. Run all specs → PRs
npx zombiectl run

# 5. Verify
npx zombiectl runs list
# → Each spec has a PR with DONE status
```

**Performance target:** Spec-to-PR under 5 minutes per spec on OVH bare-metal.

---

## Environment Variables (Complete v1)

```dotenv
# Core
API_KEY=local-dev-api-key                    # Local dev fallback; supports comma-separated rotation window
ENCRYPTION_MASTER_KEY=<64 hex chars>

# Database (role-separated)
DATABASE_URL=postgres://...                  # Local dev fallback
DATABASE_URL_API=postgres://api_accessor:...
DATABASE_URL_WORKER=postgres://worker_accessor:...

# Redis
REDIS_URL=redis://localhost:6379             # Local dev fallback
REDIS_URL_API=rediss://api_user:...
REDIS_URL_WORKER=rediss://worker_user:...

# GitHub App
GITHUB_APP_ID=
GITHUB_APP_PRIVATE_KEY=
GITHUB_CLIENT_ID=
GITHUB_CLIENT_SECRET=

# Clerk
CLERK_SECRET_KEY=
CLERK_JWKS_URL=
CLERK_PUBLISHABLE_KEY=

# Agent runtime
NULLCLAW_API_KEY=                            # Default LLM key (or BYOK per workspace)
NULLCLAW_OBSERVER=log                        # log|noop|verbose (default: log)
AGENT_CONFIG_DIR=/app/config
DEFAULT_MAX_ATTEMPTS=3
WORKER_CONCURRENCY=1
LOG_LEVEL=info
RATE_LIMIT_CAPACITY=30
RATE_LIMIT_REFILL_PER_SEC=5.0
READY_MAX_QUEUE_DEPTH=                       # Optional readiness threshold; 503 when queue depth exceeds this value
READY_MAX_QUEUE_AGE_MS=                      # Optional readiness threshold; 503 when oldest queued age exceeds this value

# Git
GIT_CACHE_ROOT=/tmp/zombie-git-cache

# Feature flags
FEATURE_PAYMENTS_ENABLED=false
```

---

## Files Created/Modified (Complete v1)

```
# Step 1: Bug fixes + secrets
src/main.zig                    — SIGTERM handler, thread join, split DB URLs, doctor checks
src/db/pool.zig                 — Migration runner, dual pool
src/http/handler.zig            — Healthz DB probe, readyz, idempotency scope, auth middleware
src/http/server.zig             — Add /readyz, /v1/github/callback routes
src/pipeline/worker.zig         — BEGIN/COMMIT, per-run arena, PR dedup, path validation
src/state/machine.zig           — CAS transitions
src/git/ops.zig                 — Hook disabling, subprocess timeouts
src/secrets/crypto.zig          — BYTEA output
src/auth/github.zig             — NEW: GitHub App JWT + installation tokens
schema/001_initial.sql          — Fix idempotency_key constraint
schema/002_vault_schema.sql     — NEW: vault schema + roles
schema/embed.zig                — Embed 002

# Step 2: Redis + Clerk
src/queue/redis.zig             — NEW: RESP protocol client
src/auth/clerk.zig              — NEW: JWT verification + JWKS
docker-compose.yml              — Add Redis service
config/redis-acl.conf           — NEW: Redis ACL rules
.env.example                    — All new env vars

# Step 4: CLI
cli/                            — NEW: entire zombiectl CLI directory
.github/workflows/ci.yml        — Already has cli lint/test jobs
.github/workflows/release.yml   — Already has npm publish job

# Parallel: Website
website/                        — NEW: static website directory
```

---

## What Is NOT in v1 Scope

- libgit2 migration (v2)
- Firecracker microVM executor (v2)
- PostHog Zig SDK (v2)
- Full envelope encryption with KMS-backed KEK (v2)
- Multi-worker concurrency / token bucket rate limiting (v2)
- Mission Control UI at `app.usezombie.com` (v3)
- Team model / workspace access control (v2 design, v3 implementation)
- Dodo billing integration (v3)
