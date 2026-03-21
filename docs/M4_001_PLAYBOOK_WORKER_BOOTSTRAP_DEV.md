# M4_001: Playbook — DEV Worker Bootstrap (`zombie-dev-worker-ant`)

**Milestone:** M4
**Workstream:** 001
**Updated:** Mar 21, 2026
**Prerequisite:** `docs/M2_002_PLAYBOOK_PRIMING_INFRA.md` complete — vaults populated, Tailscale authkey in `ZMB_CD_PROD/tailscale/authkey`, SSH key in `ZMB_CD_DEV/zombie-dev-worker-ant/ssh-private-key`.

Bootstrap the DEV bare-metal worker node (`zombie-dev-worker-ant`) so CI can deploy the `zombied worker` process to it. Each section below is one atomic workstream — complete and verify before advancing.

---

## Human vs Agent Split

| Step | Owner | Why |
|------|-------|-----|
| 1.0 Provision server + OS | Human | OVHCloud console, requires account |
| 2.0 Generate + store SSH key | Human | Key must be stored in vault before agent can use it |
| 3.0 Join Tailscale | Human | Requires console/KVM access at first boot |
| 4.0 Install Docker | Agent | SSH via Tailscale, fully scriptable |
| 5.0 Install Firecracker + KVM | Agent | SSH via Tailscale, fully scriptable |
| 6.0 Bootstrap `/opt/zombie/` | Agent | SSH via Tailscale, fully scriptable |
| 7.0 Smoke test | Agent | SSH via Tailscale, verify deploy.sh end-to-end |

---

## 1.0 Provision Server + OS

**Owner:** Human
**Goal:** OVHCloud KS-1 bare-metal node running Debian Trixie, reachable via console.

### Steps

1. Log in to [OVHCloud Manager](https://ca.ovh.com/manager/)
2. Order KS-1 in Beauharnois, CA (BHS) region
3. Install **Debian 12 (Bookworm)** or **Debian Trixie** via the reinstall wizard
4. Set root password or add your public key during reinstall
5. Wait for delivery email — typically 15–60 min

### Acceptance

```bash
# From your Mac (public SSH during bootstrap — before Tailscale locks it down)
ssh root@<ovhcloud-ip> "uname -r && lscpu | grep -i virt"
```

Expected: kernel version printed, `Virtualization type: full` present (KVM available on bare-metal).

---

## 2.0 Generate + Store SSH Key

**Owner:** Human
**Goal:** A dedicated deploy SSH key pair exists. Private key is in the vault. Public key is on the server.

This is the key CI uses — not your personal key.

### Steps

```bash
# Generate a new Ed25519 key (no passphrase — CI needs unattended access)
ssh-keygen -t ed25519 -C "zombie-dev-worker-ant deploy key" -f ~/.ssh/zombie-dev-worker-ant -N ""

# Store private key in vault (ZMB_CD_DEV)
op item edit "zombie-dev-worker-ant" --vault ZMB_CD_DEV \
  "ssh-private-key[concealed]=$(cat ~/.ssh/zombie-dev-worker-ant)"

# Add public key to server authorized_keys
ssh root@<ovhcloud-ip> \
  "mkdir -p ~/.ssh && echo '$(cat ~/.ssh/zombie-dev-worker-ant.pub)' >> ~/.ssh/authorized_keys"
```

### Acceptance

```bash
# Confirm private key reads back from vault (non-empty)
op read "op://ZMB_CD_DEV/zombie-dev-worker-ant/ssh-private-key" | head -1
# Expected: -----BEGIN OPENSSH PRIVATE KEY-----

# Confirm passwordless SSH using the vault key
KEY=$(op read "op://ZMB_CD_DEV/zombie-dev-worker-ant/ssh-private-key")
ssh -i <(printf '%s\n' "$KEY") root@<ovhcloud-ip> "echo ok"
# Expected: ok
```

---

## 3.0 Join Tailscale

**Owner:** Human (requires SSH or console access to server)
**Goal:** `zombie-dev-worker-ant` is in the tailnet and reachable by hostname from any node in the tailnet (Mac, CI runner).

Tailscale replaces public SSH — once joined, disable password auth and restrict `sshd` to tailnet interface.

### Steps

```bash
# SSH into the server (public IP, before Tailscale)
ssh root@<ovhcloud-ip>

# On the server: install Tailscale
curl -fsSL https://tailscale.com/install.sh | sh

# Join tailnet — authkey from vault (read on your Mac, paste into server session)
# On your Mac:
op read "op://ZMB_CD_PROD/tailscale/authkey"

# On the server (paste the authkey):
tailscale up --authkey "<authkey>" --hostname zombie-dev-worker-ant

# Verify node is visible
tailscale status
```

After joining, harden SSH (optional but recommended):

```bash
# Restrict sshd to tailnet interface only
echo "ListenAddress $(tailscale ip -4)" >> /etc/ssh/sshd_config
systemctl restart sshd
```

### Acceptance

```bash
# From your Mac — SSH via Tailscale hostname (no IP needed)
KEY=$(op read "op://ZMB_CD_DEV/zombie-dev-worker-ant/ssh-private-key")
ssh -i <(printf '%s\n' "$KEY") zombie-dev-worker-ant "tailscale status | grep zombie-dev-worker-ant"
# Expected: zombie-dev-worker-ant  <tailscale-ip>  ... active
```

---

## 4.0 Install Docker

**Owner:** Agent
**Goal:** Docker daemon is running on the node. Agent can pull GHCR images.

### Steps

```bash
KEY=$(op read "op://ZMB_CD_DEV/zombie-dev-worker-ant/ssh-private-key")

ssh -i <(printf '%s\n' "$KEY") zombie-dev-worker-ant << 'REMOTE'
set -euo pipefail

apt-get update -qq
apt-get install -y docker.io
systemctl enable docker
systemctl start docker

# Smoke pull — image is public on GHCR, no auth needed
docker pull ghcr.io/usezombie/zombied:dev-latest
REMOTE
```

### Acceptance

```bash
KEY=$(op read "op://ZMB_CD_DEV/zombie-dev-worker-ant/ssh-private-key")
ssh -i <(printf '%s\n' "$KEY") zombie-dev-worker-ant \
  "docker ps && docker images ghcr.io/usezombie/zombied"
# Expected: docker ps header (no error), zombied image listed
```

---

## 5.0 Install Firecracker + KVM

**Owner:** Agent
**Goal:** KVM is accessible on the node. Firecracker binary is installed. The `zombied worker` process can boot microVMs (required for M4_008 sandbox execution).

### Steps

```bash
KEY=$(op read "op://ZMB_CD_DEV/zombie-dev-worker-ant/ssh-private-key")

ssh -i <(printf '%s\n' "$KEY") zombie-dev-worker-ant << 'REMOTE'
set -euo pipefail

# Verify KVM is available — bail early if not
apt-get install -y cpu-checker
if ! kvm-ok 2>&1 | grep -q "KVM acceleration can be used"; then
  echo "ERROR: KVM not available on this host — cannot proceed" >&2
  exit 1
fi

# Install Firecracker
ARCH=$(uname -m)
FC_VERSION=v1.7.0
curl -fsSL \
  "https://github.com/firecracker-microvm/firecracker/releases/download/${FC_VERSION}/firecracker-${FC_VERSION}-${ARCH}.tgz" \
  | tar xz -C /usr/local/bin --strip-components=1

firecracker --version

# Allow deploy user (debian) to access KVM device without root
usermod -aG kvm debian
REMOTE
```

### Acceptance

```bash
KEY=$(op read "op://ZMB_CD_DEV/zombie-dev-worker-ant/ssh-private-key")
ssh -i <(printf '%s\n' "$KEY") zombie-dev-worker-ant \
  "kvm-ok && firecracker --version && ls -l /dev/kvm"
# Expected:
#   INFO: /dev/kvm exists
#   KVM acceleration can be used
#   Firecracker v1.7.0
#   crw-rw---- 1 root kvm ... /dev/kvm
```

---

## 6.0 Bootstrap `/opt/zombie/`

**Owner:** Agent
**Goal:** `/opt/zombie/deploy.sh` and `/opt/zombie/.env` exist on the node. CI can call `deploy.sh` to pull and restart the worker container.

### Steps

```bash
KEY=$(op read "op://ZMB_CD_DEV/zombie-dev-worker-ant/ssh-private-key")

# Read secrets from vault (on your Mac, before SSH)
DB_URL=$(op read "op://ZMB_CD_DEV/planetscale-dev/connection-string")
REDIS_URL=$(op read "op://ZMB_CD_DEV/upstash-dev/url")
ENC_KEY=$(op read "op://ZMB_CD_DEV/zombied-local-config/encryption-master-key")
GH_APP_ID=$(op read "op://ZMB_CD_DEV/github-app/app-id")
GH_APP_KEY=$(op read "op://ZMB_CD_DEV/github-app/private-key")

ssh -i <(printf '%s\n' "$KEY") zombie-dev-worker-ant << REMOTE
set -euo pipefail

mkdir -p /opt/zombie
chown debian:debian /opt/zombie

# deploy.sh — CI calls this on every push to main
cat > /opt/zombie/deploy.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

IMAGE="ghcr.io/usezombie/zombied:dev-latest"

echo "Pulling \$IMAGE..."
docker pull "\$IMAGE"

echo "Restarting zombied-worker..."
docker stop zombied-worker 2>/dev/null || true
docker rm   zombied-worker 2>/dev/null || true

docker run -d \\
  --name zombied-worker \\
  --restart unless-stopped \\
  --device /dev/kvm \\
  --env-file /opt/zombie/.env \\
  "\$IMAGE" \\
  zombied worker

echo "Done."
docker ps --filter name=zombied-worker
EOF
chmod +x /opt/zombie/deploy.sh

# .env — worker-only vars (no PORT or MIGRATE_ON_START; web API is on Fly)
cat > /opt/zombie/.env << EOF
DATABASE_URL_WORKER=$DB_URL
REDIS_URL_WORKER=$REDIS_URL
ENCRYPTION_MASTER_KEY=$ENC_KEY
GITHUB_APP_ID=$GH_APP_ID
GITHUB_APP_PRIVATE_KEY=$GH_APP_KEY
ENVIRONMENT=dev
EOF
chmod 600 /opt/zombie/.env

echo "Bootstrap complete."
ls -la /opt/zombie/
REMOTE
```

### Acceptance

```bash
KEY=$(op read "op://ZMB_CD_DEV/zombie-dev-worker-ant/ssh-private-key")
ssh -i <(printf '%s\n' "$KEY") zombie-dev-worker-ant \
  "ls -la /opt/zombie/ && head -1 /opt/zombie/deploy.sh && stat -c '%a' /opt/zombie/.env"
# Expected:
#   deploy.sh  (executable)
#   .env       (600 permissions)
#   #!/usr/bin/env bash
```

---

## 7.0 Smoke Test — First Manual Deploy

**Owner:** Agent
**Goal:** `deploy.sh` runs end-to-end: pulls image, starts container with KVM access, container stays running.

Run this before CI is activated. If it fails here, fix it before enabling the CI job.

### Steps

```bash
KEY=$(op read "op://ZMB_CD_DEV/zombie-dev-worker-ant/ssh-private-key")

ssh -i <(printf '%s\n' "$KEY") zombie-dev-worker-ant \
  "cd /opt/zombie && ./deploy.sh"
```

### Acceptance

```bash
KEY=$(op read "op://ZMB_CD_DEV/zombie-dev-worker-ant/ssh-private-key")
ssh -i <(printf '%s\n' "$KEY") zombie-dev-worker-ant << 'REMOTE'
# Container is running
docker ps --filter name=zombied-worker --format "{{.Status}}" | grep -i "up"

# KVM device was passed into the container
docker inspect zombied-worker | grep -i kvm

# Worker process started (give it 5s)
sleep 5
docker logs zombied-worker 2>&1 | tail -5
REMOTE
# Expected:
#   Up X seconds
#   /dev/kvm listed in HostConfig.Devices
#   Worker log lines (no crash/panic)
```

---

## 8.0 Activate CI

**Owner:** Human (flip a GitHub variable)
**Goal:** `deploy-dev-worker` job in `deploy-dev.yml` starts running against this node on every push to main.

Once §7.0 smoke test passes, enable the CI job:

1. Go to GitHub → Settings → Variables → Actions
2. Set `DEV_WORKER_READY=true`

CI will SSH to `zombie-dev-worker-ant` via Tailscale on the next push and call `deploy.sh` — same script you just tested manually.

### Acceptance

Push a commit to `main` (or re-run the last `deploy-dev.yml` run). Verify:

- `deploy-dev-worker` job reaches the SSH step and exits 0
- `docker ps` on the node shows a freshly-restarted `zombied-worker` container with a recent start time

---

## Sequence Summary

```
1.0 Provision server (Human)         ← OVHCloud KS-1, Debian
2.0 SSH key → vault (Human)          ← Ed25519, ZMB_CD_DEV
3.0 Tailscale join (Human)           ← zombie-dev-worker-ant hostname
4.0 Docker (Agent via SSH)           ← docker.io, GHCR pull verified
5.0 Firecracker + KVM (Agent)        ← v1.7.0, kvm-ok must pass
6.0 /opt/zombie/ bootstrap (Agent)   ← deploy.sh + .env from vault
7.0 Smoke test (Agent)               ← manual deploy.sh run, container up
8.0 Activate CI (Human)              ← flip DEV_WORKER_READY=true
```

**PROD workers** (`zombie-prod-worker-ant`, `zombie-prod-worker-bird`) follow the same sequence. Replace `ZMB_CD_DEV` with `ZMB_CD_PROD`, image tag `dev-latest` with `latest`, and `ENVIRONMENT=dev` with `ENVIRONMENT=prod`.
