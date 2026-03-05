# M3_006: Clerk Authentication — API + CLI Contract

**Prototype:** v1.0.0
**Milestone:** M3
**Workstream:** 006
**Date:** Mar 05, 2026
**Status:** IN_PROGRESS
**Priority:** P0 — v1 requirement
**Depends on:** M4_001 (CLI surface), M4_003 (dynamic runtime topology)

---

## 1.0 API Authentication Path

**Status:** IN_PROGRESS

Move API auth from static bearer key only to Clerk JWT verification with local-dev fallback.

**Dimensions:**
- 1.1 DONE Added `src/auth/clerk.zig` with RS256 JWT verification against JWKS (`n`/`e`) and claim extraction
- 1.2 DONE JWKS caching implemented in verifier with 6-hour refresh window
- 1.3 DONE API handler auth now uses Clerk JWT when Clerk is configured; falls back to `API_KEY` only when Clerk is disabled
- 1.4 DONE `token_expired` 401 mapping added for expired JWTs

---

## 2.0 Authorization Path

**Status:** IN_PROGRESS

Enforce tenant-scoped workspace access checks for authenticated principals.

**Dimensions:**
- 2.1 DONE Tenant/workspace authorization enforced for run start/get/retry, specs list, pause, and sync endpoints
- 2.2 DONE Clerk principal tenant extraction (`metadata.tenant_id`) wired to workspace checks
- 2.3 IN_PROGRESS M2M scope policy is supported through shared JWT path but lacks dedicated operator runbook examples

---

## 3.0 Operational Validation

**Status:** IN_PROGRESS

Ensure operator checks can validate auth dependencies deterministically.

**Dimensions:**
- 3.1 DONE `zombied doctor` now validates Clerk JWKS reachability when Clerk is enabled
- 3.2 DONE Runtime env contract extended with Clerk vars (`CLERK_JWKS_URL`, `CLERK_ISSUER`, `CLERK_AUDIENCE`) in `.env.example`
- 3.3 DONE Unit/integration tests added for JWT signature verification, audience validation, and token expiry behavior

---

## 4.0 Acceptance Criteria

**Status:** IN_PROGRESS

- [ ] 4.1 `zombiectl login/logout` device flow implemented (CLI)
- [x] 4.2 API requires valid Clerk JWT when Clerk mode is enabled
- [x] 4.3 Expired JWT returns deterministic `token_expired` 401
- [x] 4.4 Tenant-scoped workspace authorization enforced in API handlers
- [ ] 4.5 Dedicated CLI token refresh/storage flows implemented
- [ ] 4.6 GitHub callback onboarding path fully integrated with CLI polling/webhook flow

---

## 5.0 Out of Scope

- Clerk frontend components
- Team/workspace RBAC model beyond tenant matching
- Session management UI
