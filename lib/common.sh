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

_dir_is_effectively_empty() {
  local d="$1" n
  [[ -d "$d" ]] || return 1
  n="$(find "$d" -mindepth 1 -maxdepth 1 ! -name '.DS_Store' 2>/dev/null | wc -l | tr -d ' ')"
  [[ "$n" -eq 0 ]]
}

# Clone dest from url if missing; fix empty dirs; detect accidental nested clones.
# Optional marker_rel: relative file that must exist for the checkout to be valid.
# Optional ref: branch/tag to clone (default: remote HEAD / main).
# Human messages go to stderr; stdout is ONLY the resolved path (for capture).
ensure_git_clone() {
  local dest="$1" url="$2" marker_rel="${3:-}" ref="${4:-}"
  local nest marker nested_marker clone_args

  require_cmd git
  mkdir -p "$(dirname "$dest")"

  marker=""
  nested_marker=""
  if [[ -n "$marker_rel" ]]; then
    marker="${dest}/${marker_rel}"
    nest="${dest}/$(basename "$dest")"
    nested_marker="${nest}/${marker_rel}"
  fi

  # Accidental: git clone url into an already-named empty/parent folder → nested tree
  if [[ -n "$nested_marker" && -f "$nested_marker" && ! -f "$marker" ]]; then
    warn "Found nested clone at ${nest} — using it (common if clone landed inside an empty folder)." >&2
    printf '%s\n' "$nest"
    return 0
  fi

  if [[ -n "$marker_rel" && -f "$marker" ]]; then
    ok "Dependency present: $dest" >&2
    printf '%s\n' "$dest"
    return 0
  fi
  if [[ -z "$marker_rel" && -d "$dest/.git" ]]; then
    ok "Dependency present: $dest" >&2
    printf '%s\n' "$dest"
    return 0
  fi

  if [[ -d "$dest" ]]; then
    if _dir_is_effectively_empty "$dest"; then
      warn "Removing empty placeholder: $dest" >&2
      rmdir "$dest" 2>/dev/null || rm -rf "$dest"
    else
      die "Directory exists but looks incomplete: $dest
Expected marker: ${marker_rel:-.git}
Fix: move/rename that folder, then re-run (installer will clone ${url}).
Or set the matching *_DIR env var to a valid checkout."
    fi
  fi

  log "Cloning dependency → $dest" >&2
  echo "  from $url${ref:+ (ref $ref)}" >&2
  clone_args=(clone --depth 1)
  [[ -n "$ref" ]] && clone_args+=(--branch "$ref")
  clone_args+=("$url" "$dest")
  git "${clone_args[@]}" >&2
  if [[ -n "$marker_rel" && ! -f "${dest}/${marker_rel}" ]]; then
    die "Clone succeeded but missing ${marker_rel} under $dest — wrong URL or repo layout changed."
  fi
  ok "Cloned $dest" >&2
  printf '%s\n' "$dest"
}

# Upstream rh-mobb #86 passes var.channel_group without declaring it — plan fails. Patch locally.
repair_validated_pattern_channel_group() {
  local root="${1:-$VALIDATED_PATTERN_DIR}"
  local main_tf="${root}/terraform/10-main.tf"
  local vars_tf="${root}/terraform/01-variables.tf"

  [[ -f "$main_tf" && -f "$vars_tf" ]] || return 0
  grep -q 'var\.channel_group' "$main_tf" || return 0
  if grep -q 'variable[[:space:]]*"channel_group"' "$vars_tf"; then
    return 0
  fi

  warn "Patching upstream gap: declare missing variable \"channel_group\" (rh-mobb #86)." >&2
  cat >>"$vars_tf" <<'EOF'

# --- patched by rosa-rhoai-installer (upstream #86 omitted this declaration) ---
variable "channel_group" {
  description = "Channel group for OpenShift version (stable, fast, candidate, nightly)."
  type        = string
  default     = "stable"
  nullable    = false
}
EOF
  ok "Patched ${vars_tf}" >&2
}

# Ensure Phase-1/Phase-2 sibling repos exist next to rosa-rhoai-installer/
ensure_dependency_repos() {
  local need_phase2="${1:-all}" # all|phase1|phase2
  local resolved

  case "$need_phase2" in
    all|phase1|phase2) ;;
    *) die "ensure_dependency_repos: need all|phase1|phase2 (got $need_phase2)" ;;
  esac

  if [[ "$need_phase2" == "all" || "$need_phase2" == "phase1" ]]; then
    # Clone once if missing — re-pull manually: git -C "$VALIDATED_PATTERN_DIR" pull
    resolved="$(ensure_git_clone "$VALIDATED_PATTERN_DIR" "$VALIDATED_PATTERN_GIT_URL" "Makefile" "$VALIDATED_PATTERN_GIT_REF")"
    VALIDATED_PATTERN_DIR="$resolved"
    export VALIDATED_PATTERN_DIR

    if ! grep -q 'cluster\.%:' "${VALIDATED_PATTERN_DIR}/Makefile"; then
      die "Makefile in $VALIDATED_PATTERN_DIR has no cluster.% rule — wrong repo.
Clone: git clone ${VALIDATED_PATTERN_GIT_URL} ${VALIDATED_PATTERN_DIR}"
    fi
    echo "ROSA Terraform pattern: $VALIDATED_PATTERN_DIR ($(git -C "$VALIDATED_PATTERN_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown))"
    repair_validated_pattern_channel_group "$VALIDATED_PATTERN_DIR"
  fi

  if [[ "$need_phase2" == "all" || "$need_phase2" == "phase2" ]]; then
    resolved="$(ensure_git_clone "$SNO_GUIDE_DIR" "$SNO_GUIDE_GIT_URL" "scripts/sno-enable-all-features-35.sh")"
    SNO_GUIDE_DIR="$resolved"
    export SNO_GUIDE_DIR
    resolved="$(ensure_git_clone "$TOOLKIT_DIR" "$TOOLKIT_GIT_URL" "lib/manifests/rhoai/hardware-profile-gpu.yaml")"
    TOOLKIT_DIR="$resolved"
    export TOOLKIT_DIR
  fi
}
