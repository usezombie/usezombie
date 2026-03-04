# UseZombie

Agent Delivery Control Plane — one Zig binary that takes a spec and ships a validated PR.

## What it does

UseZombie connects a spec queue to a coordinated agent team (Echo → Scout → Warden) and ships validated PRs with retry loops, structured defect reports, and full audit trails.

## Stack

- `zombied` — one static Zig binary (~2-3MB). HTTP API + worker pipeline + agent runtime.
- PlanetScale Postgres — state, transitions, artifacts, workspace memories.
- Upstash Redis Streams — dispatch queue. Zero CPU while idle.
- NullClaw — native Zig agent runtime via `@import("nullclaw")`. No subprocess.
- GitHub App OAuth — per-workspace repo access with short-lived tokens.

## Dev Commands

```bash
cp .env.example .env
make up        # start Postgres + zombied
make quality   # fmt + lint
make test      # unit tests
make down      # stop services
```

## Public API

- `POST /v1/runs` — queue a spec-to-PR run
- `GET /v1/runs/{run_id}` — get run status + transitions + artifacts
- `POST /v1/runs/{run_id}:retry` — retry a blocked run
- `POST /v1/workspaces/{workspace_id}:pause` — pause a workspace
- `GET /v1/specs` — list specs for a workspace
- `POST /v1/workspaces/{workspace_id}:sync` — sync PENDING_*.md specs from repo

Full spec: `public/openapi.json`

## Machine-Readable Surfaces

- `public/openapi.json` — OpenAPI 3.1 spec
- `public/agent-manifest.json` — JSON-LD agent discovery
- `public/llms.txt` — LLM-friendly API summary
- `public/skill.md` — agent onboarding instructions

## Binary

```bash
zombied serve    # HTTP API + worker loop (M1: combined)
zombied doctor   # check Postgres, config, LLM key (planned)
zombied run      # one-shot spec run (planned)
```

## Links

- Product: https://usezombie.com
- AI-focused: https://usezombie.ai
- Agent discovery: https://usezombie.sh
- Repo: https://github.com/usezombie/usezombie
