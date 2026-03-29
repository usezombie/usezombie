# Security model

## Overview

UseZombie's security model is built on two principles: **fail-closed execution** and **separate runtime boundaries**. If the system cannot verify that a security prerequisite is met, it refuses to proceed.

## Runtime boundaries

The worker and executor are separate security boundaries, each with a distinct trust level and responsibility.

### Worker boundary

The worker is a **trusted** component. It handles:

- Orchestration — claiming runs, managing lifecycle state.
- Credential management — signing GitHub App JWTs, passing API keys via RPC payload.
- Billing enforcement — checking workspace credits before starting a run.
- PR creation — pushing branches and opening pull requests on behalf of the user.

The worker has access to all credentials and can make authenticated requests to GitHub, PostgreSQL, and Redis.

### Executor boundary

The executor is an **untrusted** boundary. It handles:

- Agent code execution — running the NullClaw agent runtime.
- Sandbox policy enforcement — Landlock, cgroups, network deny.
- Resource metering — tracking memory, CPU, and token usage.

The executor does **not** have access to credentials in its environment. The Anthropic API key is passed inside the `startStage` RPC payload and used only for agent API calls. The executor cannot reach the database, Redis, or GitHub directly.

## Fail-closed behavior

If any sandbox prerequisite is missing at startup, the executor refuses to start:

- Landlock not supported by the kernel: executor exits with `UZ-SANDBOX-001`.
- cgroups v2 not available: executor exits with `UZ-SANDBOX-001`.
- Unix socket path not writable: executor exits with a diagnostic error.

There is no degraded mode in production. Either the full sandbox is enforced, or the executor does not run.

## Lease-based liveness

Each run has a lease — a bounded time window during which the worker holds exclusive ownership. If the worker crashes or becomes unresponsive, the lease eventually expires, and the reconciler marks the run as failed (`UZ-EXEC-014`).

Leases prevent zombie runs from consuming resources indefinitely. They also prevent two workers from accidentally working on the same run.

<Warning>
UseZombie v1 is **not mid-session durable**. If a worker crashes during a run, the partial work is lost. The run is marked as failed, and the user must retry. Mid-session checkpointing is planned for v2.
</Warning>

## Spec injection threat model

Specs are user-authored markdown that the agent interprets. The attack surface is an adversarial spec that tries to escape the sandbox or exfiltrate data.

### Defenses in v1

| Layer | Defense |
|-------|---------|
| Spec validation | Server-side validation rejects specs that reference files outside the repository root. Path traversal patterns (`../`, absolute paths) are blocked. |
| Gate loop | Compilation failures from injected code are caught by `make lint`, `make test`, `make build`. The gate loop treats any failure as a signal to self-repair, not to proceed. |
| Sandbox | Even if the agent writes malicious code, the sandbox prevents filesystem escape, network exfiltration, and privilege escalation. |
| Human review | All PRs in v1 require human review before merge. The agent cannot merge its own work. |

### Planned for v2

| Layer | Defense |
|-------|---------|
| Static analysis gates | Semgrep rules and gitleaks scanning on every PR before it is opened. |
| Diff audit | Automated review of the diff for suspicious patterns (credential access, network calls, obfuscation). |
| Sandbox hardening | Firecracker VM isolation replacing Landlock+cgroups for stronger boundary enforcement. |

## Credential injection model

Agent execution requires three credential types, each with distinct injection paths:

### Anthropic API key

- Stored in 1Password vault (`op://ZMB_CD_DEV/anthropic-dev/credential`).
- Deployed to worker via `.env` at deploy time.
- Passed to executor via `StartStage` RPC payload `agent_config.api_key` field.
- Never exposed as executor process environment variable.
- Worker halts startup if absent (`UZ-CRED-001`).

### GitHub App installation token

- Worker signs JWT using GitHub App private key (already in vault).
- Requests short-lived installation token per-run, scoped to target repo.
- Token TTL: 1 hour (GitHub default), refreshed if run approaches 55-minute mark.
- Held in memory only, never persisted to database.
- Token request failure classifies as `policy_deny` (`UZ-CRED-002`).

### Package registry network allowlist

- Phase 1: executor network policy extended from `deny_all` to allowlist for known registries (npmjs.org, pypi.org, crates.io, pkg.go.dev).
- Phase 2: internal package mirror replaces allowlist for supply chain security.
- Controlled by `EXECUTOR_NETWORK_POLICY` env var; default: `deny_all`.

## Credential detection signals

| Signal | Meaning |
|--------|---------|
| `UZ-CRED-001` | Anthropic API key missing at worker startup |
| `UZ-CRED-002` | GitHub App installation token request failed |

## RBAC boundary

UseZombie treats role as part of the authenticated identity contract:

- `user` can access normal workspace operations.
- `operator` can manage harnesses, skill secrets, agent scoring views, and workspace scoring configuration.
- `admin` can perform billing lifecycle mutations and API-key-backed administrative operations.

Enforcement is server-side. Hidden CLI commands are not treated as a security boundary. The contract is pinned by live HTTP integration tests that prove `harness`, `skill-secret`, and admin billing-event routes reject under-scoped JWTs with `INSUFFICIENT_ROLE`.

## Free plan billing boundary

The free-plan credit model is fail-closed:

1. Before admitting run, sync, or operator harness execution, the server reconciles workspace billing state and checks remaining free credit.
2. If credit is exhausted, the request is rejected before execution starts with `UZ-BILLING-005`.
3. Runtime usage is deducted only when a run reaches a completed billable outcome.
4. Failed, interrupted, or otherwise incomplete runs do not consume free credit.

This avoids hidden overdraft paths and brittle mid-run termination policies.
