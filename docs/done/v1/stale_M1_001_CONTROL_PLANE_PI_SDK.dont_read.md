# DONE 001: Control Plane Sprint 1

Date: Feb 28, 2026
Status: Completed (implemented and verified)

## Goal
Define Sprint 1 control-plane behavior with explicit channel ingress rules (web + agent API only), deterministic run lifecycle, and clear worker-to-control-plane contracts so every run is reproducible from command intake to terminal outcome.

## Explicit assumptions
1. GitHub is the only forge in Sprint 1.
2. Sprint 1 has no OpenClaw Gateway integration; chat/voice ingress is deferred to a later phase.
3. Execution agents (Echo/Scout/Warden) run as PI Agent instances inside isolated workers. Control plane remains the source of run-state truth.
4. Control-plane API is canonical for lifecycle transitions, idempotency, and policy decisions.
5. Retry budget is bounded and configured per workspace policy.

## In-scope
1. [x] Deterministic lifecycle: `SPEC_QUEUED -> RUN_PLANNED -> PATCH_IN_PROGRESS -> PATCH_READY -> VERIFICATION_IN_PROGRESS -> PR_PREPARED -> PR_OPENED -> NOTIFIED -> DONE`.
2. [x] Failure path: `VERIFICATION_IN_PROGRESS -> VERIFICATION_FAILED -> PATCH_IN_PROGRESS` (while retries remain) and `VERIFICATION_IN_PROGRESS -> BLOCKED -> NOTIFIED_BLOCKED` (retries exhausted).
3. [x] Control operations: `start_run`, `get_run`, `retry_run`, `pause_workspace`, `list_specs`, `sync_specs`.
4. [x] Channel ingress contract for web and agent API.
5. [x] Actor role mapping: `echo`, `scout`, `warden`, and engine/system actor.
6. [x] Append-only run ledger + artifact indexing for replay.

## Out-of-scope
1. Multi-forge parity (GitLab/Bitbucket).
2. Multi-repo orchestration in one run.
3. Full billing implementation.
4. OpenClaw Gateway integration and natural-language chat/voice command routing.
5. Voice adapter / ElevenLabs integration.
6. Autonomous critical/destructive operations without confirmation gates.
7. Final UI visuals and brand copy.

## Interfaces and contracts
### 1) Run lifecycle contract
State invariants:
1. A run has exactly one active state at a time.
2. A transition is valid only if in the approved state graph.
3. Terminal states are immutable (`DONE`, `NOTIFIED_BLOCKED`) except metadata enrichments.
4. Every transition records `timestamp`, `actor`, `reason_code`, and `attempt`.

Transition policy:
1. `start_run` creates run in `SPEC_QUEUED` and enqueues planning.
2. `retry_run` is valid only from `VERIFICATION_FAILED` or `BLOCKED` with policy approval.
3. `pause_workspace` blocks new admissions only; in-flight runs continue unless separately cancelled.

### 2) Channel ingress contract
1. Web ingress: web UI calls control API directly.
2. Agent ingress: autonomous agent calls control API directly with machine credentials.
3. Chat/voice ingress is deferred in Sprint 1 and must not be implemented in this milestone.
4. Regardless of ingress channel, lifecycle transitions and policy checks execute only in control plane.

### 3) Actor and skill contract
1. `echo` (planner): generates `plan.json` from spec + repository context.
2. `scout` (builder): implements changes and writes `implementation.md`.
3. `warden` (validator): validates and writes `validation.md` + `attempt_N_defects.md` on failures.
4. Engine/system actor handles PR creation, notifications, and terminal-state progression.
5. `clawable` coordinator role is reserved for Phase 2+ chat/voice ingress and is not active in Sprint 1.

### 4) Control API contract (surface)
1. `start_run(spec_id, workspace_id, mode, requested_by)` returns `run_id`, `state`, and admission metadata.
2. `get_run(run_id)` returns current state, transitions pointer, artifacts index, and policy decisions.
3. `retry_run(run_id, reason)` increments `attempt` and re-enters `PATCH_IN_PROGRESS` when allowed.
4. `pause_workspace(workspace_id, pause=true|false, reason)` toggles workspace admission control.
5. `list_specs(workspace_id, status, cursor)` returns deterministic queue ordering.
6. `sync_specs(workspace_id)` scans `docs/spec/PENDING_*.md` in the workspace repo, upserts spec records into the control plane DB, and returns the count of new/updated specs. Called automatically before `start_run` if no specs exist, and can be called explicitly via API.

### 4a) Spec ingestion contract
1. Spec discovery: control plane clones/fetches the workspace repo and reads `docs/spec/PENDING_*.md` files.
2. Each file becomes a `specs` row with `spec_id` derived from filename, `sequence` from the numeric prefix, and `content_hash` for change detection.
3. Spec status is tracked in the `specs` table (`pending`, `in_progress`, `done`, `blocked`). Files in the repo are never renamed.
4. `sync_specs` is idempotent: re-scanning produces no duplicates if content is unchanged.
5. Sprint 1: `sync_specs` is called as part of `start_run` flow (lazy sync). Explicit `POST /v1/workspaces/{workspace_id}:sync` endpoint is also available.

### 5) Identity and idempotency contract
1. `start_run` requires `idempotency_key` per workspace; duplicates map to same `run_id`.
2. `retry_run` requires `retry_token` to prevent duplicate retry injection.
3. `pause_workspace` requires monotonic `version` to prevent stale overwrites.
4. All API requests include `request_id` correlation; retries must be safe under repeated delivery.

### 6) Storage and replay contract
1. `runs` stores canonical run metadata and current-state pointer.
2. `run_transitions` is append-only, ordered by per-run sequence.
3. Artifact index stores logical names and immutable object keys.
4. PR record stores forge IDs and artifact links.
5. Policy events are queryable in run timeline.

### 7) Canonical command path examples
1. Web: `button click -> start_run` directly to API.
2. Agent API: `agent client -> start_run/get_run/retry_run` directly to API.
3. Deferred (not Sprint 1): `chat/voice -> OpenClaw gateway -> control API`.

## Acceptance criteria
1. [x] All allowed lifecycle transitions are explicitly defined and enforced.
2. [x] Every run has complete transition history from `SPEC_QUEUED` to terminal state.
3. [x] Ingress path does not alter lifecycle semantics: same commands produce same state behavior.
4. [x] Web and agent API requests are deduplicated safely under transport retries.
5. [x] Retry budget exhaustion produces deterministic `BLOCKED` + `reason_code`.
6. [x] Replay can resolve artifacts + policy decisions + actor trail for each attempt.

### 8) Reason-code catalog (Sprint 1 minimum)
1. `PLAN_COMPLETE` — Echo finished planning.
2. `PATCH_STARTED` — Scout began implementation.
3. `PATCH_COMMITTED` — Scout committed changes to branch.
4. `VALIDATION_STARTED` — Warden began review.
5. `VALIDATION_PASSED` — Warden approved.
6. `VALIDATION_FAILED_TESTS` — Test failures detected.
7. `VALIDATION_FAILED_SPEC_MISMATCH` — Implementation doesn't match spec.
8. `VALIDATION_FAILED_SECURITY` — Security issue detected (e.g., leaked secrets).
9. `RETRIES_EXHAUSTED` — Max retry budget consumed.
10. `PR_CREATED` — GitHub PR opened.
11. `NOTIFICATION_SENT` — Operator notified.
12. `WORKSPACE_PAUSED` — Workspace admission paused by operator.
13. `IDEMPOTENT_HIT` — Duplicate request returned existing run.
14. `POLICY_DENIED` — Policy engine rejected the action.

## Risks and mitigations
1. Risk: channel-specific behavior drift (web vs agent API).
Mitigation: enforce one shared command schema and one control-plane state engine.
2. Risk: duplicate API delivery starts multiple runs.
Mitigation: idempotency keys + retry token enforcement + request correlation IDs.
3. Risk: confusion about deferred OpenClaw/chat/voice features.
Mitigation: explicitly mark chat/voice integration as Phase 2+ in Sprint 1 docs and prompts.
4. Risk: unclear operator audit trails.
Mitigation: require actor + reason code on all transitions and policy decisions.

## Test/verification commands
```bash
# Required section presence
rg -n "^## (Goal|Explicit assumptions|In-scope|Out-of-scope|Interfaces and contracts|Acceptance criteria|Risks and mitigations|Test/verification commands)$" docs/done/DONE1_001_CONTROL_PLANE_SPRINT1.md

# Lifecycle and API terms
rg -n "SPEC_QUEUED|RUN_PLANNED|PATCH_IN_PROGRESS|PATCH_READY|VERIFICATION_IN_PROGRESS|VERIFICATION_FAILED|PR_PREPARED|PR_OPENED|DONE|BLOCKED|start_run|get_run|retry_run|pause_workspace|list_specs" docs/done/DONE1_001_CONTROL_PLANE_SPRINT1.md

# Ingress and actor terms
rg -n "web|agent API|echo|scout|warden|deferred|OpenClaw" docs/done/DONE1_001_CONTROL_PLANE_SPRINT1.md
```
