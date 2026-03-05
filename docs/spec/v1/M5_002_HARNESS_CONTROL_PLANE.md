# M5_002: Harness Control Plane (Multi-Tenant Agent Profiles)

**Prototype:** v1.0.0
**Milestone:** M5
**Workstream:** 002
**Date:** Mar 05, 2026
**Status:** IN_PROGRESS
**Priority:** P0 — required for safe multi-tenant dynamic harnesses
**Depends on:** M4_003 dynamic topology runtime baseline

---

## 1.0 Objective and Contracts

**Status:** IN_PROGRESS

Introduce a multi-tenant control plane that compiles customer-authored harness definitions into validated executable agent profiles, stores them in DB, and activates one profile per workspace for deterministic runtime execution.

**Dimensions:**
- 1.1 DONE Define canonical terms: `role`, `skill`, `stage`, `transition`, `terminal`
- 1.2 DONE Define default fallback contract: if no active profile exists, runtime uses `default-v1` topology
- 1.3 DONE Define immutability contract: active profile cannot be mutated during run execution

---

## 2.0 Data Model (Generic, DB-Backed)

**Status:** DONE

Store profile source, compiled graph, activation state, and history in tenant-safe tables.

**Dimensions:**
- 2.1 DONE `agent_profiles` table contract
- 2.2 DONE `agent_profile_versions` table contract (source + compiled + validation report)
- 2.3 DONE `workspace_active_profile` binding contract (`workspace_id` -> `profile_version_id`)
- 2.4 DONE `profile_compile_jobs` contract for async compile/validate lifecycle
- 2.5 DONE `workspace_skill_secrets` contract for per-workspace skill credentials

### 2.1 `agent_profiles` (logical profile identity)

Required fields (assume base IDs/audit columns available):
- `profile_id` (stable slug, e.g., `acme-harness-v1`)
- `tenant_id`
- `workspace_id`
- `name`
- `status` (`DRAFT|ACTIVE|ARCHIVED`)

### 2.2 `agent_profile_versions` (immutable executable snapshots)

Required fields:
- `profile_version_id`
- `profile_id`
- `version` (monotonic integer)
- `source_markdown` (customer-authored harness)
- `compiled_profile_json` (runtime schema: stages/role/skill/on_pass/on_fail)
- `compile_engine` (model + parser version)
- `validation_report_json`
- `is_valid`

Compiled profile schema expectations:
- stage fields include `role`, `skill`, `on_pass`, `on_fail`
- `skill` supports explicit registry refs (example: `clawhub://openclaw/github-reviewer@1.2.0`)
- all skill refs must be version-pinned (no floating `latest`)

### 2.3 `workspace_active_profile`

Required fields:
- `workspace_id` (PK)
- `profile_version_id`
- `activated_by`
- `activated_at`

### 2.4 `profile_compile_jobs`

Required fields:
- `compile_job_id`
- `workspace_id`
- `requested_profile_id`
- `requested_version`
- `state` (`QUEUED|RUNNING|SUCCEEDED|FAILED`)
- `failure_reason`

### 2.5 `workspace_skill_secrets`

Required fields:
- `workspace_id`
- `skill_id` or `skill_ref`
- `key_name`
- `secret_ciphertext`
- `secret_meta_json` (source, rotation, scope)

Rules:
- Secrets are encrypted at rest.
- Secrets are never persisted in markdown/profile JSON/artifacts.
- Runtime secret injection is scoped to `{workspace_id, skill_ref}`.

---

## 3.0 API Surface

**Status:** DONE

Provide deterministic control-plane APIs for create, compile, validate, activate, and fetch active profile.

**Dimensions:**
- 3.1 DONE Create/update harness source API
- 3.2 DONE Compile+validate API
- 3.3 DONE Activate API
- 3.4 DONE Worker fetch-active-profile API
- 3.5 DONE Workspace skill secret management API

### 3.1 Authoring

- `PUT /v1/workspaces/{workspace_id}/harness/source`
  - Input: markdown harness text
  - Output: draft profile version metadata

### 3.2 Compile + Validate

- `POST /v1/workspaces/{workspace_id}/harness/compile`
  - Input: profile/version reference
  - Behavior: LLM-assisted parse to compiled graph + deterministic policy validation
  - Output: compile job id + validation result

### 3.3 Activate

- `POST /v1/workspaces/{workspace_id}/harness/activate`
  - Input: valid `profile_version_id`
  - Behavior: atomic swap in `workspace_active_profile`
  - Output: active version metadata

### 3.4 Runtime Fetch

- `GET /v1/workspaces/{workspace_id}/harness/active`
  - Output: active compiled profile JSON
  - Fallback: returns `default-v1` marker if no active profile is bound

### 3.5 Skill Secrets

- `PUT /v1/workspaces/{workspace_id}/skills/{skill_ref}/secrets/{key_name}`
  - Input: encrypted secret payload or secret reference
  - Output: secret version metadata
- `DELETE /v1/workspaces/{workspace_id}/skills/{skill_ref}/secrets/{key_name}`
  - Behavior: revoke secret for future runs

---

## 4.0 Compile and Validation Pipeline

**Status:** DONE

Use AI for parsing/authoring ergonomics, but enforce deterministic safety gates before execution.

**Dimensions:**
- 4.1 DONE Deterministic parse from markdown -> proposed graph JSON
- 4.2 DONE Deterministic schema validation and transition validation
- 4.3 DONE Policy guardrails (allowed skills, terminal set, retry/time budgets)
- 4.4 DONE Store validation report and reject invalid profiles from activation

Validation rules (minimum):
- Exactly one gate stage.
- Gate stage skill must be `warden` for v1.
- Allowed terminals: `done`, `retry`, `blocked`.
- All `on_pass`/`on_fail` targets must resolve to a declared stage or terminal.
- Skill allowlist must be tenant/workspace policy-driven. Default registry is ClawHub.
- Skill refs must be pinned to explicit versions.

---

## 5.0 Runtime Resolution Contract

**Status:** DONE

Worker runtime resolves execution profile per workspace deterministically.

**Dimensions:**
- 5.1 DONE Worker loads active profile by `workspace_id` at run start
- 5.2 DONE If missing/unavailable, worker uses `default-v1`
- 5.3 DONE Stage execution uses `{role, skill, on_pass, on_fail}` graph semantics
- 5.4 DONE Stage skill registry resolution errors produce explicit `BLOCKED` reason

Execution meaning:
- `role`: semantic responsibility label (`planner`, `security_reviewer`, `implementer`).
- `skill`: executable integration binding (how role runs; built-in or registry skill).

---

## 6.0 Multi-Tenant Safety and Isolation

**Status:** IN_PROGRESS

Prevent cross-tenant profile leakage and enforce per-tenant policy.

**Dimensions:**
- 6.1 DONE Tenant/workspace scoping on all profile APIs and queries
- 6.2 PENDING Skill allowlist and quotas per workspace
- 6.3 DONE Immutable audit history for source, compile result, and activation events
- 6.4 DONE Run-level snapshot pinning (run executes against activated version at start)
- 6.5 DONE Host vs sandbox env separation for skill secrets (OpenClaw model)

Secret handling approach (OpenClaw-aligned):
- Host execution: skill-scoped env/api key injection.
- Sandbox execution: explicit sandbox env injection only.
- No implicit inheritance of host secrets into sandbox.

---

## 7.0 Observability and Explainability

**Status:** PENDING

Add control-plane and runtime visibility to explain why stage transitions happened.

**Dimensions:**
- 7.1 PENDING Compile/validation events with profile ids/versions
- 7.2 PENDING Runtime transition events: `stage_id`, `skill`, verdict, next target
- 7.3 PENDING Activation history query for workspace debugging
- 7.4 PENDING Dry-run endpoint to preview transition path without side effects

---

## 8.0 Acceptance Criteria

**Status:** PENDING

- [x] 8.1 Customer markdown can be compiled into a valid executable profile JSON
- [x] 8.2 Invalid profiles cannot be activated
- [x] 8.3 Worker fetches active workspace profile and executes graph deterministically
- [x] 8.4 Missing active profile falls back to `default-v1` without behavior regression
- [x] 8.5 Profile activation is auditable and versioned
- [ ] 8.6 Multi-tenant isolation is enforced across all profile operations

---

## 9.0 Out of Scope

- Visual drag-and-drop DAG editor
- Runtime in-run profile mutation
- Cross-workspace shared mutable profile pointers
- Non-deterministic LLM-only control flow decisions without validation
