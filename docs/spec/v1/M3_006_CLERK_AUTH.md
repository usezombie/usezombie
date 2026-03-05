# M3_006: Clerk Authentication — CLI + API

Date: Mar 4, 2026
Status: PENDING
Priority: P0 — v1 requirement
Depends on: M4_001 (CLI must exist to integrate auth)

---

## Problem

1. The API uses a static `API_KEY` bearer token. No user identity, no multi-tenancy.
2. `zombiectl` has no authentication implementation.
3. Machine-to-machine (M2M) auth for agent-to-agent pipelines is not implemented.
4. No workspace-level authorization — any valid token accesses any workspace.

## Solution

Clerk provides three auth flows needed for v1:

### Flow 1: CLI Device Auth (zombiectl login)

For human users authenticating from a terminal:

```
1. zombiectl login
2. CLI generates a device code + user code
3. CLI opens browser: https://usezombie.com/device?code=XXXX-YYYY
4. User authenticates via Clerk (email, OAuth, passkey)
5. Clerk redirects with approval
6. CLI polls Clerk's token endpoint until approved
7. CLI receives JWT access token + refresh token
8. Stored in ~/.zombie/config.json
```

**Why device flow (not localhost redirect):**
- Works in SSH sessions, containers, remote machines.
- No need for local HTTP server.
- Standard OAuth 2.0 device authorization grant (RFC 8628).

**Clerk configuration:**
- Application type: Native/CLI
- OAuth grant: `urn:ietf:params:oauth:grant-type:device_code`
- Token lifetime: 1 hour (with refresh)

### Flow 2: API Bearer Token Auth

Every API request includes `Authorization: Bearer <clerk_jwt>`.

**API-side verification:**
1. Extract JWT from Authorization header.
2. Verify JWT signature using Clerk's JWKS endpoint (cached).
3. Extract `sub` (user ID), `org_id` (optional), `metadata.tenant_id`.
4. Look up user's workspaces in Postgres: `WHERE tenant_id = $1`.
5. Reject if the requested workspace doesn't belong to the user's tenant.

**JWKS caching:** Fetch `https://<clerk-domain>/.well-known/jwks.json` on startup, refresh every 6 hours or on verification failure.

### Flow 3: Machine-to-Machine (M2M) Auth

For autonomous agents (AI PM, CI pipelines):

1. Create M2M application in Clerk with client credentials grant.
2. Agent authenticates: `POST /oauth/token` with `client_id` + `client_secret`.
3. Receives JWT with `sub = machine_<id>`, `iss = <clerk_issuer>`.
4. Same JWT verification path as Flow 2.

**Environment variables for M2M:**
```dotenv
CLERK_M2M_ISSUER=https://clerk.usezombie.com
CLERK_M2M_AUDIENCE=https://api.usezombie.com
```

### Flow 4: GitHub App Callback (Workspace Onboarding)

When a user runs `zombiectl workspace add <repo_url>`:

1. CLI opens browser: `https://github.com/apps/usezombie/installations/new`
2. User installs GitHub App on their repo.
3. GitHub redirects to `https://api.usezombie.com/v1/github/callback?installation_id=123&setup_action=install`
4. API verifies the callback, creates workspace row in Postgres.
5. API returns workspace ID to the CLI (via polling or webhook).

## Implementation

### zombied API Changes

```
src/auth/clerk.zig         — NEW: JWT verification, JWKS fetching, user context extraction
src/http/handler.zig       — Replace API_KEY check with Clerk JWT verification
src/http/server.zig        — Add GET /v1/github/callback route
```

**Auth middleware flow:**
```
Request → Extract Bearer token → Verify JWT signature (JWKS) → Extract user/tenant context → Check workspace authorization → Handler
```

**Backward compatibility:** Keep `API_KEY` auth as a fallback for local dev. If `CLERK_SECRET_KEY` is not set, fall back to `API_KEY` validation.

### zombiectl CLI Changes (M4_001 integration)

```
cli/src/auth/clerk.ts      — Device flow implementation
cli/src/auth/token.ts      — Token storage, refresh, expiry check
cli/src/commands/login.ts   — zombiectl login command
cli/src/commands/logout.ts  — zombiectl logout command
cli/src/api/client.ts       — Auto-attach Bearer token to all API calls
```

### Clerk Instances

| Environment | Instance | Domain |
|---|---|---|
| Local | Reuse dev instance | `clerk.dev.usezombie.com` |
| Development | Dev instance | `clerk.dev.usezombie.com` |
| Production | Prod instance | `clerk.usezombie.com` |

### Environment Variables

```dotenv
# API side
CLERK_SECRET_KEY=sk_live_...           # For JWT verification
CLERK_PUBLISHABLE_KEY=pk_live_...      # For frontend (future)
CLERK_JWKS_URL=https://clerk.usezombie.com/.well-known/jwks.json
CLERK_WEBHOOK_SECRET=whsec_...         # For Clerk webhooks (user sync)

# CLI side (built into the binary, not env vars)
CLERK_DEVICE_AUTH_URL=https://clerk.usezombie.com/oauth/device/code
CLERK_TOKEN_URL=https://clerk.usezombie.com/oauth/token
CLERK_CLIENT_ID=<cli_app_client_id>
```

## Acceptance Criteria

1. `zombiectl login` completes device auth flow, stores JWT in `~/.zombie/config.json`.
2. `zombiectl logout` clears stored tokens.
3. All API requests require valid Clerk JWT (or `API_KEY` fallback for local dev).
4. JWT expired → 401 response with `{"error":"token_expired"}`.
5. User can only access workspaces belonging to their tenant.
6. M2M client credentials flow works for agent-to-agent pipelines.
7. `zombiectl workspace add` triggers GitHub App install + callback.
8. `zombied doctor` checks Clerk connectivity (JWKS endpoint reachable).

## Auth Milestone Sequence

| Step | Component | Milestone |
|---|---|---|
| 1 | API: JWT verification + JWKS | M3_006 (this spec) |
| 2 | CLI: device auth flow | M4_001 + M3_006 |
| 3 | API: workspace authorization | M3_006 |
| 4 | CLI: GitHub App callback | M4_001 + M3_006 |
| 5 | M2M: client credentials | M3_006 |
| 6 | Mission Control UI: Clerk frontend | v3 |

## Out of Scope

- Clerk frontend components (React/Next.js) — v3 Mission Control UI.
- Team/workspace access model (design in v2, implement in v3).
- Session management UI — v3.
