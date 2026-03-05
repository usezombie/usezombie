# M4_001: zombiectl CLI

Date: Mar 3, 2026
Status: PENDING
Priority: P1
Depends on: M1 control plane API operational

---

## Goal

Ship a client CLI (`zombiectl`) that lets humans and agents authenticate, connect repos, sync specs, trigger runs, and monitor progress — without touching the web UI or raw HTTP API.

## Location

`cli/` directory in the monorepo.

## Commands

```
zombiectl login                        # Browser OAuth via Clerk
zombiectl logout                       # Clear local auth
zombiectl workspace add <repo_url>     # Install GitHub App on repo, create workspace
zombiectl workspace list               # List connected workspaces
zombiectl workspace remove <id>        # Disconnect workspace
zombiectl specs sync [path]            # Sync PENDING_*.md specs from local dir to workspace
zombiectl run [spec_id]                # Trigger a run (or next queued spec)
zombiectl run status <run_id>          # Watch run progress (live polling)
zombiectl runs list                    # List recent runs with status
zombiectl doctor                       # Check connectivity, auth, workspace health
zombiectl harness source put <file>    # Upload harness markdown source for workspace
zombiectl harness compile [--version]  # Compile + validate workspace harness profile
zombiectl harness activate <version>   # Activate validated harness profile version
zombiectl harness active               # Fetch active profile (or default-v1 fallback)
zombiectl skills secret put <skill_ref> <key_name> --from-env <ENV> [--scope host|sandbox]
zombiectl skills secret delete <skill_ref> <key_name>
```

## Tech Stack

| Component | Choice | Why |
|-----------|--------|-----|
| Runtime | **Node.js + TypeScript** | Widest agent/developer reach. `npx` distribution. |
| CLI framework | **commander** | Standard, minimal, well-documented. |
| Auth | **Clerk SDK** | Device auth flow: CLI → browser → callback on localhost. |
| API client | **openapi-typescript** | Typed client auto-generated from `public/openapi.json`. |
| Config | `~/.zombie/config.json` | Auth tokens, default workspace, preferences. |
| Spinners | **ora** | Terminal spinners for async operations. |
| Colors | **chalk** | Terminal color output. |

## Authentication Flow

### `zombiectl login`

```
1. CLI starts local HTTP server on random port (e.g., localhost:9876)
2. CLI opens browser: https://usezombie.com/cli-auth?redirect=http://localhost:9876/callback
3. User authenticates via Clerk in browser
4. Clerk redirects to localhost:9876/callback?token=<session_token>
5. CLI captures token, stores in ~/.zombie/config.json
6. CLI shuts down local server
7. Output: "Logged in as alice@example.com"
```

### `zombiectl logout`

Deletes token from `~/.zombie/config.json`. Does not revoke server-side session (user can do that via web UI).

## Workspace Management

### `zombiectl workspace add <repo_url>`

```
1. CLI verifies auth (reads token from config)
2. CLI opens browser: GitHub App installation flow for <repo_url>
3. User authorizes repo access in GitHub
4. GitHub sends installation callback to UseZombie API
5. UseZombie API creates workspace, stores encrypted installation ID
6. CLI polls GET /v1/workspaces?repo_url=<repo_url> until workspace appears
7. Output: "Workspace created: ws_abc123 (github.com/user/repo)"
```

### `zombiectl workspace list`

```bash
$ npx zombiectl workspace list
ID          REPO                        STATUS    SPECS
ws_abc123   github.com/user/webapp      active    3 pending
ws_def456   github.com/user/api         active    0 pending
ws_ghi789   github.com/user/docs        paused    1 pending
```

### `zombiectl workspace remove <id>`

Disconnects workspace. Does not uninstall GitHub App (user does that in GitHub settings). Marks workspace as `disconnected` in UseZombie.

## Spec Sync

### `zombiectl specs sync [path]`

Scans `path` (default: current directory) for `PENDING_*.md` files. Uploads each to the default workspace (or workspace inferred from git remote).

```
1. CLI reads PENDING_*.md files from path
2. CLI resolves workspace from git remote URL (or --workspace flag)
3. POST /v1/workspaces/{id}:sync with spec contents
4. Output:
   Synced 2 specs to workspace ws_abc123:
     PENDING_001_add_auth.md → spec_aaa111
     PENDING_002_fix_search.md → spec_bbb222
```

## Run Management

### `zombiectl run [spec_id]`

Triggers a run for the given spec (or next queued spec in the workspace).

```
1. POST /v1/runs { workspace_id, spec_id }
2. CLI enters watch mode (polls GET /v1/runs/{id} every 2s)
3. Output:
   Run started: run_xyz789
   Echo planning... done (12s)
   Scout building... done (45s)
   Warden validating... PASS
   PR opened: https://github.com/user/webapp/pull/42
```

### `zombiectl run status <run_id>`

Same as watch mode above, for an existing run. Shows current state and live progress.

### `zombiectl runs list`

```bash
$ npx zombiectl runs list
ID          SPEC                    STATUS      DURATION    PR
run_xyz789  add_dark_mode           DONE        1m 12s      #42
run_abc123  fix_auth_timeout        RUNNING     0m 34s      —
run_def456  refactor_payments       BLOCKED     2m 01s      —
```

## Doctor

### `zombiectl doctor`

Checks connectivity and health of the local setup.

```bash
$ npx zombiectl doctor
Auth          ✓ Logged in as alice@example.com
API           ✓ https://api.usezombie.com/healthz (200 OK, 45ms)
Workspaces    ✓ 3 active workspaces
GitHub App    ✓ Installation valid for 3 repos
Config        ✓ ~/.zombie/config.json exists
```

## Harness And Skill Secrets

### `zombiectl harness source put <file>`

Uploads workspace harness markdown to `PUT /v1/workspaces/{workspace_id}/harness/source` and creates a new draft profile version.

### `zombiectl harness compile [--version <profile_version_id>]`

Triggers deterministic compile + validation via `POST /v1/workspaces/{workspace_id}/harness/compile`.

### `zombiectl harness activate <profile_version_id>`

Activates a validated profile version with `POST /v1/workspaces/{workspace_id}/harness/activate`.

### `zombiectl harness active`

Fetches current active profile using `GET /v1/workspaces/{workspace_id}/harness/active` and shows whether source is `active` or `default-v1`.

### `zombiectl skills secret put/delete`

Manages per-workspace, per-skill secrets:
- `PUT /v1/workspaces/{workspace_id}/skills/{skill_ref}/secrets/{key_name}`
- `DELETE /v1/workspaces/{workspace_id}/skills/{skill_ref}/secrets/{key_name}`

For ClawHub skill refs in `harness.md`, CLI URL-encodes `skill_ref` and stores secrets with explicit scope (`host` vs `sandbox`) to preserve injection boundaries.

## Config File

`~/.zombie/config.json`:

```json
{
  "auth": {
    "token": "<clerk_session_token>",
    "email": "alice@example.com",
    "expires_at": "2026-03-04T10:30:00Z"
  },
  "api_url": "https://api.usezombie.com",
  "default_workspace": "ws_abc123"
}
```

## usezombie.sh Integration

- `zombiectl` links to `https://usezombie.sh` (the `/agents` route) for machine-readable discovery.
- An LLM agent browsing `usezombie.sh` finds `agent-manifest.json` → discovers UseZombie API → can install `zombiectl` and use it.
- `skill.md` at `usezombie.sh/skill.md` contains onboarding instructions that reference `zombiectl`.

## Distribution

```bash
# End-user invocation (no install needed)
npx zombiectl login

# Global install
npm install -g zombiectl
zombiectl login
```

Package name: `zombiectl` on npm.

## Project Structure

```
cli/
├── package.json
├── tsconfig.json
├── src/
│   ├── index.ts              # Entry point, commander setup
│   ├── commands/
│   │   ├── login.ts
│   │   ├── logout.ts
│   │   ├── workspace.ts      # add, list, remove
│   │   ├── specs.ts          # sync
│   │   ├── run.ts            # run, status
│   │   ├── runs.ts           # list
│   │   └── doctor.ts
│   ├── api/
│   │   └── client.ts         # Auto-generated typed client from openapi.json
│   ├── auth/
│   │   └── clerk.ts          # Device auth flow
│   └── config/
│       └── store.ts          # ~/.zombie/config.json read/write
└── generated/
    └── api-types.ts           # openapi-typescript output
```

## Acceptance Criteria

1. `npx zombiectl login` opens browser, completes Clerk auth, saves token.
2. `npx zombiectl workspace add <url>` opens GitHub App install, creates workspace.
3. `npx zombiectl specs sync` finds PENDING_*.md files, syncs to workspace.
4. `npx zombiectl run` triggers a run, shows live progress, outputs PR URL on success.
5. `npx zombiectl doctor` checks auth, API, workspaces, and reports status.
6. All commands exit non-zero on failure with clear error messages.
7. Typed API client matches `public/openapi.json` — no manual endpoint definitions.

## Out of Scope

1. Interactive spec editor (specs are plain markdown files).
2. PR review commands (use `gh pr` for that).
3. Workspace settings/config (use web UI).
4. Billing management (use web UI).
5. Windows support for M2 (Linux + macOS only).

## References

- `docs/ARCHITECTURE.md` — Credential Model, Client Interfaces sections.
- `public/openapi.json` — API spec for typed client generation.
- `public/agent-manifest.json` — Machine-readable discovery.
- `public/skill.md` — Agent onboarding instructions.
