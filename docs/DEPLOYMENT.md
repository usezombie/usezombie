# Deployment Guide — UseZombie v1

Date: Mar 4, 2026
Status: Active v1 deployment contract

## Goal

Deploy a CLI-first UseZombie control plane where API and worker roles are deterministic, Redis-backed, and secure by default. v1 uses NullClaw built-in sandbox and hardened git CLI. v2 adds Firecracker isolation and libgit2.

## 1. Prerequisites

- `zig` 0.15.2+, `git`, `curl`, `jq`, `gh` installed
- Access to Postgres 18.2 and Redis 7
- Tailscale tailnet configured for control-plane and worker hosts
- GitHub App credentials and installation flow configured
- Clerk application configured (device flow for CLI, JWT verification for API)
- Cloudflare DNS for `usezombie.com`, `usezombie.sh`, `api.usezombie.com`, `docs.usezombie.com`

## 2. One-Time Setup

### 2.1 Network policy baseline (Tailscale)

1. Join API and worker nodes to the same Tailscale tailnet.
2. Configure Tailscale ACLs:
   - API nodes → Postgres (5432), Redis (6379), GitHub API (443)
   - Worker nodes → Postgres (5432), Redis (6379), GitHub API (443), LLM providers (443)
   - External → API only (443 via load balancer)
   - External → Postgres, Redis, Worker: DENIED
3. For managed Postgres/Redis: set IP allowlists to Tailscale exit node IPs.

### 2.2 Control-plane identities and secrets

1. Configure GitHub App (`GITHUB_APP_ID`, `GITHUB_APP_PRIVATE_KEY`, callback URL `https://api.usezombie.com/v1/github/callback`).
2. Configure Clerk application (device flow for CLI, secret key for API JWT verification).
3. Configure runtime encryption key (`ENCRYPTION_MASTER_KEY` — 64 hex chars).
4. Configure separate database credentials for API (`api_accessor`) and worker (`worker_accessor`) roles.
5. Configure separate Redis credentials for API (`api_user`) and worker (`worker_user`).
6. Store all secrets in environment-specific vault entries (Proton Pass: `CLW_{LOCAL,DEV,PROD}`).

### 2.3 Redis setup

1. Create Redis stream and consumer group:
   ```
   XGROUP CREATE run_queue workers 0 MKSTREAM
   ```
2. Configure ACLs:
   ```
   ACL SETUSER api_user on >api_password ~run_queue +xadd +xgroup +ping
   ACL SETUSER worker_user on >worker_password ~run_queue +xreadgroup +xack +xautoclaim +xgroup +ping +xinfo
   ACL SETUSER default off
   ```

### 2.4 DNS (Cloudflare)

| Record | Type | Target |
|---|---|---|
| `usezombie.com` | CNAME | Vercel (static website) |
| `usezombie.sh` | CNAME | Vercel (static website) |
| `api.usezombie.com` | CNAME | Railway/Fly/Render (zombied API) |
| `docs.usezombie.com` | CNAME | Mintlify |
| `app.usezombie.com` | — | v2 (not configured for v1) |

## 3. Environment Matrix

### 3.1 Environment Local

Purpose: local development and API/worker contract testing.

In scope:
- `zombiectl` CLI development (Node.js 22)
- `zombied` API + worker (Zig binary)
- Postgres 18.2 (docker container)
- Redis 7 (docker container with ACL config)
- `docker-compose.yml` for local service orchestration

Out of scope for local:
- Vercel website (test with `npm run dev` locally)
- Firecracker isolation (macOS has no KVM)
- Full Tailscale network policy
- PostHog analytics

Local notes:
1. Run API/worker/Postgres/Redis via Docker Compose.
2. Clerk: reuse dev instance for auth E2E. Skip for pure API development (use `API_KEY` fallback).
3. NullClaw sandbox may use bubblewrap on Linux Docker or degrade gracefully on macOS.
4. Website: `cd website && npm run dev` for local preview.

### 3.2 Environment Development

Purpose: integration environment for team testing and reliability checks.

Components:
- Website on Vercel: `dev.usezombie.com` (preview deployment)
- Database: `usezombie-dev` (Postgres 18.2 — PlanetScale or Neon)
- Cache: `usezombie-dev` (Upstash Redis, TLS required)
- Clerk: development instance (`clerk.dev.usezombie.com`)
- Worker nodes: OVH VM/bare-metal low-cost pool
- Control-plane host: Railway/Fly/Render (cost-optimized)
- PostHog project: development

Development expectations:
1. Redis stream semantics (`XADD`, `XREADGROUP`, `XACK`, `XAUTOCLAIM`) fully operational.
2. Tailscale + IP allowlisting enforced before team access.
3. Clerk JWT auth enforced (no `API_KEY` fallback in dev).
4. NullClaw sandbox active with Landlock backend on Linux workers.

### 3.3 Environment Production

Purpose: customer-facing execution environment.

Components:
- Website: `usezombie.com` + `usezombie.sh` on Vercel
- Database: `usezombie` (Postgres 18.2 — production instance)
- Cache: `usezombie-cache` (Upstash Redis, TLS required)
- Clerk: production instance (`clerk.usezombie.com`)
- Control-plane host: Railway/Fly/Render (cost + reliability tradeoff)
- Worker nodes: OVH bare-metal/discounted server pool (M2+ class)
- PostHog project: production
- Docs: `docs.usezombie.com` (Mintlify)

Production expectations:
1. All security hardening from M3_005 enforced.
2. Clerk JWT auth required for all API access.
3. Database role separation (api_accessor / worker_accessor) enforced.
4. Redis ACLs enforced (separate API/worker credentials).
5. Secrets rotation and audit reporting required before customer workloads.
6. v2 additions (Firecracker, libgit2) required before multi-tenant customer workloads.

## 4. Deploy

Deploy in sequence.

### Step 1: DNS + Website

1. Configure Cloudflare DNS records per section 2.4.
2. Deploy static website to Vercel from `website/` directory.
3. Verify `usezombie.com` and `usezombie.sh` load correctly.
4. Verify `usezombie.sh/openapi.json` and `usezombie.sh/agent-manifest.json` return valid responses.

### Step 2: Data plane (Postgres + Redis)

1. Provision Postgres 18.2 database for current environment.
2. Provision Redis 7 with TLS enabled.
3. Create Postgres roles (`api_accessor`, `worker_accessor`, `callback_accessor`) with grants per M3_000.
4. Apply DB migrations (`001_initial.sql`, `002_vault_schema.sql`).
5. Create Redis stream and consumer group. Configure Redis ACLs per section 2.3.

### Step 3: Authentication (Clerk)

1. Configure Clerk application with device flow (CLI) and JWT verification (API).
2. Set environment variables: `CLERK_SECRET_KEY`, `CLERK_JWKS_URL`.
3. Configure GitHub App callback URL: `https://api.usezombie.com/v1/github/callback`.

### Step 4: Control-plane API (`zombied serve`)

1. Deploy API instance(s) on selected host.
2. Configure env vars:
   - `DATABASE_URL_API`
   - `REDIS_URL_API`
   - `CLERK_SECRET_KEY`
   - `CLERK_JWKS_URL`
   - `GITHUB_APP_ID`
   - `GITHUB_CLIENT_ID`
   - `GITHUB_CLIENT_SECRET`
3. Verify `/healthz` and `/readyz` endpoints.

### Step 5: Worker (`zombied worker`)

1. Deploy worker on Linux host (Tailscale-connected).
2. Configure env vars:
   - `DATABASE_URL_WORKER`
   - `REDIS_URL_WORKER`
   - `ENCRYPTION_MASTER_KEY`
   - `GITHUB_APP_ID`
   - `GITHUB_APP_PRIVATE_KEY`
   - `NULLCLAW_API_KEY` (default LLM key, or rely on BYOK per workspace)
3. Verify worker joins Redis consumer group and claims queued runs.

### Step 6: CLI distribution

1. Publish `zombiectl` to npm: `npm publish --access public`.
2. Verify: `npx zombiectl login` → device auth → token stored.
3. Verify: `npx zombiectl doctor` → all checks pass.

## 5. Verify

```bash
# API liveness/readiness
curl -sS https://api.usezombie.com/healthz
curl -sS https://api.usezombie.com/readyz

# CLI auth
npx zombiectl login
npx zombiectl doctor

# Workspace setup
npx zombiectl workspace add https://github.com/indykish/terraform-provider-e2e

# Submit a run
npx zombiectl specs sync docs/spec/
npx zombiectl run

# Check run state
npx zombiectl run status <run_id>
```

Redis coordination checks:
```bash
redis-cli -u "$REDIS_URL" XINFO STREAM run_queue
redis-cli -u "$REDIS_URL" XPENDING run_queue workers
```

## 6. Smoke Tests

1. `zombiectl login` → Clerk device auth completes → token stored.
2. `zombiectl workspace add` → GitHub App installed → workspace created.
3. `zombiectl specs sync` → specs synced to workspace.
4. Submit spec via CLI and confirm run enters `SPEC_QUEUED`.
5. Confirm worker claims run from Redis and writes state transitions.
6. Force one validation failure and verify retry loop re-enqueues via Redis.
7. Confirm successful run creates PR and marks `DONE`.
8. Kill one worker mid-run and verify `XAUTOCLAIM` reclaims the stale message.

**Acceptance test repo:** `https://github.com/indykish/terraform-provider-e2e`

## 7. Third-Party Services (v1)

| Service | v1 | v2 | Purpose | Notes |
|---|---|---|---|---|
| GitHub App | Yes | Yes | Repo access + PR creation | Installation tokens, not PATs |
| Postgres 18.2 | Yes | Yes | System of record | Role separation (api/worker/callback) |
| Redis 7 (Upstash) | Yes | Yes | Queue + coordination | Stream + consumer-group + ACLs |
| Tailscale | Yes | Yes | Network allowlisting | Restrict service reachability |
| Clerk | Yes | Yes | AuthN/AuthZ | Device flow (CLI), JWT (API), M2M (agents) |
| Cloudflare | Yes | Yes | DNS + CDN | All domains |
| Vercel | Yes | Yes | Static website hosting | usezombie.com + usezombie.sh |
| Mintlify | Yes | Yes | Docs portal | docs.usezombie.com |
| Firecracker | No | Yes | Execution isolation | v2 — KVM required |
| PostHog | Recommended | Yes | Product analytics | Not required for v1 launch |
| Langfuse | Pending | Pending | Agent tracing | Decide before production hardening |
| Dodo | Optional | Optional | Billing | Feature-flagged for initial free launch |

## 8. Pending: Langfuse Project

Decision needed before production launch:

1. Approve Langfuse as tracing backend, or
2. Select alternative (Helicone/OpenTelemetry collector + warehouse).

Minimum requirement either way: run-level traceability by `run_id` and attempt.

## 9. Dodo Account

Dodo is optional for initial free launch.

1. Keep billing disabled (`FEATURE_PAYMENTS_ENABLED=false`) for early release.
2. Integrate Dodo only after entitlement and webhook verification pass.

## 10. docs.usezombie.com (Mintlify)

Source:
- `https://github.com/usezombie/docs`
- local path: `~/Projects/docs`

Deployment expectations:
1. Keep API and CLI contracts in sync with public docs.
2. Publish architecture and deployment updates before changing runtime behavior.
3. Link machine-readable assets (`openapi.json`, `agent-manifest.json`, `llms.txt`, `skill.md`) from docs.

## 11. Security Hardening Checklist

Before production launch, verify all items from M3_005:

- [ ] Tailscale ACLs configured — workers unreachable from external networks
- [ ] Postgres role separation — `api_accessor` cannot read `vault.secrets`
- [ ] Redis ACLs — API user cannot XREADGROUP, worker user cannot write arbitrary keys
- [ ] GitHub tokens — installation-scoped, 1-hour lifetime, never stored
- [ ] Clerk JWT — all API requests authenticated (no `API_KEY` in production)
- [ ] TLS on all Postgres and Redis connections
- [ ] `ENCRYPTION_MASTER_KEY` in memory only, never logged
- [ ] `zombied doctor` reports security posture
