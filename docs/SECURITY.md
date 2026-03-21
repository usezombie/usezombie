# Security Posture & Cryptographic Risk Assessment

**Date:** Mar 21, 2026
**Status:** Living document — update on infrastructure or algorithm changes

---

## Cryptographic Inventory

| Asset | Algorithm | Lifespan | Quantum Risk | Notes |
|-------|-----------|----------|-------------|-------|
| Envelope KEK | AES-256-GCM | Long-lived (vault) | **Safe** — Grover's gives 128-bit security, infeasible | Versioned rotation supported (KEK_VERSION 1→2) |
| Per-secret DEK | AES-256-GCM | Per-secret | **Safe** | Random per encrypt, wrapped by KEK |
| Clerk JWTs | ES256 (ECDSA P-256) | 60 seconds | **None** — expires before attack completes | OIDC abstraction decouples from Clerk's signing algorithm |
| TLS key exchange | X25519Kyber768 | Per-session | **Protected** — Cloudflare ships PQC hybrid | Only applies to Cloudflare Tunnel path |
| TLS certificates | ECDSA P-256 | 90 days (Let's Encrypt) | **Low** — rotates frequently | Certificate forgery requires breaking key within 90d window |
| SSH worker keys | Ed25519 | Indefinite | **Real risk** — harvest now, decrypt later | Long-lived, no rotation policy, classically signed |
| Tailscale WireGuard | Curve25519 | Per-session | **Low** — ephemeral keys, rotated per handshake | sntrup761 PQC hybrid available in newer versions |
| GitHub App PEM | RSA 2048 | Long-lived | **Medium** — long-lived RSA key, breakable by Shor's | Rotate annually; GitHub doesn't offer PQC keys yet |

---

## Post-Quantum Risk: SSH Worker Keys

**Severity:** Medium (future risk, not exploitable today)
**Timeline:** Cryptographically relevant quantum computers (CRQC) estimated 2035–2040

### Threat Model

1. Attacker records Tailscale SSH traffic today
2. Stores encrypted sessions
3. In 2035+, runs Shor's algorithm on captured Ed25519 public key (~8 hours on ~20M physical qubits)
4. Derives private key, decrypts all stored sessions

### Affected Assets

- `op://ZMB_CD_PROD/zombie-prod-worker-ant/ssh-private-key` (Ed25519)
- `op://ZMB_CD_PROD/zombie-prod-worker-bird/ssh-private-key` (Ed25519)
- `op://ZMB_CD_DEV/zombie-dev-worker-ant/ssh-private-key` (Ed25519)

### Current Mitigations

- Tailscale encrypts traffic via WireGuard (Curve25519 per-session keys — ephemeral, limits harvest window)
- No public SSH port — Tailscale only (reduces attack surface for traffic capture)
- Worker nodes are bare-metal, not multi-tenant (limits lateral movement value)

### Planned Mitigations

1. **SSH key rotation** — rotate worker SSH keys quarterly. Limits the window of harvested traffic per key.
2. **PQC SSH key exchange** — OpenSSH 9.0+ supports `sntrup761x25519-sha512` hybrid KEX (PQC + classical). Enable on worker nodes when Debian ships OpenSSH 9.x+.
3. **PQC SSH host keys** — OpenSSH 9.9+ supports ML-DSA host key signatures. Adopt when available in stable Debian.

---

## Post-Quantum Risk: GitHub App PEM

**Severity:** Low-medium (long-lived RSA 2048 key)

GitHub App private keys (RSA 2048) are used to sign JWTs for installation token requests. These are long-lived and stored in vault. RSA 2048 is breakable by Shor's algorithm in ~4 hours on a CRQC.

### Mitigations

- Rotate annually (GitHub allows regenerating App private keys)
- GitHub does not yet offer PQC key types — no action available beyond rotation
- Installation tokens are short-lived (1 hour) — limits blast radius of a compromised App key

---

## Symmetric Encryption: No Quantum Risk

The envelope encryption system (AES-256-GCM) is quantum-resistant:

- Grover's algorithm reduces AES-256 to ~128-bit equivalent security — still computationally infeasible
- KEK versioning supports rotation without re-encrypting existing secrets
- DEKs are random per secret — compromising one DEK reveals one secret, not all

No changes needed for v1 or v2.

---

## TLS: Partially Protected

Traffic flowing through Cloudflare Tunnel benefits from Cloudflare's hybrid PQC key exchange (X25519Kyber768) when the client supports it (Chrome 124+, Firefox, curl with PQC-enabled OpenSSL).

**Remaining gap:** TLS certificate signatures are still ECDSA P-256. A CRQC could forge a certificate, but:
- Let's Encrypt certificates rotate every 90 days
- Cloudflare manages the edge certificate (their timeline to PQC certificates applies, not ours)
- Certificate Transparency logs would detect forged certificates

No action needed — this is a CA/browser ecosystem upgrade, not application-level.

---

## Action Items

| Priority | Action | Depends on | Target |
|----------|--------|-----------|--------|
| P3 | Quarterly SSH key rotation for worker nodes | Ops process | Q2 2026 |
| P3 | Enable `sntrup761x25519-sha512` KEX on workers | Debian OpenSSH 9.x | When available |
| P3 | Annual GitHub App PEM rotation | Ops process | Mar 2027 |
| P4 | PQC SSH host keys (ML-DSA) | OpenSSH 9.9+ in Debian stable | 2027+ |
| — | Monitor JOSE/JWA ML-DSA standard for JWT signing | IETF draft progress | No action until standard finalized |
