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

# Ensure default profile name is visible / inherited by child scripts
export AWS_PROFILE="${AWS_PROFILE:-$DEFAULT_AWS_PROFILE}"

# Sibling paths (override with export … before running if your layout differs)
export VALIDATED_PATTERN_DIR="${VALIDATED_PATTERN_DIR:-$WORKSPACE_ROOT/validated-pattern-terraform-rosa}"
export VALIDATED_PATTERN_GIT_URL="${VALIDATED_PATTERN_GIT_URL:-https://github.com/rh-mobb/validated-pattern-terraform-rosa.git}"
export VALIDATED_PATTERN_GIT_REF="${VALIDATED_PATTERN_GIT_REF:-main}"
export SNO_GUIDE_DIR="${SNO_GUIDE_DIR:-$WORKSPACE_ROOT/rhoai-sno-setup-guide}"
export TOOLKIT_DIR="${TOOLKIT_DIR:-$WORKSPACE_ROOT/RHOAI-Toolkit}"

log "rosa-rhoai-installer"
echo "Guide: INSTALL.md | Defaults: multi-AZ, 1× m6a.xlarge/AZ | profile=${AWS_PROFILE}"
echo "Pattern: ${VALIDATED_PATTERN_DIR}"
echo

if [[ "$PHASE2_ONLY" == "true" ]]; then
  ensure_dependency_repos phase2
  export SNO_GUIDE_DIR TOOLKIT_DIR
  exec "${SCRIPT_DIR}/phase2/install_rhoai.sh" "${PASSTHRU[@]}"
fi

# Clone sibling pattern if missing (re-pull: git -C "$VALIDATED_PATTERN_DIR" pull)
if [[ "$TOOLS_ONLY" != "true" ]]; then
  ensure_dependency_repos phase1
  export VALIDATED_PATTERN_DIR
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
