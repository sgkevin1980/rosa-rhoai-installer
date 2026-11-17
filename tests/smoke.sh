#!/usr/bin/env bash
# Static checks — no AWS / cluster required
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail=0
check() {
  if "$@"; then
    echo "[ok] $*"
  else
    echo "[FAIL] $*"
    fail=1
  fi
}

echo "== bash -n =="
for f in install.sh phase1/install_rosa.sh phase2/install_rhoai.sh lib/common.sh; do
  check bash -n "$f"
done

echo "== required files =="
for f in INSTALL.md README.md \
  templates/terraform.tfvars.tmpl \
  templates/nodepool-cpu.yaml.tmpl \
  templates/nodepool-gpu.yaml.tmpl \
  templates/datasciencecluster-baseline.yaml \
  lib/defaults.env \
  state/README.md; do
  check test -f "$f"
done

echo "== defaults =="
# shellcheck source=/dev/null
source lib/defaults.env
[[ "$DEFAULT_INSTANCE_TYPE" == "m6a.xlarge" ]] || { echo "[FAIL] DEFAULT_INSTANCE_TYPE"; fail=1; }
[[ "$DEFAULT_MULTI_AZ" == "true" ]] || { echo "[FAIL] DEFAULT_MULTI_AZ"; fail=1; }
[[ "$DEFAULT_MIN_REPLICAS" == "1" && "$DEFAULT_MAX_REPLICAS" == "1" ]] || { echo "[FAIL] replicas"; fail=1; }
grep -q 'multi_az = __MULTI_AZ__' templates/terraform.tfvars.tmpl || { echo "[FAIL] multi_az tmpl"; fail=1; }
echo "[ok] multi-AZ, 1 worker/AZ, m6a.xlarge"

echo "== no personal absolute paths =="
if grep -REn '/Users/|/home/[a-zA-Z]' \
  --include='*.md' --include='*.sh' --include='*.env' --include='*.tmpl' --include='*.yaml' \
  --exclude-dir=state --exclude-dir=.git --exclude='smoke.sh' . 2>/dev/null; then
  echo "[FAIL] absolute home paths found"
  fail=1
else
  echo "[ok] no absolute home paths"
fi

if [[ "$fail" -ne 0 ]]; then
  echo "SMOKE FAILED"
  exit 1
fi
echo "SMOKE PASSED"
