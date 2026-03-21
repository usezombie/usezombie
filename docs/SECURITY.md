# Security Posture & Cryptographic Risk Assessment

**Date:** Mar 21, 2026
**Status:** Living document — update on infrastructure or algorithm changes

---

## How Long Does a Quantum Attack Take?

Current best estimates for breaking P-256 / Ed25519 with a cryptographically relevant quantum computer (CRQC):

| Source | Estimate | Qubits needed |
|--------|----------|---------------|
| IBM / Google roadmap | 2035–2040 earliest | ~4,000+ logical qubits |
| Gidney & Ekera (2021) | ~8 hours once hardware exists | 2,330 logical qubits (~20M physical) |
| NIST PQC report | Not before 2030, likely later | — |
| BSI (German fed) | Plan for post-2030 | — |

Today's largest quantum computers: ~1,200 physical qubits (IBM Condor). You need ~20 million physical qubits to break P-256. We're 4+ orders of magnitude away.

Once the hardware exists, the actual attack (Shor's algorithm on the P-256 curve) would take **hours, not seconds**.

---

## Why JWTs Are Not at Risk

Clerk JWTs expire in 60 seconds. An attacker would need to:

1. Intercept the JWT
2. Extract the public key from JWKS
3. Run Shor's to derive the private key (~8 hours)
4. Forge a new JWT

By step 3, the original token is long expired, and the forged token would need a valid `exp` claim that Clerk's JWKS rotation would have already invalidated.

The real risk is not JWT forgery — it's **long-lived asymmetric keys** (TLS certificates, SSH keys, code signing). Those sit unchanged for months or years. JWTs are ephemeral by design.

---

## TLS 1.3 and SSH Can Be Broken in < 8 Hours — Real Vulnerability

**TLS 1.3** — partially protected already. Cloudflare and Chrome ship **X25519Kyber768** hybrid key exchange today. `api-dev.usezombie.com` traffic through Cloudflare Tunnel already negotiates PQC key exchange. The handshake is safe. But the **server certificate** (ECDSA P-256) is still classically signed — a CRQC could forge a certificate. The fix is PQC certificate signatures, which is in draft (NIST SP 800-227).

**SSH** — this is the real exposure. Worker nodes use **Ed25519** keys:

- `zombie-prod-worker-ant/ssh-private-key`
- `zombie-prod-worker-bird/ssh-private-key`
- `zombie-dev-worker-ant/ssh-private-key`

Ed25519 is Curve25519 — same class as P-256, breakable by Shor's in the same ~8 hour window. These keys are **long-lived** (they sit in vault indefinitely, don't expire, don't rotate). That's the exact "harvest now, decrypt later" threat:

1. Attacker records Tailscale SSH traffic today
2. Stores it
3. In 2035, runs Shor's on the captured Ed25519 public key (~8 hrs)
4. Derives private key, decrypts all stored sessions

---

## What's Actually at Risk in This Stack

| Asset | Algorithm | Lifespan | PQC risk |
|-------|-----------|----------|----------|
| Clerk JWTs | ES256 (P-256) | 60 seconds | **None** — expires before attack completes |
| TLS key exchange | X25519Kyber768 | Per-session | **Protected** — Cloudflare already ships PQC |
| TLS certificates | ECDSA P-256 | 90 days (Let's Encrypt) | **Low** — rotates frequently |
| SSH worker keys | Ed25519 | Indefinite | **Real risk** — harvest now, decrypt later |
| Tailscale WireGuard | Curve25519 | Per-session, rotated | **Low** — ephemeral keys, rotated frequently |
| Encryption KEK | AES-256 | Long-lived | **Safe** — Grover's gives 128-bit security, still infeasible |
| Per-secret DEK | AES-256-GCM | Per-secret | **Safe** — random per encrypt, wrapped by KEK |
| GitHub App PEM | RSA 2048 | Long-lived | **Medium** — breakable by Shor's in ~4 hrs, rotate annually |

---

## Practical Mitigations (No Code Changes)

1. **SSH key rotation** — rotate worker SSH keys quarterly. Limits the window of harvested traffic per key.
2. **OpenSSH 9.0+ supports PQC** — `ssh-keygen -t ml-kem-768` (hybrid ML-KEM + X25519 key exchange). Workers run Debian — OpenSSH 9.x is available. This protects the key exchange but not the host key signature.
3. **OpenSSH 9.9+ supports ML-DSA** — `sntrup761x25519-sha512` is already the default KEX. Full PQC host keys (`-t ml-dsa-87`) are coming.

---

## Symmetric Encryption: No Quantum Risk

The envelope encryption system (AES-256-GCM) is quantum-resistant:

- Grover's algorithm reduces AES-256 to ~128-bit equivalent security — still computationally infeasible
- KEK versioning supports rotation without re-encrypting existing secrets (KEK_VERSION 1 → 2)
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

## GitHub App PEM: Rotate Annually

GitHub App private keys (RSA 2048) are used to sign JWTs for installation token requests. These are long-lived and stored in vault. RSA 2048 is breakable by Shor's algorithm in ~4 hours on a CRQC.

- Rotate annually (GitHub allows regenerating App private keys)
- GitHub does not yet offer PQC key types — no action available beyond rotation
- Installation tokens are short-lived (1 hour) — limits blast radius of a compromised App key

---

## Action Items

| Priority | Action | Depends on | Target |
|----------|--------|-----------|--------|
| P3 | Quarterly SSH key rotation for worker nodes | Ops process | Q2 2026 |
| P3 | Enable `sntrup761x25519-sha512` KEX on workers | Debian OpenSSH 9.x | When available |
| P3 | Annual GitHub App PEM rotation | Ops process | Mar 2027 |
| P4 | PQC SSH host keys (ML-DSA) | OpenSSH 9.9+ in Debian stable | 2027+ |
| — | Monitor JOSE/JWA ML-DSA standard for JWT signing | IETF draft progress | No action until standard finalized |
