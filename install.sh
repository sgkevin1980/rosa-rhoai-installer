#!/usr/bin/env bash
# Orchestrator — Phase 1 (ROSA) → confirm gate → optional Phase 2 (OpenShift AI 3.5)
#
# Usage:
#   ./install.sh
#   ./install.sh --tools-only
#   ./install.sh --phase1-only
#   ./install.sh --phase2-only
#   ./install.sh --plan-only
#   ./install.sh --skip-preflight-gates   # already did AWS/ROSA/billing/OCM manually
#   ./install.sh --from=inputs            # skip tools/aws/preflight entirely
#   ./install.sh --force
#
# Default AWS profile: rhdp_demo (lib/defaults.env)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/common.sh"

TOOLS_ONLY=false
PHASE1_ONLY=false
PHASE2_ONLY=false
PLAN_ONLY=false
FORCE=false
PASSTHRU=()

for a in "$@"; do
  case "$a" in
    --tools-only) TOOLS_ONLY=true; PASSTHRU+=("$a") ;;
    --phase1-only) PHASE1_ONLY=true ;;
    --phase2-only) PHASE2_ONLY=true ;;
    --plan-only) PLAN_ONLY=true; PASSTHRU+=("$a") ;;
    --skip-preflight-gates|--skip-preflight) PASSTHRU+=("--skip-preflight-gates") ;;
    --force) FORCE=true; PASSTHRU+=("$a") ;;
    -h|--help)
      sed -n '2,16p' "$0"
      exit 0
      ;;
    *)
      PASSTHRU+=("$a")
      ;;
  esac
done

require_macos

# Ensure default profile name is visible / inherited
export AWS_PROFILE="${AWS_PROFILE:-$DEFAULT_AWS_PROFILE}"

log "rosa-rhoai-installer"
echo "Spec: SPEC.md | Guide: INSTALL.md"
echo "Default AWS profile: ${AWS_PROFILE} (override with export AWS_PROFILE=...)"
echo "Phase 1 workers: 2× m6a.xlarge | AI capacity: Karpenter NodePools in Phase 2 only"
echo

if [[ "$PHASE2_ONLY" == "true" ]]; then
  exec "${SCRIPT_DIR}/phase2/install_rhoai.sh" "${PASSTHRU[@]}"
fi

# Phase 1 (prints Console / API / Username / Password at the end)
"${SCRIPT_DIR}/phase1/install_rosa.sh" "${PASSTHRU[@]}"

if [[ "$TOOLS_ONLY" == "true" || "$PLAN_ONLY" == "true" || "$PHASE1_ONLY" == "true" ]]; then
  ok "Stopped after Phase 1 options (tools/plan/phase1-only)."
  echo "Login credentials were printed above (also state/access-*.txt if verify ran)."
  exit 0
fi

echo
echo "===================================================="
echo "Phase 1 finished (credentials printed above)."
echo "Install OpenShift AI 3.5 (platform-ready)?"
echo "This creates Karpenter CPU+GPU NodePools and installs RHOAI - extra cost when nodes scale."
echo "===================================================="
if confirm_yes "Continue to Phase 2 - OpenShift AI 3.5?"; then
  "${SCRIPT_DIR}/phase2/install_rhoai.sh"
else
  ok "Skipping Phase 2. Re-print creds: cat state/access-*.txt"
  echo "Run later: ./phase2/install_rhoai.sh"
fi

ok "Installer finished"
