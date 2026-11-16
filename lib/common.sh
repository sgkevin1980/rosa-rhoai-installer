#!/usr/bin/env bash
# Shared helpers for rosa-rhoai-installer

set -euo pipefail

INSTALLER_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "${INSTALLER_ROOT}/lib/defaults.env"

STATE_DIR="${INSTALLER_ROOT}/state"
LOG_DIR="${STATE_DIR}/logs"
CLUSTER_ENV="${STATE_DIR}/cluster.env"

mkdir -p "${LOG_DIR}"

# --- logging ---
log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ok]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

require_macos() {
  [[ "$(uname -s)" == "Darwin" ]] || die "This installer supports macOS only. See INSTALL.md."
}

require_cmd() {
  local c="$1"
  command -v "$c" >/dev/null 2>&1 || die "Required command not found: $c. Run: ./phase1/install_rosa.sh --tools-only (INSTALL.md Step 0.2)."
}

prompt() {
  # usage: prompt VAR "Question" "default"
  local __var="$1" __q="$2" __def="${3:-}" __ans
  if [[ -n "$__def" ]]; then
    read -r -p "$__q [$__def]: " __ans || true
    __ans="${__ans:-$__def}"
  else
    while true; do
      read -r -p "$__q: " __ans || true
      [[ -n "$__ans" ]] && break
      echo "  (required)"
    done
  fi
  printf -v "$__var" '%s' "$__ans"
}

prompt_secret() {
  local __var="$1" __q="$2" __ans
  read -r -s -p "$__q: " __ans || true
  echo
  [[ -n "$__ans" ]] || die "Secret value is required."
  printf -v "$__var" '%s' "$__ans"
}

confirm_yes() {
  # returns 0 if yes
  local __q="$1" __def="${2:-n}" __ans
  read -r -p "$__q [y/N]: " __ans || true
  __ans="${__ans:-$__def}"
  [[ "$__ans" =~ ^[Yy]([Ee][Ss])?$ ]]
}

confirm_gate() {
  # Hard gate: user must type yes
  local __title="$1" __body="$2"
  echo
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "$__title"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "$__body"
  echo
  local __ans
  read -r -p "Type YES to confirm you completed this (or Ctrl-C to stop): " __ans || true
  [[ "$__ans" == "YES" ]] || die "Stopped at gate: $__title. Complete the steps in INSTALL.md, then re-run."
}

load_cluster_env() {
  [[ -f "$CLUSTER_ENV" ]] || die "Missing $CLUSTER_ENV. Run Phase 1 input collection first (INSTALL.md)."
  # shellcheck source=/dev/null
  set -a
  source "$CLUSTER_ENV"
  set +a
}

save_cluster_env_kv() {
  # append/update KEY=VALUE in cluster.env
  local key="$1" val="$2" tmp
  mkdir -p "$STATE_DIR"
  touch "$CLUSTER_ENV"
  tmp="$(mktemp)"
  grep -v "^${key}=" "$CLUSTER_ENV" >"$tmp" || true
  printf '%s=%q\n' "$key" "$val" >>"$tmp"
  # Use plain KEY=value for shell sourcing (val already safe for our fields)
  grep -v "^${key}=" "$CLUSTER_ENV" >"$tmp" 2>/dev/null || true
  printf '%s="%s"\n' "$key" "$val" >>"$tmp"
  mv "$tmp" "$CLUSTER_ENV"
}

ensure_aws_profile() {
  export AWS_PROFILE="${AWS_PROFILE:-$DEFAULT_AWS_PROFILE}"
  require_cmd aws
  if ! aws sts get-caller-identity >/dev/null 2>&1; then
    die "AWS credentials failed for AWS_PROFILE=${AWS_PROFILE}. Run phase1/01b_configure_aws.sh (INSTALL.md Step 0.3)."
  fi
  ok "AWS identity OK (profile=${AWS_PROFILE})"
}

aws_account_id() {
  aws sts get-caller-identity --query Account --output text
}

ensure_ocm_token() {
  if [[ -z "${RHCS_TOKEN:-}" ]]; then
    [[ -f "$OCM_TOKEN_FILE" ]] || die "Missing OCM token at $OCM_TOKEN_FILE. See INSTALL.md Step 0.6."
    export RHCS_TOKEN
    RHCS_TOKEN="$(tr -d '[:space:]' <"$OCM_TOKEN_FILE")"
  fi
  [[ -n "$RHCS_TOKEN" ]] || die "OCM token is empty."
}

rosa_login() {
  require_cmd rosa
  ensure_ocm_token
  rosa login --token="$RHCS_TOKEN" >/dev/null
  ok "rosa login OK"
}

timestamp() { date +%Y%m%d-%H%M%S; }

run_logged() {
  local logfile="$1"; shift
  mkdir -p "$(dirname "$logfile")"
  echo "---- $(date -Iseconds) ----" >>"$logfile"
  echo "+ $*" >>"$logfile"
  "$@" 2>&1 | tee -a "$logfile"
}
