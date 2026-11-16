#!/usr/bin/env bash
# Static / contract checks — no AWS, no cluster, no secrets required
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
for f in SPEC.md INSTALL.md README.md \
  templates/terraform.tfvars.tmpl \
  templates/nodepool-cpu.yaml.tmpl \
  templates/nodepool-gpu.yaml.tmpl \
  templates/datasciencecluster-baseline.yaml \
  lib/defaults.env \
  examples/cluster.env.example \
  state/README.md; do
  check test -f "$f"
done

echo "== defaults =="
# shellcheck source=/dev/null
source lib/defaults.env
[[ "$DEFAULT_INSTANCE_TYPE" == "m6a.xlarge" ]] || { echo "[FAIL] DEFAULT_INSTANCE_TYPE=$DEFAULT_INSTANCE_TYPE"; fail=1; }
[[ "$DEFAULT_AWS_PROFILE" == "rhdp_demo" ]] || { echo "[FAIL] DEFAULT_AWS_PROFILE"; fail=1; }
echo "[ok] defaults: m6a.xlarge x2, profile rhdp_demo"

echo "== no personal absolute paths in docs/scripts =="
# Scan product files only (exclude this test file — it names forbidden patterns)
if grep -REn '/Users/|/home/[a-zA-Z]' \
  --include='*.md' --include='*.sh' --include='*.env' --include='*.tmpl' --include='*.yaml' \
  --exclude-dir=state --exclude-dir=.git --exclude='smoke.sh' . 2>/dev/null; then
  echo "[FAIL] absolute home paths found (see above)"
  fail=1
else
  echo "[ok] no absolute home paths in docs/scripts"
fi

echo "== no credential-looking literals in scripts =="
if grep -REn 'AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}|-----BEGIN (RSA |OPENSSH )?PRIVATE' \
  --include='*.sh' --include='*.md' --include='*.env' --include='*.tmpl' --include='*.yaml' \
  --exclude-dir=state --exclude-dir=.git --exclude='smoke.sh' . 2>/dev/null; then
  echo "[FAIL] credential-like literals found"
  fail=1
else
  echo "[ok] no AKIA/ASIA/PEM literals"
fi

echo "== sibling repos (warn only) =="
for d in "$VALIDATED_PATTERN_DIR" "$SNO_GUIDE_DIR" "$TOOLKIT_DIR"; do
  if [[ -d "$d" ]]; then
    echo "[ok] present: $d"
  else
    echo "[warn] missing (needed for live install): $d"
  fi
done

echo "== no user-facing numbered step scripts =="
if compgen -G "phase1/0*.sh" >/dev/null || compgen -G "phase2/1*.sh" >/dev/null; then
  echo "[FAIL] numbered step scripts still present"
  fail=1
else
  echo "[ok] no phase1/0*.sh or phase2/1*.sh"
fi

if [[ "$fail" -ne 0 ]]; then
  echo "SMOKE FAILED"
  exit 1
fi
echo "SMOKE PASSED"
