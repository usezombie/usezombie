# M84_001: Harden the runner sandbox — clear env, CLOEXEC fds, absolute argv[0]

**Prototype:** v2.0.0
**Milestone:** M84
**Workstream:** 001
**Date:** Jun 03, 2026
**Status:** PENDING
**Priority:** P1 — security boundary. Closes a daemon-credential / file-descriptor exfiltration path open to an untrusted sandboxed agent. No customer-facing behaviour change; gates untrusted/local-runner GA.
**Categories:** API
**Batch:** B1 — standalone security hardening; no concurrent workstream.
**Branch:** {feat/m84-runner-sandbox-hardening — added at CHORE(open)}
**Depends on:** None hard. Sequenced **after** M82_001 (Zig 0.16 toolchain) lands — it edits the same `child_process.forkExec` / `process.spawn` path and `sandbox_args.appendBwrap`. Rebasing onto the post-0.16 `forkExec` avoids a conflict.
**Provenance:** agent-surfaced during the M82_001 `forkExec → process.spawn` CTO / threat-model review (Jun 03, 2026), then corroborated by an independent CTO review (ChatGPT). All three findings are **pre-existing** (the manual fork-exec path had them too) and confirmed by code reading, **not** introduced by M82 — M82 is behaviour-preserving and explicitly does not touch them (M82 Discovery, "Sandbox-hardening" entry, Indy-acked).

> **Provenance is load-bearing.** Findings come from reading `sandbox_args.zig` / `child_process.zig` / `child_exec.zig` under an adversarial lens, not from a vulnerability report. The exact env/fd surface must be re-confirmed at PLAN against the then-current `appendBwrap` and `forkExec`.

**Canonical architecture:** the host-resident `zombie-runner` execution plane (`docs/architecture/` runner-fleet docs). The sandbox model is bwrap (namespaces) + Landlock (in-child) + cgroup (kill domain); this workstream hardens the **process-boundary env/fd/process-group surface** that sits underneath those, not the namespace/LSM layers.

---

## Implementing agent — read these first

1. `docs/AUTH.md` — `ZOMBIE_RUNNER_TOKEN` is the daemon's control-plane credential; §1 exists because it can currently leak into the sandbox. Auth-boundary file — `/review` the env-allowlist change specifically.
2. `src/runner/sandbox_args.zig` — `appendBwrap` (the bwrap argv builder) and `bwrapPath`; §1 + §3 land here.
3. `src/runner/child_process.zig` — `forkExec` (now `std.process.spawn`), `killChild` (the `kill(-pgid)` fallback); §2 (fd hygiene) + §3 (argv[0]) + §4 (kill-tree) land here.
4. `src/runner/child_exec.zig` — the in-child `__execute` entry; documents the "secrets ride stdin, never argv/env" contract this workstream extends to the daemon's own token.
5. `docs/ZIG_RULES.md` — all `*.zig` edits.

---

## PR Intent & comprehension handshake

- **PR title (eventual):** `build(m84): harden runner sandbox — clear env, CLOEXEC fds, absolute argv[0]`
- **Intent (one sentence):** Ensure an untrusted sandboxed agent cannot read the daemon's environment (incl. `ZOMBIE_RUNNER_TOKEN`), cannot inherit a non-`CLOEXEC` daemon file descriptor, and cannot influence `argv[0]` resolution — and pin the `kill(-pgid)` fallback that reaps its whole process tree.
- **Handshake (agent fills at PLAN, before EXECUTE):** restate intent; list `ASSUMPTIONS I'M MAKING:`. Re-confirm the env passthrough allowlist (§1) against what the in-child engine + its tools legitimately need — a too-tight allowlist breaks tool execution; a too-loose one re-opens the leak.

---

## Applicable Rules

- **`docs/greptile-learnings/RULES.md`**:
  - **RULE UFS** — the env passthrough allowlist (var names), the daemon deny-list, and bwrap flag literals (`--clearenv`, `--setenv`) are single-sourced named constants, referenced from both `appendBwrap` and its tests — never re-spelled.
  - **RULE NLG** — pre-2.0: no "legacy"/"compat" framing for the hardened path; the unhardened behaviour is simply replaced, not shimmed.
  - **RULE NDC / NLR** — no dead code; if a finding turns out already-mitigated (e.g. Zig opens are CLOEXEC by default), record that in Discovery and downgrade that Dimension to an assertion rather than adding a no-op.
- **`docs/ZIG_RULES.md`** — all `*.zig` edits (tagged-union results, `errdefer`, cross-compile both linux targets).
- **`docs/AUTH.md`** — `ZOMBIE_RUNNER_TOKEN` handling; the env-allowlist change is auth-boundary and must not alter how the daemon *itself* reads or sends the token, only what the child inherits.
- **`docs/LOGGING_STANDARD.md`** — any new "env_cleared"/"fd_audit" emit follows the logfmt envelope; never log the token or a full environ dump.

## Applicable Gates

| Gate | Fires? | Satisfaction strategy |
|------|--------|-----------------------|
| ZIG GATE | **yes** — `*.zig` edits | Read `docs/ZIG_RULES.md`; cross-compile both linux targets before commit. |
| UFS | **yes** — allowlist + deny-list + bwrap flags | Named constants in `sandbox_args.zig`, reused in tests (`// pin test` only where the literal IS the bwrap contract). |
| LENGTH (≤350/≤50/≤70) | **yes** — `appendBwrap` grows | Extract the env-allowlist emit into a helper if `appendBwrap` nears the 50-line cap. |
| LOGGING | **maybe** — new audit emit | Envelope unchanged; never log secret values. |
| LIFECYCLE | **no** | No new heap/handle ownership; fd hygiene tightens flags, adds no resource. |
| SCHEMA / ERROR REGISTRY / UI / DESIGN TOKEN | **no** | No schema, no UI; argv[0] guard reuses an existing fail-closed error class. |

---

## Overview

**Goal (testable):** A token planted in the daemon's environment never appears in the sandboxed child's environment or argv; **no** non-`CLOEXEC` daemon file descriptor is inherited by the child; `forkExec` rejects a non-absolute `argv[0]` before `spawn`; and `kill(-pgid)` reaps a forking agent's whole descendant tree — each proven by a negative/regression test.

**Problem:** The host runner spawns an untrusted, prompt-injectable agent inside bwrap + Landlock + cgroup. Three pre-existing process-boundary leaks sit *underneath* that isolation: (1) bwrap inherits the daemon environment, exposing `ZOMBIE_RUNNER_TOKEN` (the control-plane credential) and `ZOMBIE_API_URL` to the agent; (2) non-`CLOEXEC` daemon file descriptors are inherited by the child; (3) `std.process.spawn` resolves a relative `argv[0]` via the parent `PATH`. None is introduced by M82 (behaviour-preserving) — all pre-exist in the manual fork-exec path.

**Solution summary:** Clear the child's environment at the bwrap boundary (`--clearenv`) and re-inject only an explicit allowlist (`--setenv`); audit and enforce `CLOEXEC` on **every** daemon-held descriptor so none is inherited; assert `argv[0]` absolute (fail-closed) before `spawn`; and pin the `kill(-pgid)` fallback that reaps a forking agent's whole tree. Behaviour for the legitimate sandboxed lease is unchanged — only the leak surface is removed. Scope is the **process boundary** (env/fd/argv/process-group), not the namespace/Landlock/cgroup-membership layers.

**Prioritization (CTO review, Jun 03, 2026).** These reduce *actual attack surface* and rank above the M82 spawn migration itself (which reduces maintenance surface): **(1)** environment sanitisation, **(2)** `CLOEXEC` audit of every daemon fd, **(3)** kill-tree fallback regression. The governing intuition: a sandbox is most often defeated by **inheriting an already-open capability across `exec`** — a socket, a connection, a control pipe — not by breaking kernel isolation. The fd/env surface matters more than the namespace layer, so §2 is the strongest finding here.

---

## Prior-Art / Reference Implementations

- **bwrap `--clearenv` + `--setenv`** is the canonical hardened-sandbox env pattern (Flatpak, `bubblewrap(1)`); the existing `appendBwrap` flag-emit style (`dup` each arg) is the in-repo pattern to extend.
- **CLOEXEC-by-default** — Zig `std.Io`/`std.fs` file opens set `O_CLOEXEC`; the workstream's job is to *prove* the daemon holds no non-CLOEXEC fd at spawn time, mirroring how `posix_spawn` users audit fd inheritance.
- **Sibling security follow-up** — the JWKS lock-across-fetch spec (also spun from M82) is the model for a focused, single-boundary security workstream with negative-test enforcement.

---

## Files Changed (blast radius)

| File | Action | Why |
|------|--------|-----|
| `src/runner/sandbox_args.zig` | EDIT | `appendBwrap`: emit `--clearenv` + `--setenv <allowlist>`; add the allowlist + deny-list constants (§1). |
| `src/runner/child_process.zig` | EDIT | `forkExec`: assert `argv[0]` absolute before `spawn` (§3); fd-hygiene audit/guard (§2); kill-tree fallback test target (§4). |
| `src/runner/sandbox_args_edge_test.zig` (+ a sibling `*_test.zig` as needed) | EDIT/CREATE | Negative tests: planted token absent from argv/env; non-allowlisted vars stripped; stray-fd sweep; relative `argv[0]` rejected; pgroup-kill reaps the tree. |
| `docs/AUTH.md` | EDIT (small) | Note that the runner token is `--clearenv`-isolated from the sandboxed child. |

---

## Decomposition & alternatives (patch vs refactor)

- **Chosen shape:** one atomic workstream (B1), four independent Sections (env / fd / argv[0] / kill-tree) that share the spawn path but have separate tests. It is a **patch** (additive hardening, behaviour-preserving for the legitimate path) — no new abstraction.
- **Alternatives considered:** (a) **Pass a filtered `Environ.Map` to `process.spawn` instead of bwrap `--clearenv`** — viable for the `dev_none` (no-bwrap) tier where there is no bwrap to clear env, but for sandboxed tiers `--clearenv` is the defence-in-depth layer that also covers a future direct-exec path; doing the dev_none spawn `environ_map` is **out of scope** — that tier is trusted-dev, no-isolation by definition. (b) **Drop env entirely** — rejected: the in-child engine legitimately reads `NULLCLAW_OBSERVER` and tools need `PATH`/`HOME`/`TMPDIR`; a strict allowlist is required, not a blanket drop.

---

## Sections (implementation slices)

### §1 — Environment isolation for the sandboxed child

bwrap currently inherits the daemon environment, so a prompt-injected agent can read `ZOMBIE_RUNNER_TOKEN` (and `ZOMBIE_API_URL`) from its process environment and exfiltrate the daemon's control-plane credential. Clear the environment at the bwrap boundary and pass through only an explicit allowlist — **fail closed**: clear first, re-add only what is named.

- **Dimension 1.1** — `appendBwrap` emits `--clearenv` ahead of the command on sandboxed tiers → Test `test_bwrap_argv_clears_env`
- **Dimension 1.2** — only the allowlist (`NULLCLAW_OBSERVER`, `PATH`, `HOME`, `TMPDIR`, `LANG` — finalised at PLAN against tool needs) is re-injected via `--setenv`; the daemon deny-list (`ZOMBIE_RUNNER_TOKEN`, `ZOMBIE_API_URL`, any `ZOMBIE_*`) never appears in argv regardless of allowlist contents → Test `test_bwrap_argv_omits_daemon_secrets`
- **Dimension 1.3** — a token planted in the daemon environment does not reach the child's environment (probe child dumps `/proc/self/environ`) → Test `test_planted_token_absent_from_child_env`

### §2 — File-descriptor hygiene (strongest finding)

`process.spawn` wires the configured stdio but does **not** close arbitrary parent fds; any non-`CLOEXEC` descriptor the daemon holds is inherited by the sandboxed child. This is the highest-leverage finding: a sandbox is most often defeated not by breaking kernel isolation but by **inheriting an already-open capability across `exec`** — a unix socket, a database connection, a control pipe, a cgroup fd, an eventfd. A single leaked descriptor is a compromise with no namespace escape required.

The invariant is absolute: **every** daemon fd is `CLOEXEC` — not most, all. Audit each open site (cgroup control files, the control-plane `http.Client`, lease pipes, log sinks) and enforce `CLOEXEC` at open; back it with a runtime sweep that no unexpected fd ≥ 3 survives into the child.

- **Dimension 2.1** — every daemon open site sets `CLOEXEC`; the audit enumerates them in Discovery (any already-CLOEXEC-by-default site downgrades to an assertion, RULE NDC) → Test `test_daemon_fds_are_cloexec`
- **Dimension 2.2** — a marker capability fd opened by the daemon is **not** accessible in the spawned child (`fcntl(N, F_GETFD)` → `EBADF`) → Test `test_marker_fd_not_inherited_by_child`
- **Dimension 2.3** — the spawned child sees no unexpected open fd ≥ 3 beyond its wired stdio (defence-in-depth sweep) → Test `test_no_stray_fds_in_child`
- **Dimension 2.4** — `forkExec` leaves `process.spawn`'s `progress_node = .none`, so std's `prog_fileno = 3` path never `dup2`s a fourth fd across `exec` (Zig 0.16 `Threaded.zig` advertises fd 3 + `ZIG_PROGRESS` *only* when a progress node is set; the runner sets none today, so no leak — but it is a contingent guarantee, not structural). The Dim 2.3 sweep asserts fd 3 absent explicitly; if live progress streaming is ever wired into the runner spawn, fd-inheritance is re-reviewed here. → Test `test_no_stray_fds_in_child` (fd-3 case) + a `progress_node == .none` assertion at the `forkExec` call site

### §3 — `argv[0]` absolute guard

`std.process.spawn` resolves a relative `argv[0]` against the **parent** `PATH`; an absolute `argv[0]` is the invariant that closes any PATH-influence vector (a future refactor changing `"/usr/bin/bwrap"` to `"bwrap"` must not silently create a `PATH` trust dependency). `buildArgv` already produces absolute paths (bwrap path / `executablePathAlloc`); make the invariant explicit and fail-closed.

- **Dimension 3.1** — `forkExec` rejects a non-absolute `argv[0]` before `spawn` (fail-closed, reusing the sandbox-setup failure class) → Test `test_relative_argv0_rejected`

### §4 — Containment kill-tree fallback (regression)

The cgroup is the primary, atomic kill domain, but `kill(-pgid, SIGKILL)` is the fallback when cgroup v2 is unavailable (older kernel) or `cgroup.kill` fails, and is the *only* kill on the `dev_none`/macOS path. `process.spawn(.pgid = 0)` (M82) must yield a process group whose group-kill reaps the **entire** tree — a forking agent must not survive via a grandchild. This regression pins the safety story the spawn migration relies on (the `.pgid = 0` → `setpgid(0,0)` equivalence is confirmed in the M82 review; here we test the *effect*).

- **Dimension 4.1** — `kill(-child_pid, SIGKILL)` reaps a child that forked a grandchild and great-grandchild (all in the child's group), with no escapee left running → Test `test_pgroup_kill_reaps_descendant_tree`
- **Dimension 4.2** — cgroup enrollment must not silently disable the kill domain. `child_supervisor.zig` currently does `scope.addProcess(child.id.?) catch log.warn(...)` (**non-fatal**): if enrollment fails, the child runs *outside* the cgroup, `scope.kill()` then writes `cgroup.kill = 1` to an **empty** cgroup — which *succeeds* — and the `kill(-pid)` fallback (which fires only on a cgroup **write error**, never on an empty-cgroup success) never triggers, so a forking child's tree survives a revocation/timeout kill. Pre-existing, not migration-induced; fs isolation still holds (bwrap + Landlock), so this is a kill-domain/containment degradation, not an fs escape. **Decision (PLAN):** either fail-closed (refuse the lease on `addProcess` failure) *or* make `killChild` *always* also signal the process group (belt-and-suspenders), so the kill domain can never be silently empty. → Test `test_kill_survives_cgroup_enrollment_failure`

### §5 — Sandbox containment verification (defense-in-depth — covers ChatGPT findings #2 network, #4 filesystem)

These assert the *existing* network-namespace + bwrap-mount + Landlock isolation actually contains a prompt-injected agent end-to-end. The **mechanisms** are owned by the M80 runner-fleet specs (namespaces, mounts, Landlock) and the network-policy roadmap (nftables egress); **M84 owns the acceptance proof** that containment holds, so a future change cannot silently regress it. These are characterization/regression tests — they **pass at M84 start** (the isolation already exists, confirmed by the Jun 03 CTO review) and must stay green. They close the gap that ChatGPT ranked #2 (network) and #4 (filesystem) had no test.

- **Dimension 5.1** — network egress (ChatGPT #2). On a sandboxed tier under the default `deny_all` policy, the child cannot reach the network: a `connect()` to an external host fails at the kernel — `--unshare-all` (`sandbox_args.zig:79`) gives an empty network namespace with no route. → Test `test_sandboxed_child_network_denied`
  - **Known gap, pinned not closed here:** under the `registry_allowlist` opt-in, `--share-net` re-joins the host netns and the allowlist is **log-only** (`runner_network_policy.zig:5-9`) — no kernel egress restriction today. A characterization test pins this *current* behaviour so the network-policy roadmap (nftables) closes it knowingly and the assertion flips when it lands. → Test `test_registry_allowlist_egress_unrestricted_today`
- **Dimension 5.2** — filesystem exposure (ChatGPT #4). The sandboxed child cannot read host `/home` / `/var` / `/root` (never bound) and cannot write `/etc` (RO bind); only the lease workspace and the `/tmp` tmpfs are writable. → Test `test_sandboxed_child_fs_isolation` (child probe: write `/etc/<x>` → denied; open `/home` → absent/empty; write workspace → ok)

---

## Interfaces

```
# src/runner/sandbox_args.zig — new single-sourced constants (RULE UFS)
const CLEARENV_FLAG = "--clearenv";
const SETENV_FLAG   = "--setenv";
const ENV_PASSTHROUGH_ALLOWLIST = [_][]const u8{ "NULLCLAW_OBSERVER", "PATH", "HOME", "TMPDIR", "LANG" }; // finalise at PLAN
const ENV_DENY_PREFIX = "ZOMBIE_"; // asserted absent from child argv/env regardless of allowlist

# src/runner/child_process.zig — fail-closed guard before spawn
if (!std.fs.path.isAbsolute(argv[0])) return error.SandboxArgvNotAbsolute;
```

Contract: the legitimate execution path (allowlisted env present, absolute `argv[0]`) is byte-for-byte unchanged in observable behaviour; only the leak surface is removed.

---

## Failure Modes

| Mode | Cause | Handling (system response + what the caller observes) |
|------|-------|--------------------------------------------------------|
| Allowlist too tight | a var the engine/tools need is omitted | tool execution fails inside the sandbox; caught by an integration smoke test that runs a tool needing `PATH`; allowlist widened deliberately |
| Allowlist too loose | a secret-bearing var slips into the allowlist | `test_bwrap_argv_omits_daemon_secrets` asserts the `ZOMBIE_*` deny-prefix is absent regardless of allowlist contents |
| `--clearenv` on a non-bwrap tier | applied where there is no bwrap (`dev_none`) | §1 is gated on `sandboxed`; `dev_none` path unchanged (out of scope, trusted-dev) |
| Stray capability fd inherited | a daemon open site forgets `CLOEXEC` | `test_marker_fd_not_inherited_by_child` + `test_no_stray_fds_in_child` fail the build before merge |
| Relative `argv[0]` reaches spawn | a future `buildArgv` change emits a relative path | `test_relative_argv0_rejected` + the runtime guard fail-close the lease |
| Group-kill misses a descendant | child re-parents / breaks its own pgroup | `test_pgroup_kill_reaps_descendant_tree` fails; cgroup tree-kill remains the primary domain regardless |

---

## Invariants

1. **No daemon secret in the child environment** — `ZOMBIE_*` (incl. `ZOMBIE_RUNNER_TOKEN` / `ZOMBIE_API_URL`) never appears in the child's environ or argv. Enforced by `test_bwrap_argv_omits_daemon_secrets` + `test_planted_token_absent_from_child_env` (negative tests), not review.
2. **Every daemon fd is `CLOEXEC`** — *all*, not most; no unexpected fd ≥ 3 reaches the child. Enforced by `test_daemon_fds_are_cloexec` + `test_marker_fd_not_inherited_by_child` + `test_no_stray_fds_in_child`. Spawn's `progress_node` stays `.none` so std's `prog_fileno = 3` path never crosses `exec` (Dim 2.4).
3. **`argv[0]` is always absolute** — enforced by the runtime guard + `test_relative_argv0_rejected`.
4. **Group-kill reaps the whole tree** — `kill(-pgid)` leaves no descendant running. Enforced by `test_pgroup_kill_reaps_descendant_tree` (the cgroup-independent safety path). cgroup-enrollment failure cannot silently empty the kill domain (Dim 4.2).
5. **Legitimate path unchanged** — the allowlisted env + absolute argv[0] case produces an identical bwrap argv shape (minus the new flags); a golden-argv test pins it.
6. **Single-owner reap (spawn-migration handle-ownership contract)** — the supervisor is the **sole** reaper of the child: exactly one `wait()`, guarded by the `reaped` flag. The `process.Child` wrapper returned by `std.process.spawn` is **non-authoritative** — `child.wait()` is never called outside the supervisor's reap path (double-reap hazard), and `child.kill()` is never called (containment is cgroup-atomic via `killChild`). The supervisor owns the extracted stdio fds, the `waitpid`, and all cleanup. Surfaced by the ChatGPT CTO review ("a future maintainer will fix things by calling `child.wait()` and create double-reaping bugs"); enforced as a code comment at the reap site in `child_supervisor.zig` and pinned here. No new test — the spawn-mechanics tests (bad-`argv[0]` → synchronous `SpawnError`; stdin-EOF → completion) live in **M82_001 Batch 6**.

---

## Test Specification (tiered)

| Dimension | Tier | Test | Asserts (concrete inputs → expected output) |
|-----------|------|------|---------------------------------------------|
| 1.1 | unit | `test_bwrap_argv_clears_env` | sandboxed `buildArgv` output contains `--clearenv` before `--` |
| 1.2 | unit | `test_bwrap_argv_omits_daemon_secrets` | argv contains no `ZOMBIE_*` var; contains `--setenv NULLCLAW_OBSERVER` when set |
| 1.3 | integration | `test_planted_token_absent_from_child_env` | daemon env has `ZOMBIE_RUNNER_TOKEN=probe`; spawned child's `/proc/self/environ` lacks `probe` |
| 2.1 | unit | `test_daemon_fds_are_cloexec` | each audited daemon open returns an fd with `FD_CLOEXEC` set |
| 2.2 | integration | `test_marker_fd_not_inherited_by_child` | daemon opens a marker fd N; child `fcntl(N, F_GETFD)` → `EBADF` |
| 2.3 | integration | `test_no_stray_fds_in_child` | spawned child enumerates `/proc/self/fd`; only wired stdio (0/1/2) present |
| 2.4 | integration | `test_no_stray_fds_in_child` (fd-3 case) | child `/proc/self/fd` has no fd 3; `forkExec` asserts `progress_node == .none` |
| 3.1 | unit | `test_relative_argv0_rejected` | `forkExec` with a relative `argv[0]` → `error.SandboxArgvNotAbsolute`, no spawn |
| 4.1 | integration | `test_pgroup_kill_reaps_descendant_tree` | child forks grandchild+great-grandchild; `kill(-pid, SIGKILL)` → all reaped, none survive |
| 4.2 | integration | `test_kill_survives_cgroup_enrollment_failure` | inject `addProcess` failure → child runs but a revocation kill still reaps its whole tree (kill domain never silently empty) |
| 5.1 | integration | `test_sandboxed_child_network_denied` | sandboxed child under `deny_all` → `connect()`/curl to an external host fails at the kernel (empty netns) |
| 5.1-gap | integration | `test_registry_allowlist_egress_unrestricted_today` | `registry_allowlist` tier → child reaches an external host (pins the current no-kernel-egress gap; flips when nftables lands) |
| 5.2 | integration | `test_sandboxed_child_fs_isolation` | child: write `/etc/<x>` → denied (RO); `/home`/`/var`/`/root` absent; write lease workspace → ok |

- **Regression:** the existing runner execution suite (`make test` / `test-integration`) must pass unchanged — the legitimate sandboxed lease still runs end-to-end.
- **Idempotency/replay:** N/A.

---

## Acceptance Criteria

- [ ] `--clearenv` present on sandboxed bwrap argv; `ZOMBIE_*` absent — verify: `test_bwrap_argv_clears_env` + `test_bwrap_argv_omits_daemon_secrets`
- [ ] Planted-token integration test green — verify: `make test-integration` (`test_planted_token_absent_from_child_env`)
- [ ] No non-CLOEXEC / stray fd inherited — verify: `test_marker_fd_not_inherited_by_child` + `test_no_stray_fds_in_child`
- [ ] Relative `argv[0]` rejected fail-closed — verify: `test_relative_argv0_rejected`
- [ ] `kill(-pgid)` reaps the descendant tree — verify: `test_pgroup_kill_reaps_descendant_tree`
- [ ] No fd 3 crosses `exec` (progress-fd path stays disabled) — verify: `test_no_stray_fds_in_child` (fd-3 case)
- [ ] cgroup-enrollment failure cannot silently empty the kill domain — verify: `test_kill_survives_cgroup_enrollment_failure`
- [ ] Sandboxed child cannot reach the network under `deny_all` (ChatGPT #2) — verify: `test_sandboxed_child_network_denied`; `registry_allowlist` egress gap pinned — `test_registry_allowlist_egress_unrestricted_today`
- [ ] Sandboxed child cannot read host `/home`/`/var` or write `/etc` (ChatGPT #4) — verify: `test_sandboxed_child_fs_isolation`
- [ ] `make lint` clean · `make test` passes · cross-compile both linux targets
- [ ] `gitleaks detect` clean · no file over 350 lines added
- [ ] `docs/AUTH.md` notes the token is `--clearenv`-isolated from the sandbox

---

## Eval Commands (post-implementation)

```bash
# E1: clearenv present, secrets absent
zig build --build-file build_runner.zig test 2>&1 | grep -E "bwrap_argv_clears_env|omits_daemon_secrets"
# E2: full runner suite (legitimate path unchanged)
make test 2>&1 | tail -5
# E3: integration (planted token + marker/stray fd + kill-tree)
make test-integration 2>&1 | tail -5
# E4: no daemon secret literal leaked into argv builder
git grep -n 'ZOMBIE_RUNNER_TOKEN' src/runner/sandbox_args.zig | head
```

---

## Dead Code Sweep

**1. Orphaned files — none expected.**

| File to delete | Verify |
|----------------|--------|
| N/A — additive hardening | — |

**2. Orphaned references.**

| Deleted symbol/import | Grep | Expected |
|-----------------------|------|----------|
| N/A | — | — |

---

## Discovery (consult log)

> **Empty at creation.** Append as work surfaces consults and decisions.

- **Origin (Jun 03, 2026):** surfaced in the M82_001 `forkExec → process.spawn` CTO/threat-model walkthrough. Three pre-existing findings (env inheritance → token exfil; non-CLOEXEC fd inheritance; relative-`argv[0]` PATH resolution). M82 is behaviour-preserving and does not change them.
  - **Indy go (verbatim, Jun 03, 2026):** _"ensure the sandbox-hardening followup is done (separate spec)"_ — context: file the three findings as their own security spec, not folded into the toolchain bump.
- **CTO review — ChatGPT (Jun 03, 2026):** independent review concurred with the architecture (spawn for creation, cgroup as the authoritative kill boundary, raw-fd supervisor preserved) and **ranked the hardening above the migration** — "the hardening findings are more significant than the fork-to-spawn change." Folded in: (1) env allowlist widened to `PATH`/`HOME`/`TMPDIR`/`LANG` + fail-closed deny-prefix; (2) FD hygiene reframed as the *strongest* finding — "most sandbox escapes steal an already-open capability (socket / connection / control pipe / cgroup fd / eventfd), not break kernel isolation" → invariant is **ALL** daemon fds CLOEXEC, plus a stray-fd sweep (Dim 2.3); (3) added §4 — a kill-tree regression proving the `kill(-pgid)` fallback reaps grandchildren. Two migration-*mechanics* tests it raised — `spawn` returns an error (not pid+127) on a bad `argv[0]`, and stdin-EOF still drives child completion — belong to **M82_001 VERIFY (Batch 6)**, recorded in that spec's Discovery.
- **CTO adversarial review — Orly (Jun 03, 2026, code-grounded multi-agent):** a 13-agent workflow audited each finding against the live runner source, then an independent skeptic refuted each. Post-refutation verdicts, ranked for *this* codebase (not ChatGPT's generic order):
  1. **Env inheritance (§1) — EXPOSED, confirmed P0.** `forkExec` (`child_process.zig:32`) passes no `.environ_map` to `std.process.spawn`, so the child inherits the daemon block incl. `ZOMBIE_RUNNER_TOKEN` (`config.zig:47`); no `--clearenv` in `appendBwrap`. *Skeptic's refinement:* NullClaw's `ShellTool` already rebuilds a fresh `EnvMap` from a `SAFE_ENV_VARS` allowlist, so a bare `printenv` in the agent is clean — but `cat /proc/$PPID/environ` (the `__execute` pid) from the shell tool reaches the inherited block, and the **default `dev_none` tier has no bwrap/Landlock/proc-scoping at all**. Leak stands; §1 is the right fix.
  2. **FD/CLOEXEC (§2) — MITIGATED (proof, not fix).** `std.process.spawn` makes every pipe `pipe2(CLOEXEC)`; only fd 0/1/2 cross via `dup2`; no daemon-held socket/sqlite/cgroup fd is open at fork time (per-call `http.Client` deinit; sequential reap-before-next-fork loop). So §2's work is invariant-proof + regression, not a live patch (RULE NDC — record in Dim 2.1). **New caveat → Dim 2.4.**
  3. **argv[0] (§3) — `buildArgv` already absolute;** §3 is a fail-closed guard pinning the invariant.
  4. **Kill-tree (§4) — cgroup-atomic kill confirmed; `pgid=0` benign** (ChatGPT's read confirmed). **New caveat → Dim 4.2.**
  - **Out-of-M84 vectors (recorded for completeness):** *Network* — netns isolation works by default (`--unshare-all` + fail-closed `deny_all`, `network.zig:38`); the only gap is the `registry_allowlist` opt-in, which re-shares host net with a **log-only** allowlist (`runner_network_policy.zig:5-9`) — owned by the network-policy roadmap (see Out of Scope; **no spec ID filed yet — orphaned, needs filing**). The audit's "macOS exposed" claim was **refuted** — `establishSandbox` (`child_supervisor.zig`) fail-closes any non-Linux host *before* fork. *Filesystem* — two layers (bwrap RO-system + RW-workspace-only, `/home /var /root` never bound; in-child Landlock), MITIGATED.
  - **CSPRNG (cross-spec — M82, not M84):** Zig 0.16 removed `std.crypto.random` on linux. Replacement = **Option A** (getrandom over the OS CSPRNG, `std.Random` adapter for the int/range sites, fail-closed on short read) — chosen for **fork-safety** (no inheritable userspace keystream → no DEK/GCM-nonce reuse across the daemon's fork; Option B `DefaultCsprng` and the nullclaw `std_compat` shim both carry that fork-unsafe state and the shim trips RULE NLG). Lands in **M82_001 Batch 3** and must cover **every** `std.crypto.random.*` site — the adversarial pass caught that the catastrophic set is not just the DEK + 2 GCM nonces but also the bearer-credential generators `api_keys/agent.zig:35`, `api_keys/tenant.zig:58`, `runner/register.zig:36`, `notifications/grant_notifier.zig:28`.
- **Remaining security gaps (Jun 03, 2026 — for the implementing agent, beyond the four Sections + §5):**
  1. **`macos_seatbelt` is an unimplemented placeholder** — no `sandbox-exec`/seatbelt profile exists in `src/` (grep empty); the tier is currently fail-closed (`establishSandbox` refuses any non-Linux host for a non-`dev_none` tier, `child_supervisor.zig:199`). **DEFERRED — Indy (Jun 03, 2026): _"I deferred this, since seatbelt is deprecated long back"_** — Apple deprecated the Seatbelt `sandbox_init` / `sandbox-exec` API years ago, so implementing this tier is not worth it. **macOS isolation story:** `dev_none` for trusted local/personal use (no isolation, by design); for untrusted agents on a Mac, run inside a **Linux VM/container** (Apple `Virtualization.framework`, the macOS `container` CLI, or Lima/Colima/OrbStack) where the real `landlock_full` / `container_nested` tiers apply in the Linux guest — macOS hosts, the Linux guest is the execution plane. Still cheap and worth keeping: a test pinning *"macOS + non-`dev_none` → lease refused"* so a self-reported tier can never imply isolation that does not exist.
  2. **No explicit `--cap-drop ALL`** — `appendBwrap` relies on `--unshare-all`'s user namespace (`sandbox_args.zig:79`) to contain Linux capabilities namespace-locally; there is no explicit `--cap-drop ALL`. The user-ns is the primary container, but an explicit cap-drop is cheap defense-in-depth — fold into §1's `appendBwrap` edit + assert the child has no host-effective caps.
  3. **No `--new-session`** — bwrap is not invoked with `--new-session`, so the child shares the controlling terminal's session (TIOCSTI terminal-injection vector *if* a tty is attached). Niche for a systemd-spawned daemon child (no controlling tty), but add it as belt-and-suspenders alongside the §1 `appendBwrap` flags.
  4. **Network nftables egress** + the orphaned roadmap spec are already noted under §5.1 / Out of Scope (no spec ID filed — needs filing).
- **PLAN decisions to bank** — the final env passthrough allowlist (does the in-child engine/tools need more than the five named?); whether §2.1 is a real fix or proof-only (if all Zig opens are already CLOEXEC, downgrade to an assertion per RULE NDC).
- **Consults** — {Architecture / Legacy-Design / gate-flag triage: question + Indy's decision, as they arise.}
- **Skill chain outcomes** — {`/write-unit-test`, `/review`, `/review-pr` results.}
- **Deferrals** — every "deferred to follow-up" needs an Indy-acked verbatim quote here.

## Skill-Driven Review Chain (mandatory)

| When | Skill | What it does | Required output |
|------|-------|--------------|-----------------|
| After implementation, before CHORE(close) | `/write-unit-test` | Audits the negative/regression-test coverage vs this Test Specification (the four invariants). | Clean. Iteration count + coverage in Discovery. |
| After tests pass, before CHORE(close) | `/review` | Adversarial diff review vs `docs/AUTH.md`, `docs/ZIG_RULES.md`, Failure Modes, Invariants (esp. deny-list completeness + the fd audit). | Clean OR every finding dispositioned. |
| After `gh pr create` | `/review-pr` | Review-comments the open PR against the immutable diff. | Comments addressed before human review/merge. |

## Verification Evidence

| Check | Command | Result | Pass? |
|-------|---------|--------|-------|
| Unit tests | `make test` | {paste snippet} | |
| Integration (token + fd + kill-tree) | `make test-integration` | {paste snippet} | |
| Lint | `make lint` | {paste snippet} | |
| Cross-compile (Zig) | `zig build -Dtarget=x86_64-linux && zig build -Dtarget=aarch64-linux` | {paste snippet} | |
| Gitleaks | `gitleaks detect` | {paste snippet} | |

---

## Out of Scope

- **`dev_none` tier env filtering** — that tier runs with no isolation by design (trusted dev); `--clearenv` applies only to sandboxed tiers. Filtering dev_none env via spawn `environ_map` is a future consideration, not this workstream.
- **Namespace / Landlock / cgroup-membership model changes** — this workstream hardens only the process-boundary env/fd/process-group surface; the bwrap namespace set, the in-child Landlock policy, and the cgroup kill domain are unchanged (owned by the M80 runner-fleet specs). **§5 adds end-to-end containment *verification* of these layers (network + fs) as M84 acceptance — proof only, no mechanism change.**
- **Network egress allowlist (nftables)** — tracked separately in the runner network-policy roadmap (**no spec ID filed yet — needs filing**); `--share-net` semantics are untouched here. §5.1 *verifies* the `deny_all` default blocks egress and *characterizes* the `registry_allowlist` gap; it does not implement nftables.
- **Rotating / scoping the runner token** so a leak is lower-impact — a control-plane credential-model change, not a runner-side patch.
