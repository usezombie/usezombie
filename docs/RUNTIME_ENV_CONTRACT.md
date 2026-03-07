# Runtime Environment Contract

Date: Mar 07, 2026
Status: Active
Owner workstream: `docs/spec/v1/M4_007_RUNTIME_ENV_CONTRACT.md`

## Goal

Define one canonical environment-variable contract for `zombied` and `zombiectl` so startup, operations, and troubleshooting remain deterministic.

## Precedence Policy

- Security-critical values are env-only.
- Non-secret operator ergonomics may use CLI overrides.
- Allowed override order: `CLI flag > env var > default`.

Current expectation:
- `zombied`: env-first runtime.
- `zombiectl`: keep slim; only non-secret convenience flags should override env.

## Required Runtime Keys

These must be present for secure `zombied serve` operation.

- `ENCRYPTION_MASTER_KEY`: required, exactly 64 hex chars.
- `GITHUB_APP_ID`: required, non-empty.
- `GITHUB_APP_PRIVATE_KEY`: required, non-empty.
- `DATABASE_URL_API`: required, non-empty.
- `DATABASE_URL_WORKER`: required, non-empty and different from `DATABASE_URL_API`.
- `REDIS_URL_API`: required, must use `rediss://`.
- `REDIS_URL_WORKER`: required, must use `rediss://` and differ from `REDIS_URL_API`.

Auth mode:
- Clerk enabled (`CLERK_SECRET_KEY` non-empty): `CLERK_JWKS_URL` is required.
- Clerk disabled: `API_KEY` must be present with at least one usable key.

## Runtime Knobs

Validated at startup:
- `PORT` (default `3000`)
- `DEFAULT_MAX_ATTEMPTS` (default `3`, must be `> 0`)
- `WORKER_CONCURRENCY` (default `1`, must be `> 0`)
- `RUN_TIMEOUT_MS` (default `300000`, must be `> 0`)
- `RATE_LIMIT_CAPACITY` (default `30`, must be `> 0`)
- `RATE_LIMIT_REFILL_PER_SEC` (default `5.0`, must be `> 0`)
- `READY_MAX_QUEUE_DEPTH` (optional, if set must be `> 0`)
- `READY_MAX_QUEUE_AGE_MS` (optional, if set must be `> 0`)

## Doctor Contract

`zombied doctor` must deterministically validate:
- role-separated DB/Redis env presence and non-equality
- Redis TLS scheme (`rediss://`)
- API and worker DB config load
- Redis readiness and ACL identity checks
- required secrets (`ENCRYPTION_MASTER_KEY`, GitHub App keys)
- auth reachability (`CLERK_JWKS_URL` when Clerk is enabled)

Output must stay machine-parseable and stable for CI/operator automation.

## Canonical Trace Context

For telemetry payloads/events, standardize these fields:
- `trace_id`
- `span_id`
- `request_id`

`correlation_id` is optional, only for cross-trace joins (for example, linking one user action to multiple traces).

## Rotation Terms

- Key-versioned envelope metadata: encrypted records include the key version used for encryption (`kek_version`).
- No-downtime rotation: dual-read/single-write behavior during key rollout so traffic continues uninterrupted.

## Drift Rule

When behavior changes:
1. Update this file first.
2. Update `.env.example` and deployment docs in the same change.
3. Ensure `zombied serve` and `zombied doctor` validations still match documented contract.
