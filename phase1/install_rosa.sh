#!/usr/bin/env bash
# Phase 1 — tools, AWS profile, manual gates, provision ROSA, print access details
#
# Usage:
#   ./phase1/install_rosa.sh              # full Phase 1
#   ./phase1/install_rosa.sh --tools-only
#   ./phase1/install_rosa.sh --plan-only           # init+plan, no apply
#   ./phase1/install_rosa.sh --skip-preflight-gates # skip YES gates if already set up
#   ./phase1/install_rosa.sh --from=inputs          # skip tools/aws/preflight entirely
#   ./phase1/install_rosa.sh --force
#
# Steps: tools → aws → preflight → inputs → provision → verify
# Default AWS profile: rhdp_demo | Default: multi-AZ, 1× m6a.xlarge per AZ
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../lib/common.sh"

FROM="tools"
TOOLS_ONLY=false
PLAN_ONLY=false
FORCE=false
SKIP_PREFLIGHT_GATES=false
for a in "$@"; do
  case "$a" in
    --tools-only) TOOLS_ONLY=true ;;
    --plan-only) PLAN_ONLY=true ;;
    --force) FORCE=true ;;
    --skip-preflight-gates|--skip-preflight) SKIP_PREFLIGHT_GATES=true ;;
    --from=*) FROM="${a#--from=}" ;;
    --from) die "Use --from=STEP (tools|aws|preflight|inputs|provision|verify)" ;;
    -h|--help)
      sed -n '2,16p' "$0"
      exit 0
      ;;
  esac
done

step_rank() {
  case "$1" in
    tools) echo 1 ;;
    aws) echo 2 ;;
    preflight) echo 3 ;;
    inputs) echo 4 ;;
    provision) echo 5 ;;
    verify) echo 6 ;;
    *) echo 0 ;;
  esac
}
FROM_N="$(step_rank "$FROM")"
[[ "$FROM_N" -gt 0 ]] || die "Unknown --from=$FROM (tools|aws|preflight|inputs|provision|verify)"
should_run() { [[ "$(step_rank "$1")" -ge "$FROM_N" ]]; }

# ─── tools ───────────────────────────────────────────────────────────
step_tools() {
  require_macos
  log "Step tools — bootstrap CLIs (Homebrew)"
  if ! command -v brew >/dev/null 2>&1; then
    err "Homebrew is not installed."
    echo
    echo "Install Homebrew, then re-run:"
    echo '  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
    echo "See INSTALL.md Step 0.2."
    exit 1
  fi
  ok "Homebrew found: $(brew --prefix)"

  ensure_pkg() {
    local brew_name="$1" cmd_name="${2:-$1}"
    if command -v "$cmd_name" >/dev/null 2>&1; then
      ok "$cmd_name already installed"
      return 0
    fi
    log "Installing $brew_name via brew…"
    brew install "$brew_name"
    command -v "$cmd_name" >/dev/null 2>&1 || die "Installed $brew_name but '$cmd_name' not on PATH."
    ok "$cmd_name installed"
  }

  ensure_pkg git git
  ensure_pkg jq jq
  ensure_pkg make make
  ensure_pkg awscli aws
  if ! command -v terraform >/dev/null 2>&1; then
    brew install hashicorp/tap/terraform 2>/dev/null || brew install terraform
  else
    ok "terraform already installed"
  fi
  if ! command -v rosa >/dev/null 2>&1; then
    brew install rosa-cli 2>/dev/null || brew install rosa || true
  else
    ok "rosa already installed"
  fi
  if ! command -v oc >/dev/null 2>&1; then
    brew install openshift-cli || true
  else
    ok "oc already installed"
  fi

  for c in git jq make aws terraform rosa oc; do
    command -v "$c" >/dev/null 2>&1 || die "Still missing: $c. Install via brew, then re-run. See INSTALL.md."
  done
  log "Version check"
  aws --version
  rosa version || true
  oc version --client || true
  terraform version
  ok "All required tools are available"

  # Auto-clone Terraform pattern (and AI deps) beside this installer if missing
  ensure_dependency_repos all
}

# ─── aws (RHDP AK/SK) ────────────────────────────────────────────────
step_aws() {
  require_cmd aws
  log "Step aws — RHDP Access Key + Secret (like OCM token paste)"
  echo "Credentials are stored in ~/.aws/credentials. See INSTALL.md Step 0.3."
  echo
  if [[ -f "$CLUSTER_ENV" ]]; then
    # shellcheck source=/dev/null
    set -a; source "$CLUSTER_ENV"; set +a
  fi

  local default_profile="${AWS_PROFILE:-$DEFAULT_AWS_PROFILE}"
  local default_region="${AWS_REGION:-$DEFAULT_REGION}"

  # Offer reuse only when an existing profile already authenticates
  if AWS_PROFILE="$default_profile" aws sts get-caller-identity >/dev/null 2>&1; then
    echo "Found working AWS profile: ${default_profile}"
    AWS_PROFILE="$default_profile" aws sts get-caller-identity
    if confirm_yes "Use this existing profile (skip pasting Access Key)?"; then
      export AWS_PROFILE="$default_profile"
      prompt REGION "Default region" "$default_region"
      aws configure set region "$REGION" --profile "$AWS_PROFILE"
      ACCOUNT_ID="$(aws_account_id)"
      ok "Using profile '${AWS_PROFILE}'. Account ID: ${ACCOUNT_ID}"
      save_cluster_env_kv AWS_PROFILE "$AWS_PROFILE"
      save_cluster_env_kv AWS_REGION "$REGION"
      save_cluster_env_kv AWS_ACCOUNT_ID "$ACCOUNT_ID"
      echo
      echo "Write this down for the billing-link check:"
      echo "  My AWS Account ID: ${ACCOUNT_ID}"
      return 0
    fi
    echo "OK — enter new Access Key / Secret below."
  fi

  # RHDP path: collect secrets first (same UX as OCM offline token)
  prompt ACCESS_KEY "AWS Access Key ID"
  prompt_secret SECRET_KEY "AWS Secret Access Key"
  prompt PROFILE_NAME "Save as AWS profile name" "$default_profile"
  prompt REGION "Default region" "$default_region"

  aws configure set aws_access_key_id "$ACCESS_KEY" --profile "$PROFILE_NAME"
  aws configure set aws_secret_access_key "$SECRET_KEY" --profile "$PROFILE_NAME"
  aws configure set region "$REGION" --profile "$PROFILE_NAME"
  aws configure set output json --profile "$PROFILE_NAME"

  export AWS_PROFILE="$PROFILE_NAME"
  aws sts get-caller-identity || die "Credentials rejected. Re-check Access Key / Secret from RHDP."
  ACCOUNT_ID="$(aws_account_id)"
  ok "AWS profile '${PROFILE_NAME}' works. Account ID: ${ACCOUNT_ID}"
  save_cluster_env_kv AWS_PROFILE "$PROFILE_NAME"
  save_cluster_env_kv AWS_REGION "$REGION"
  save_cluster_env_kv AWS_ACCOUNT_ID "$ACCOUNT_ID"
  echo
  echo "Write this down for the billing-link check:"
  echo "  My AWS Account ID: ${ACCOUNT_ID}"
}

# ─── preflight (manual gates + optional skip) ─────────────────────────
preflight_ensure_ocm_token() {
  # Collect or reuse OCM token (same UX as AK)
  if [[ -f "$OCM_TOKEN_FILE" ]]; then
    echo "Found existing token file: $OCM_TOKEN_FILE"
    if confirm_yes "Use the existing offline token file?"; then
      ok "Using existing $OCM_TOKEN_FILE"
      return 0
    fi
  fi
  echo "1. Open https://console.redhat.com/openshift/token"
  echo "2. Copy the API token, then paste below (hidden)"
  prompt_secret OCM_TOKEN_PASTE "Paste OCM offline token"
  mkdir -p "$(dirname "$OCM_TOKEN_FILE")"
  umask 077
  printf '%s\n' "$OCM_TOKEN_PASTE" >"$OCM_TOKEN_FILE"
  chmod 600 "$OCM_TOKEN_FILE"
  ok "Wrote $OCM_TOKEN_FILE (mode 600)"
}

preflight_verify_ocm() {
  local STS_ACCOUNT="$1"
  rosa_login
  OCM_USER=""
  WHOAMI_JSON="$(rosa whoami --output json 2>/dev/null || true)"
  if [[ -n "$WHOAMI_JSON" ]]; then
    OCM_USER="$(echo "$WHOAMI_JSON" | jq -r '.username // .Username // empty')"
  fi
  if [[ -z "$OCM_USER" ]]; then
    rosa whoami || true
    OCM_USER="$(rosa whoami 2>&1 | awk -F: '/Username|Account Username/{print $2}' | head -1 | xargs || true)"
  fi
  ok "OCM username: ${OCM_USER:-unknown}"
  prompt EXPECTED_USER "Type the OCM username you expect (must match)" "${OCM_USER}"
  [[ "$EXPECTED_USER" == "$OCM_USER" ]] || die "Expected '${EXPECTED_USER}' but rosa whoami is '${OCM_USER}'. Wrong account — stop."

  WHOAMI_TEXT="$(rosa whoami 2>&1 || true)"
  echo "$WHOAMI_TEXT"
  if echo "$WHOAMI_TEXT" | grep -q "$STS_ACCOUNT"; then
    ok "OCM view includes STS account ${STS_ACCOUNT}"
  else
    warn "Could not clearly see AWS account ${STS_ACCOUNT} in rosa whoami output."
    if [[ "$SKIP_PREFLIGHT_GATES" != "true" ]]; then
      confirm_gate \
        "Confirm OCM ↔ AWS account match" \
        "Your STS AWS Account ID is: ${STS_ACCOUNT}

Type YES only if the linked billing AWS account is ${STS_ACCOUNT}."
    else
      warn "Skipped account-match YES gate. Wrong billing link will fail at apply."
    fi
  fi
  save_cluster_env_kv OCM_USERNAME "$EXPECTED_USER"
}

preflight_ensure_ocm_role() {
  # Automated: link this AWS account to the OCM org (fixes CLUSTERS-MGMT-403).
  # Uses --admin so the role can manage account resources for cluster create.
  log "Ensuring OCM role exists and is linked (automated)"
  local linked
  linked="$(rosa list ocm-role 2>/dev/null | awk 'NR>1 && $3=="Yes" {print; exit}' || true)"
  if [[ -n "$linked" ]]; then
    ok "Linked OCM role already present"
    echo "$linked"
    return 0
  fi

  warn "No linked OCM role in this AWS account — creating one (rosa create ocm-role --admin)"
  # Prefer admin capability for first-time RHDP accounts; mode auto applies IAM changes now
  if rosa create ocm-role --admin --mode auto --yes; then
    ok "OCM role created"
  else
    # Fallback least-privilege profile used by validated-pattern (still enough for TF/CLI)
    warn "Admin OCM role create failed — trying --no-console profile"
    rosa create ocm-role --no-console --mode auto --yes \
      || die "rosa create ocm-role failed. Check IAM permissions on this AWS user, then retry."
  fi

  linked="$(rosa list ocm-role 2>/dev/null | awk 'NR>1 && $3=="Yes" {print; exit}' || true)"
  [[ -n "$linked" ]] || die "OCM role still not Linked=Yes. Run: rosa list ocm-role"
  ok "OCM role linked"
  echo "$linked"

  # ELB service-linked role (common one-time prerequisite)
  if ! aws iam get-role --role-name AWSServiceRoleForElasticLoadBalancing >/dev/null 2>&1; then
    log "Creating ELB service-linked role"
    aws iam create-service-linked-role --aws-service-name elasticloadbalancing.amazonaws.com \
      || warn "Could not create ELB service-linked role — create may fail later if missing"
  else
    ok "ELB service-linked role present"
  fi
}

step_preflight() {
  require_cmd aws
  require_cmd rosa
  require_cmd jq
  log "Step preflight — AWS + ROSA enable + billing + OCM"
  echo "Guide: INSTALL.md Steps 0.4–0.6"
  echo "Default AWS profile name: ${DEFAULT_AWS_PROFILE}"
  echo

  if [[ -f "$CLUSTER_ENV" ]]; then
    # shellcheck source=/dev/null
    set -a; source "$CLUSTER_ENV"; set +a
  fi
  export AWS_PROFILE="${AWS_PROFILE:-$DEFAULT_AWS_PROFILE}"
  ensure_aws_profile
  STS_ACCOUNT="$(aws_account_id)"
  ok "STS Account ID: ${STS_ACCOUNT}"
  save_cluster_env_kv AWS_ACCOUNT_ID "$STS_ACCOUNT"

  # Experienced / resumed users: skip long YES gates if already done manually
  if [[ "$SKIP_PREFLIGHT_GATES" != "true" ]]; then
    echo
    echo "If you already configured AWS profile (${DEFAULT_AWS_PROFILE}), enabled ROSA,"
    echo "linked billing, set up the OCM token, and can run rosa — you can skip the"
    echo "detailed YES gates and run automated checks only."
    if confirm_yes "Skip detailed preflight gates (I already completed ROSA enable + billing + OCM)?"; then
      SKIP_PREFLIGHT_GATES=true
      warn "Detailed gates skipped. Create will still fail if billing/ROSA enable is missing."
    fi
  fi

  if [[ "$SKIP_PREFLIGHT_GATES" == "true" ]]; then
    log "Fast preflight — automated checks only (detailed gates skipped)"
    confirm_gate \
      "Confirm you already meet preflight requirements" \
      "Type YES only if ALL of these are true for AWS account ${STS_ACCOUNT}:

1. AWS CLI profile works (sts get-caller-identity)
2. ROSA HCP is enabled in the AWS Console (prerequisites green)
3. AWS ↔ Red Hat billing is linked (Connect accounts done)
4. OCM offline token is available (file or you will paste next)
5. rosa login / rosa whoami works for the correct Red Hat user

If any item is false, press Ctrl-C and re-run without --skip-preflight-gates."
    preflight_ensure_ocm_token
    preflight_verify_ocm "$STS_ACCOUNT"
    preflight_ensure_ocm_role
    ok "Fast preflight passed"
    return 0
  fi

  confirm_gate \
    "MANUAL GATE 1/3 — Enable ROSA (AWS Console)" \
    "This is NOT automated. Screenshots: INSTALL.md Step 0.4

1. AWS Console → search ROSA → Get started
2. Click Enable ROSA
3. On Verify ROSA prerequisites, wait until status is GREEN
   (ROSA with HCP enabled — Classic may also show; you will use HCP)
4. AWS account for this check: ${STS_ACCOUNT}

Guide + images: INSTALL.md Step 0.4"

  confirm_gate \
    "MANUAL GATE 2/3 — Link AWS billing to Red Hat" \
    "This is NOT automated. Screenshots: INSTALL.md Step 0.5

If skipped, create fails with:
  billing account not linked to organization at the aws marketplace

1. Bottom of ROSA Get Started → Continue to Red Hat
2. On Complete your account connection: confirm AWS account ID == ${STS_ACCOUNT}
3. Accept terms → Connect accounts

Guide + images: INSTALL.md Step 0.5"

  echo
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "MANUAL GATE 3/3 — OCM offline token"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "Get the token in the browser, then paste here — same pattern as AWS Access Key."
  echo
  preflight_ensure_ocm_token
  preflight_verify_ocm "$STS_ACCOUNT"
  preflight_ensure_ocm_role
  ok "Preflight passed"
}

# ─── inputs ──────────────────────────────────────────────────────────
step_inputs() {
  log "Step inputs — cluster settings"
  echo "Defaults: public Tokyo ROSA HCP 4.22. See INSTALL.md Step 1.2."
  echo
  ensure_dependency_repos phase1
  if [[ -f "$CLUSTER_ENV" ]]; then
    # shellcheck source=/dev/null
    set -a; source "$CLUSTER_ENV"; set +a
  fi
  export AWS_PROFILE="${AWS_PROFILE:-$DEFAULT_AWS_PROFILE}"

  prompt CLUSTER_NAME "Cluster name (lowercase, unique)" "${CLUSTER_NAME:-}"
  [[ "$CLUSTER_NAME" =~ ^[a-z0-9]([a-z0-9-]{0,13}[a-z0-9])?$ ]] || die "Invalid cluster name '${CLUSTER_NAME}'."

  prompt REGION "Region" "${AWS_REGION:-$DEFAULT_REGION}"
  prompt OPENSHIFT_VERSION "OpenShift version" "${OPENSHIFT_VERSION:-$DEFAULT_OPENSHIFT_VERSION}"
  [[ "$OPENSHIFT_VERSION" =~ ^4\.22\. ]] || die "Version must be 4.22.x (got '${OPENSHIFT_VERSION}')."

  prompt NETWORK_TYPE "Cluster type (public only in v1)" "${DEFAULT_NETWORK_TYPE}"
  [[ "$NETWORK_TYPE" == "public" ]] || die "v1 supports public only."

  prompt AWS_PROFILE "AWS profile" "${AWS_PROFILE:-$DEFAULT_AWS_PROFILE}"
  prompt MULTI_AZ "Multi-AZ VPC/subnets (yes/no)" "$([[ "${DEFAULT_MULTI_AZ}" == "true" ]] && echo yes || echo no)"
  MULTI_AZ_BOOL=true
  [[ "$MULTI_AZ" =~ ^[Yy] ]] || MULTI_AZ_BOOL=false
  prompt INSTANCE_TYPE "Default worker instance type" "${DEFAULT_INSTANCE_TYPE}"
  if [[ "$MULTI_AZ_BOOL" == "true" ]]; then
    echo "(Multi-AZ: min/max replicas are per availability zone, not cluster totals.)"
  fi
  prompt MIN_REPLICAS "Default worker replicas (min)" "${DEFAULT_MIN_REPLICAS}"
  prompt MAX_REPLICAS "Default worker replicas (max)" "${DEFAULT_MAX_REPLICAS}"
  prompt VPC_CIDR "VPC CIDR" "${DEFAULT_VPC_CIDR}"
  prompt ENABLE_AUTONODE "Enable AutoNode (yes/no)" "yes"
  ENABLE_AUTONODE_BOOL=true
  [[ "$ENABLE_AUTONODE" =~ ^[Yy] ]] || ENABLE_AUTONODE_BOOL=false

  CLUSTER_DIR="${VALIDATED_PATTERN_DIR}/clusters/${CLUSTER_NAME}"
  if [[ -d "$CLUSTER_DIR" && "$FORCE" != "true" ]]; then
    die "Cluster dir already exists: ${CLUSTER_DIR}
Refuse to overwrite. Pick another name, or re-run with --force."
  fi

  mkdir -p "$CLUSTER_DIR"
  TFVARS="${CLUSTER_DIR}/terraform.tfvars"
  TMPL="${INSTALLER_ROOT}/templates/terraform.tfvars.tmpl"
  [[ -f "$TMPL" ]] || die "Missing template $TMPL"

  sed \
    -e "s|__CLUSTER_NAME__|${CLUSTER_NAME}|g" \
    -e "s|__OPENSHIFT_VERSION__|${OPENSHIFT_VERSION}|g" \
    -e "s|__REGION__|${REGION}|g" \
    -e "s|__VPC_CIDR__|${VPC_CIDR}|g" \
    -e "s|__MULTI_AZ__|${MULTI_AZ_BOOL}|g" \
    -e "s|__INSTANCE_TYPE__|${INSTANCE_TYPE}|g" \
    -e "s|__MIN_REPLICAS__|${MIN_REPLICAS}|g" \
    -e "s|__MAX_REPLICAS__|${MAX_REPLICAS}|g" \
    "$TMPL" >"$TFVARS"

  if [[ "$ENABLE_AUTONODE_BOOL" != "true" ]]; then
    sed -i.bak 's/enable_autonode = true/enable_autonode = false/' "$TFVARS" && rm -f "${TFVARS}.bak"
  fi

  cat >"$CLUSTER_ENV" <<EOF
CLUSTER_NAME="${CLUSTER_NAME}"
AWS_PROFILE="${AWS_PROFILE}"
AWS_REGION="${REGION}"
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-}"
OPENSHIFT_VERSION="${OPENSHIFT_VERSION}"
NETWORK_TYPE="${NETWORK_TYPE}"
MULTI_AZ="${MULTI_AZ_BOOL}"
INSTANCE_TYPE="${INSTANCE_TYPE}"
MIN_REPLICAS="${MIN_REPLICAS}"
MAX_REPLICAS="${MAX_REPLICAS}"
VPC_CIDR="${VPC_CIDR}"
ENABLE_AUTONODE="${ENABLE_AUTONODE_BOOL}"
VALIDATED_PATTERN_DIR="${VALIDATED_PATTERN_DIR}"
CLUSTER_DIR="${CLUSTER_DIR}"
TFVARS_PATH="${TFVARS}"
EOF
  ok "Wrote ${CLUSTER_ENV}"
  ok "Wrote ${TFVARS}"
}

# ─── provision ───────────────────────────────────────────────────────
step_provision() {
  load_cluster_env
  export AWS_PROFILE
  ensure_aws_profile
  ensure_ocm_token
  export RHCS_TOKEN
  rosa_login

  ensure_dependency_repos phase1
  [[ -f "${TFVARS_PATH:-}" ]] || die "Missing terraform.tfvars — re-run with --from=inputs"
  [[ -d "${CLUSTER_DIR:-}" ]] || die "Missing cluster dir ${CLUSTER_DIR:-} — re-run with --from=inputs"

  LOG="${LOG_DIR}/provision-${CLUSTER_NAME}-$(timestamp).log"
  log "Step provision — ROSA HCP '${CLUSTER_NAME}' (~35–50 min after apply)"
  echo "Using Terraform pattern: $VALIDATED_PATTERN_DIR"
  echo "Logs: $LOG"

  cd "$VALIDATED_PATTERN_DIR"
  # Must run from validated-pattern-terraform-rosa root (defines cluster.<name>.init)
  log "make cluster.${CLUSTER_NAME}.init  (cwd=$(pwd))"
  run_logged "$LOG" make "cluster.${CLUSTER_NAME}.init"
  log "make cluster.${CLUSTER_NAME}.plan"
  run_logged "$LOG" make "cluster.${CLUSTER_NAME}.plan"

  # Costly / irreversible: require confirm unless --plan-only
  if [[ "$PLAN_ONLY" == "true" ]]; then
    ok "Plan-only mode — stopping before apply. Re-run without --plan-only to create the cluster."
    echo "Undo/local: remove ${CLUSTER_DIR} if you discard this draft (terraform not applied)."
    return 0
  fi

  echo
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "Terraform plan finished. Creating the cluster costs money."
  echo "Undo later: cd ${VALIDATED_PATTERN_DIR} && make cluster.${CLUSTER_NAME}.destroy"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  confirm_yes "Apply terraform and create cluster '${CLUSTER_NAME}'?" || die "Apply cancelled by user."

  export AUTO_APPROVE=true
  log "make cluster.${CLUSTER_NAME}.apply"
  run_logged "$LOG" make "cluster.${CLUSTER_NAME}.apply"
  log "Fetching kubeconfig / login"
  run_logged "$LOG" make "cluster.${CLUSTER_NAME}.login" || warn "make login reported an issue — continue to verify."

  KUBE_CANDIDATE="${KUBECONFIG:-$HOME/.kube/config}"
  for p in \
    "${CLUSTER_DIR}/kubeconfig" \
    "${CLUSTER_DIR}/auth/kubeconfig" \
    "${VALIDATED_PATTERN_DIR}/clusters/${CLUSTER_NAME}/kubeconfig"; do
    [[ -f "$p" ]] && KUBE_CANDIDATE="$p" && break
  done
  save_cluster_env_kv KUBECONFIG_PATH "$KUBE_CANDIDATE"
  export KUBECONFIG="${KUBECONFIG:-$KUBE_CANDIDATE}"

  # AutoNode may be enabled in TF but CRDs can lag — try rosa edit as fallback
  if command -v oc >/dev/null 2>&1 && [[ -f "${KUBECONFIG}" ]]; then
    if ! oc get crd ec2nodeclasses.karpenter.k8s.aws >/dev/null 2>&1; then
      warn "Karpenter EC2NodeClass CRD missing — attempting rosa edit --autonode enabled"
      ROLE_ARN="$(rosa describe cluster -c "$CLUSTER_NAME" -o json 2>/dev/null | jq -r '.aws.auto_node.iam_role_arn // .aws.sts.auto_node.role_arn // empty' || true)"
      if [[ -n "${ROLE_ARN}" && "$ROLE_ARN" == arn:* ]]; then
        rosa edit cluster -c "$CLUSTER_NAME" --autonode=enabled --autonode-iam-role-arn="$ROLE_ARN" | tee -a "$LOG" || warn "rosa edit autonode failed"
      else
        warn "Enable AutoNode manually: rosa edit cluster -c ${CLUSTER_NAME} --autonode=enabled --autonode-iam-role-arn=<role-arn>"
      fi
    else
      ok "Karpenter CRDs present"
    fi
  fi
  ok "Provision finished"
}

# ─── verify + print access ───────────────────────────────────────────
step_verify() {
  load_cluster_env
  export AWS_PROFILE
  ensure_aws_profile
  ensure_ocm_token
  export RHCS_TOKEN
  rosa_login
  require_cmd oc
  require_cmd jq

  log "Step verify — cluster '${CLUSTER_NAME}'"
  STATE="$(rosa describe cluster -c "$CLUSTER_NAME" -o json 2>/dev/null | jq -r '.state // empty' || true)"
  if [[ -z "$STATE" ]]; then
    rosa describe cluster -c "$CLUSTER_NAME" || true
    STATE="$(rosa describe cluster -c "$CLUSTER_NAME" 2>&1 | awk -F: '/^State/{print $2}' | xargs || true)"
  fi
  [[ "$STATE" == "ready" ]] || die "Cluster state is '${STATE:-unknown}', expected ready."
  ok "Cluster state: ready"

  API="$(rosa describe cluster -c "$CLUSTER_NAME" -o json 2>/dev/null | jq -r '.api.url // empty' || true)"
  CONSOLE="$(rosa describe cluster -c "$CLUSTER_NAME" -o json 2>/dev/null | jq -r '.console.url // empty' || true)"

  export KUBECONFIG="${KUBECONFIG:-${KUBECONFIG_PATH:-}}"
  if [[ -z "${KUBECONFIG}" || ! -f "${KUBECONFIG}" ]]; then
    (cd "$VALIDATED_PATTERN_DIR" && make "cluster.${CLUSTER_NAME}.login") || true
    export KUBECONFIG="${KUBECONFIG:-${KUBECONFIG_PATH:-$HOME/.kube/config}}"
  fi

  log "Worker nodes"
  oc get nodes -o wide || die "oc get nodes failed — fix kubeconfig (make cluster.${CLUSTER_NAME}.login)."
  NOT_READY="$(oc get nodes --no-headers 2>/dev/null | awk '$2 != "Ready" {print}' || true)"
  [[ -z "$NOT_READY" ]] || warn "Some nodes not Ready yet:\n${NOT_READY}"

  log "AutoNode / Karpenter"
  if oc get crd 2>/dev/null | grep -qi karpenter; then
    ok "Karpenter CRDs found"
    oc get ec2nodeclass 2>/dev/null || oc get ec2nodeclasses.karpenter.k8s.aws 2>/dev/null || true
  else
    warn "No karpenter CRDs. See INSTALL.md troubleshooting."
  fi

  # --- Login credentials (always print at end of Phase 1) ---
  # Avoid nested ${var:-...${nested}...} and date -I* (fragile on macOS bash 3.2).
  log "Collecting ROSA access details (URLs + admin credentials)"
  ADMIN_USER="admin"
  ADMIN_PASSWORD=""

  SECRET_ID="${CLUSTER_NAME}-credentials"
  SECRET_JSON="$(aws secretsmanager get-secret-value --secret-id "$SECRET_ID" --query SecretString --output text 2>/dev/null || true)"
  if [[ -n "$SECRET_JSON" ]]; then
    ADMIN_USER="$(printf '%s' "$SECRET_JSON" | jq -r '.user // .username // "admin"')"
    ADMIN_PASSWORD="$(printf '%s' "$SECRET_JSON" | jq -r '.password // empty')"
    if [[ -z "$API" || "$API" == "null" ]]; then
      API="$(printf '%s' "$SECRET_JSON" | jq -r '.url // empty')"
    fi
  fi

  # Fallback: validated-pattern make target (may print to terminal as well)
  if [[ -z "$ADMIN_PASSWORD" && -d "$VALIDATED_PATTERN_DIR" ]]; then
    (cd "$VALIDATED_PATTERN_DIR" && make "cluster.${CLUSTER_NAME}.show-credentials") 2>/dev/null || true
  fi

  if [[ -z "$API" || "$API" == "null" ]]; then
    API="$(rosa describe cluster -c "$CLUSTER_NAME" -o json 2>/dev/null | jq -r '.api.url // empty' || true)"
  fi
  if [[ -z "$CONSOLE" || "$CONSOLE" == "null" ]]; then
    CONSOLE="$(rosa describe cluster -c "$CLUSTER_NAME" -o json 2>/dev/null | jq -r '.console.url // empty' || true)"
  fi

  ACCESS_FILE="${STATE_DIR}/access-${CLUSTER_NAME}.txt"
  GENERATED_AT="$(date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || date)"
  umask 077
  {
    echo "ROSA cluster access - ${CLUSTER_NAME}"
    echo "Generated: ${GENERATED_AT}"
    echo
    echo "Console:  ${CONSOLE:-unknown}"
    echo "API:      ${API:-unknown}"
    echo "Username: ${ADMIN_USER}"
    if [[ -n "$ADMIN_PASSWORD" ]]; then
      printf 'Password: %s\n' "$ADMIN_PASSWORD"
    else
      echo "Password: <unavailable - run: make cluster.${CLUSTER_NAME}.show-credentials>"
    fi
    echo
    echo "oc login:"
    echo "  cd ${VALIDATED_PATTERN_DIR} && make cluster.${CLUSTER_NAME}.login"
    echo
    echo "Re-print anytime:"
    echo "  cat ${ACCESS_FILE}"
    echo "  aws secretsmanager get-secret-value --secret-id ${CLUSTER_NAME}-credentials --query SecretString --output text"
  } >"$ACCESS_FILE"
  chmod 600 "$ACCESS_FILE"
  save_cluster_env_kv ACCESS_FILE "$ACCESS_FILE"
  save_cluster_env_kv CONSOLE_URL "${CONSOLE:-}"
  save_cluster_env_kv API_URL "${API:-}"
  save_cluster_env_kv ADMIN_USER "$ADMIN_USER"

  echo
  echo "===================================================="
  echo " Phase 1 complete - ROSA login credentials"
  echo "===================================================="
  echo
  echo "  Cluster:  ${CLUSTER_NAME}"
  echo "  Console:  ${CONSOLE:-unknown}"
  echo "  API:      ${API:-unknown}"
  echo "  Username: ${ADMIN_USER}"
  if [[ -n "$ADMIN_PASSWORD" ]]; then
    printf '  Password: %s\n' "$ADMIN_PASSWORD"
  else
    echo "  Password: <not retrieved>"
    echo "            aws secretsmanager get-secret-value --secret-id ${CLUSTER_NAME}-credentials --query SecretString --output text"
    echo "            or: cd ${VALIDATED_PATTERN_DIR} && make cluster.${CLUSTER_NAME}.show-credentials"
  fi
  echo "  Kubeconfig: ${KUBECONFIG:-unknown}"
  echo "  Saved copy: ${ACCESS_FILE}  (mode 600, gitignored)"
  echo
  echo "===================================================="
  echo "Open the Console URL and log in with Username / Password above."
  ok "Phase 1 verify passed"
}

# ─── main ────────────────────────────────────────────────────────────
log "Phase 1 — ROSA HCP installer"
echo "Guide: INSTALL.md | Resume: --from=tools|aws|preflight|inputs|provision|verify"

should_run tools && step_tools
if [[ "$TOOLS_ONLY" == "true" ]]; then
  ok "Tools-only done."
  exit 0
fi
should_run aws && step_aws
should_run preflight && step_preflight
should_run inputs && step_inputs
should_run provision && step_provision
if [[ "$PLAN_ONLY" == "true" ]]; then
  ok "Phase 1 stopped after plan (--plan-only). No verify."
  exit 0
fi
should_run verify && step_verify

ok "Phase 1 finished"
