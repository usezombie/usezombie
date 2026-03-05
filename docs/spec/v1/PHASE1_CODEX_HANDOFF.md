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
If the M3_xxx is fully done, then rename M3_XXX to DONE_M3_xxx...md and move it to docs/done/v1/..

---

## v1 Milestone Dependency Graph

```
M3_001 (Bug Fixes) ─────────────────────────────┐
M3_000 (Secrets/Schema) ────────────────────────┤
                                                ├──→ M3_004 (Redis Streams) ──→ M4_001 (zombiectl CLI)
M3_006 (Clerk Auth) ────────────────────────────┤                                    │
                                                │                               M4_002 (npm publish)
M3_005 (Security Hardening) ←── depends on ─────┘
M3_007 (Website) ──── independent, parallel ──────────────────────────────────────────
```

**Execution order:**

| Step | Milestones (parallel) | What |
|------|----------------------|------|
| 1 | ✅ M3_001 + ✅ M3_000 | Critical bug fixes + secrets schema separation — DONE (Mar 05, 2026) |
| 2 | M3_004 + M3_006 | Redis streams + Clerk auth |
| 3 | M3_005 | Security hardening (needs Redis + schema done) |
| 4 | M4_001 | zombiectl CLI (needs Clerk + Redis + API hardened) |
| 5 | M4_002 | npm publish |
| ∥ | ✅ M3_007 | Website (independent, can run in parallel with any step) — DONE (Mar 05, 2026) |

---

## ✅ DONE: Step 1 — M3_001 Critical Bug Fixes

Reference: `docs/done/v1/DONE_M3_001_ORACLE_HEAD_TO_HEAD.md` (dimensions 5, 7, 11-20)

### 1.1 Transaction wrapping for run claiming

**File:** `src/pipeline/worker.zig`

The `FOR UPDATE SKIP LOCKED` query runs without `BEGIN`/`COMMIT`. Fix:

```sql
BEGIN;
SELECT ... FOR UPDATE OF r SKIP LOCKED;
UPDATE runs SET state = 'RUNNING' WHERE run_id = $1 AND state = 'SPEC_QUEUED';
COMMIT;
```

Commit after claiming. All subsequent transitions use CAS guards.

### 1.2 Compare-and-set state transitions

**File:** `src/state/machine.zig`

Replace two-query `getRunState()` + `UPDATE` with single atomic:

```sql
UPDATE runs SET state = $new_state, updated_at = NOW()
WHERE run_id = $run_id AND state = $expected_state
RETURNING state
```

Zero rows = invalid transition → return error.

### 1.3 Idempotency key scoped to workspace

**File:** `schema/001_initial.sql` + `src/http/handler.zig`

Change `UNIQUE(idempotency_key)` to `UNIQUE(workspace_id, idempotency_key)`. Update `handleStartRun` idempotency check query.

### 1.4 PR dedup guard

**File:** `src/pipeline/worker.zig`

Before `git.createPullRequest()`: `SELECT pr_url FROM runs WHERE run_id = $1`. Skip if not NULL.

### 1.5 Path canonicalization

**File:** `src/pipeline/worker.zig`

After constructing `spec_abs`: resolve to absolute, verify it starts with worktree path. Reject `..` traversal.

### 1.6 Git hook disabling

**File:** `src/git/ops.zig`

Add `-c core.hooksPath=/dev/null` to every git subprocess call.

### 1.7 Subprocess timeouts

**File:** `src/git/ops.zig`

Add `--max-time 30` / `--connect-timeout 10` to curl. Implement timeout wrapper for git subprocess: kill child after N seconds (clone=120s, commit=30s, push=60s).

### 1.8 SIGTERM handler + graceful shutdown

**File:** `src/main.zig`

Install `SIGTERM`/`SIGINT` handler via `std.posix.sigaction`. Set `worker_state.running = false`. Join worker thread. Transition in-progress run to BLOCKED. Clean up worktrees.

### 1.9 Per-run ArenaAllocator

**File:** `src/pipeline/worker.zig`

Create `ArenaAllocator` at start of `executeRun()`, `defer arena.deinit()`. Pass to all functions within the run. Matches per-request arena in `handler.zig`.

### 1.10 Health check depth

**File:** `src/http/handler.zig` + `src/http/server.zig`

`/healthz`: execute `SELECT 1` — return 503 if Postgres unreachable.
`/readyz`: check DB + worker thread liveness — return 503 if either is dead.

---

## ✅ DONE: Step 1 (parallel) — M3_000 Secrets + Schema Separation

Reference: `docs/done/v1/DONE_M3_000_SECRETS_HARDENING.md`

### 1A.1 Vault schema

**File:** `schema/002_vault_schema.sql` (new)

Create `vault` schema. Create roles: `api_accessor` (public only), `worker_accessor` (public + vault), `callback_accessor` (vault only). Move secrets to `vault.secrets` with BYTEA columns.

### 1A.2 Migration runner with version tracking

**File:** `src/db/pool.zig`

Create `schema_migrations` table. Track applied versions. Run each migration once, idempotently.

### 1A.3 Split DATABASE_URL per role

**File:** `src/main.zig` + `src/db/pool.zig`

Read `DATABASE_URL_API` and `DATABASE_URL_WORKER`. Fall back to `DATABASE_URL` for local dev.

### 1A.4 GitHub App JWT authentication

**File:** `src/auth/github.zig` (new)

RS256 JWT generation from `GITHUB_APP_PRIVATE_KEY`. Exchange for installation tokens. Cache until 5 min before expiry. Use for git push + PR creation. Replace curl-based PR creation.

### 1A.5 BYTEA secrets storage

**File:** `src/secrets/crypto.zig`

Return raw bytes from `encrypt()`. Accept raw bytes in `decrypt()`. Use BYTEA parameter binding with pg.zig.

---

## Step 2: M3_004 — Redis Streams

Reference: `docs/spec/v1/M3_004_REDIS_STREAMS.md`

### 2.1 Redis client (RESP protocol)

**File:** `src/queue/redis.zig` (new)

Implement minimal RESP protocol client over TCP/TLS:
- `connect(url)` — parse `redis://` or `rediss://` URL, TCP + optional TLS
- `xadd(stream, fields)` — `XADD run_queue * run_id <id> attempt <n>`
- `xreadgroup(group, consumer, stream, block_ms, count)` — blocking read
- `xack(stream, group, message_id)` — acknowledge
- `xautoclaim(stream, group, consumer, min_idle_ms)` — reclaim stale
- `xgroupCreate(stream, group)` — create group with MKSTREAM

### 2.2 API enqueue

**File:** `src/http/handler.zig`

After `INSERT INTO runs`: `redis.xadd("run_queue", .{.run_id = id, .attempt = "0", .workspace_id = ws_id})`.

### 2.3 Worker dequeue

**File:** `src/pipeline/worker.zig`

Replace Postgres polling loop with:
```
while (running) {
    msg = redis.xreadgroup("workers", consumer_id, "run_queue", 5000, 1);
    if (msg) { processRun(msg); redis.xack(...); }
}
```

### 2.4 Stale message recovery

**File:** `src/pipeline/worker.zig`

Periodic (every 60s): `redis.xautoclaim("run_queue", "workers", consumer_id, 300000)`. CAS guard in Postgres prevents double-processing.

### 2.5 docker-compose.yml

Add `redis:7-alpine` service with ACL config from `config/redis-acl.conf`.

---

## Step 2 (parallel): M3_006 — Clerk Authentication

Reference: `docs/spec/v1/M3_006_CLERK_AUTH.md`

### 2A.1 JWT verification

**File:** `src/auth/clerk.zig` (new)

Fetch JWKS from `CLERK_JWKS_URL` on startup. Verify RS256 JWT signatures. Extract `sub`, `org_id`, `tenant_id`. Cache JWKS, refresh every 6 hours.

### 2A.2 Auth middleware

**File:** `src/http/handler.zig`

Replace `API_KEY` check with Clerk JWT verification. Fall back to `API_KEY` when `CLERK_SECRET_KEY` is not set (local dev).

### 2A.3 Workspace authorization

**File:** `src/http/handler.zig`

After JWT verification: check that requested workspace belongs to user's tenant. Return 403 if not.

### 2A.4 GitHub callback handler

**File:** `src/http/handler.zig` + `src/http/server.zig`

Add `GET /v1/github/callback` route. Handles GitHub App installation callback: `installation_id` + `setup_action`. Creates workspace row.

---

## Step 3: M3_005 — Security Hardening

Reference: `docs/spec/v1/M3_005_SECURITY_HARDENING.md`

This step coordinates and verifies work from Steps 1-2:

### 3.1 Redis ACL configuration

**File:** `config/redis-acl.conf` (new)

```
user api_user on >api_password ~run_queue +xadd +xgroup +ping
user worker_user on >worker_password ~run_queue +xreadgroup +xack +xautoclaim +xgroup +ping +xinfo
user default off
```

### 3.2 Tailscale network policy documentation

Update `docs/DEPLOYMENT.md` section 2.1 with specific ACL rules (already done).

### 3.3 Doctor security checks

**File:** `src/main.zig` (doctor subcommand)

Add checks: Postgres role grants, Redis ACL WHOAMI, required env vars present.

---

## Step 4: M4_001 — zombiectl CLI

Reference: `docs/spec/v1/M4_001_CLI_ZOMBIECTL.md`

### Tech stack

- Node.js 22 + TypeScript
- Use the create-cli skill(/create-cli) and create the cli using framework and guidelines mentioned there
- Clerk SDK for device auth
- `openapi-typescript` for typed API client -- is this needed consult the create-cli skill
- `ora` for spinners, `chalk` for colors -- is this needed consult the create-cli skill

### Directory

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

### Commands


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


### Auth flow

Device Authorization Grant (RFC 8628):

1. POST to Clerk device auth endpoint → get `device_code` + `user_code` + `verification_uri`
2. Open browser with `verification_uri`
3. Poll Clerk token endpoint every 5s until approved
4. Store JWT + refresh token in `~/.zombie/config.json`

---

## Step 5: M4_002 — npm Publish

Reference: `docs/spec/v1/M4_002_PUBLISH_CLI.md`

1. Configure `package.json`: `"name": "zombiectl"`, `"bin": {"zombiectl": "./bin/zombiectl.js"}`.
2. `npm publish --provenance --access public`.
3. CI: automated publish on tag push (already in `.github/workflows/release.yml`).
4. Verify: `npx zombiectl --help` works.

---

## ✅ DONE: Parallel — M3_007 Static Website

Reference: `docs/done/v1/DONE_M3_007_WEBSITE_STATIC.md`

Can be built independently of all backend work.

### Setup

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

### Domains

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
API_KEY=local-dev-api-key                    # Local dev fallback only
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
AGENT_CONFIG_DIR=/app/config
DEFAULT_MAX_ATTEMPTS=3

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
