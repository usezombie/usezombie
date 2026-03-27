#!/usr/bin/env bash
# M4_001 Section 2: host readiness gate
# Verifies playbook steps 2.0, 4.0, 5.0:
#   - KVM available (kvm-ok or /dev/kvm exists)
#   - Tailscale installed and active
#   - Docker installed and running
#   - Firecracker binary installed
set -euo pipefail

echo ""
echo "== M4_001 Section 2: host readiness =="

vault_dev="${VAULT_DEV:-ZMB_CD_DEV}"
missing=0

declare -A OP_CACHE_VALUE
declare -A OP_CACHE_STATUS

op_read_with_retry() {
  local ref="$1"
  if [ -n "${OP_CACHE_STATUS[$ref]:-}" ]; then
    if [ "${OP_CACHE_STATUS[$ref]}" = "ok" ]; then
      printf '%s' "${OP_CACHE_VALUE[$ref]}"
      return 0
    fi
    return 1
  fi

  local attempts="${OP_READ_RETRIES:-2}"
  local delay_s="${OP_READ_BASE_DELAY_SECONDS:-1}"
  local min_interval_s="${OP_READ_MIN_INTERVAL_SECONDS:-0.2}"
  local value=""

  for attempt in $(seq 1 "$attempts"); do
    sleep "$min_interval_s"
    if value="$(op read "$ref" 2>/dev/null)"; then
      OP_CACHE_STATUS["$ref"]="ok"
      OP_CACHE_VALUE["$ref"]="$value"
      printf '%s' "$value"
      return 0
    fi

    if [ "$attempt" -lt "$attempts" ]; then
      sleep "$delay_s"
    fi
  done

  OP_CACHE_STATUS["$ref"]="err"
  OP_CACHE_VALUE["$ref"]=""
  return 1
}

# Establish SSH connection details from vault
ssh_key="$(op_read_with_retry "op://$vault_dev/zombie-dev-worker-ant/ssh-private-key" || true)"
ssh_host="$(op_read_with_retry "op://$vault_dev/zombie-dev-worker-ant/hostname" || true)"
ssh_user="$(op_read_with_retry "op://$vault_dev/zombie-dev-worker-ant/deploy-user" || true)"

if [ -z "$ssh_key" ] || [ -z "$ssh_host" ] || [ -z "$ssh_user" ]; then
  echo "  ✗ Cannot establish SSH — missing vault refs. Run section 1 first."
  exit 1
fi

remote_cmd() {
  ssh -i <(printf '%s\n' "$ssh_key") \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=10 \
    -o BatchMode=yes \
    "${ssh_user}@${ssh_host}" "$@" 2>&1
}

# Verify SSH works before proceeding
if ! remote_cmd "echo ok" | grep -q "ok"; then
  echo "  ✗ SSH connectivity failed — cannot check host readiness"
  exit 1
fi
echo "  ✓ SSH connected to ${ssh_user}@${ssh_host}"

# 2.0 KVM available
echo "-- checking KVM (step 2.0)"
kvm_result="$(remote_cmd "test -e /dev/kvm && echo 'kvm_present' || (command -v kvm-ok >/dev/null 2>&1 && kvm-ok 2>&1 || echo 'kvm_missing')")"
if echo "$kvm_result" | grep -q "kvm_present\|KVM acceleration can be used"; then
  echo "  ✓ KVM available"
else
  echo "  ✗ KVM not available"
  echo "    output: $kvm_result"
  missing=$((missing + 1))
fi

# 3.0 + 4.0 Tailscale installed and active
echo "-- checking Tailscale (step 3.0)"
ts_result="$(remote_cmd "command -v tailscale >/dev/null 2>&1 && tailscale status --json 2>/dev/null | head -1 || echo 'tailscale_missing'")"
if echo "$ts_result" | grep -q "tailscale_missing"; then
  echo "  ✗ Tailscale not installed"
  missing=$((missing + 1))
else
  echo "  ✓ Tailscale installed and active"
fi

# 4.0 Docker installed and running
echo "-- checking Docker (step 4.0)"
docker_result="$(remote_cmd "command -v docker >/dev/null 2>&1 && docker info --format '{{.ServerVersion}}' 2>/dev/null || echo 'docker_missing'")"
if echo "$docker_result" | grep -q "docker_missing"; then
  echo "  ✗ Docker not installed or not running"
  missing=$((missing + 1))
else
  echo "  ✓ Docker running (version: $docker_result)"
fi

# 5.0 Firecracker binary installed
echo "-- checking Firecracker (step 5.0)"
fc_result="$(remote_cmd "command -v firecracker >/dev/null 2>&1 && firecracker --version 2>&1 | head -1 || echo 'firecracker_missing'")"
if echo "$fc_result" | grep -q "firecracker_missing"; then
  echo "  ✗ Firecracker not installed"
  missing=$((missing + 1))
else
  echo "  ✓ Firecracker installed ($fc_result)"
fi

if [ "$missing" -gt 0 ]; then
  echo ""
  echo "❌ section 2 failed: $missing issue(s) detected"
  exit 1
fi

echo ""
echo "✅ section 2 passed"
