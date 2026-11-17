#!/usr/bin/env bash
# Phase 2 — OpenShift AI 3.5 platform-ready (no model smoke)
#
# Usage:
#   ./phase2/install_rhoai.sh
#   ./phase2/install_rhoai.sh --from=sno
#   ./phase2/install_rhoai.sh --help
#
# Steps: nodepools → nfd_gpu → rhods → sno → hardware → verify
# NodePools are created first so Pending AI pods can scale Karpenter CPU nodes.
# Default ROSA workers stay multi-AZ m6a.xlarge floor; AI capacity is on-demand Karpenter.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../lib/common.sh"

FROM="nodepools"
for a in "$@"; do
  case "$a" in
    --from=*) FROM="${a#--from=}" ;;
    --from) die "Use --from=STEP (nodepools|nfd_gpu|rhods|sno|hardware|verify)" ;;
    -h|--help)
      sed -n '2,14p' "$0"
      exit 0
      ;;
  esac
done

step_rank() {
  case "$1" in
    nodepools) echo 1 ;;
    nfd_gpu) echo 2 ;;
    rhods) echo 3 ;;
    sno) echo 4 ;;
    hardware) echo 5 ;;
    verify) echo 6 ;;
    *) echo 0 ;;
  esac
}
FROM_N="$(step_rank "$FROM")"
[[ "$FROM_N" -gt 0 ]] || die "Unknown --from=$FROM"
should_run() { [[ "$(step_rank "$1")" -ge "$FROM_N" ]]; }

prepare_kube() {
  if [[ -f "$CLUSTER_ENV" ]]; then
    # shellcheck source=/dev/null
    set -a; source "$CLUSTER_ENV"; set +a
  fi
  export AWS_PROFILE="${AWS_PROFILE:-$DEFAULT_AWS_PROFILE}"
  export KUBECONFIG="${KUBECONFIG:-${KUBECONFIG_PATH:-$HOME/.kube/config}}"
  require_cmd oc
  oc whoami >/dev/null 2>&1 || die "oc cannot reach the cluster. Set KUBECONFIG or re-run Phase 1 verify/login. See INSTALL.md."
  ok "oc identity: $(oc whoami 2>/dev/null) | KUBECONFIG=${KUBECONFIG}"
}

wait_csv_succeeded() {
  # wait_csv_succeeded <namespace> <grep-pattern> <max-attempts> <sleep-sec>
  local ns="$1" pat="$2" max="${3:-60}" sleep_s="${4:-15}"
  local i
  for i in $(seq 1 "$max"); do
    if oc get csv -n "$ns" --no-headers 2>/dev/null | grep -E "$pat" | grep -qi Succeeded; then
      return 0
    fi
    sleep "$sleep_s"
  done
  return 1
}

# ─── nodepools (BEFORE heavy AI install) ─────────────────────────────
step_nodepools() {
  log "Step nodepools — Karpenter CPU + GPU on-demand (Phase 2 only)"
  echo "Risk: without these, the m6a.xlarge platform floor often hits Insufficient cpu during RHOAI install."
  echo "Undo: oc delete nodepool rhoai-cpu-ondemand rhoai-gpu-ondemand"

  if ! oc get crd nodepools.karpenter.sh >/dev/null 2>&1 && ! oc get crd nodepools.karpenter.k8s.aws >/dev/null 2>&1; then
    # ROSA AutoNode uses karpenter.sh/v1 NodePool
    if ! oc api-resources 2>/dev/null | grep -qi nodepool; then
      warn "NodePool API not found — AutoNode may be disabled."
      echo "Enable AutoNode, then re-run with --from=nodepools, or scale workers as fallback."
      if [[ -n "${CLUSTER_NAME:-}" ]] && confirm_yes "Scale ROSA workers machinepool to 4 as fallback now?"; then
        require_cmd rosa
        ensure_aws_profile
        rosa edit machinepool -c "$CLUSTER_NAME" workers --replicas=4 \
          || rosa edit machinepool workers -c "$CLUSTER_NAME" --replicas=4 \
          || warn "rosa edit machinepool failed"
      fi
      return 0
    fi
  fi

  local cpu_out gpu_out
  cpu_out="${STATE_DIR}/nodepool-cpu-${CLUSTER_NAME:-cluster}.yaml"
  gpu_out="${STATE_DIR}/nodepool-gpu-${CLUSTER_NAME:-cluster}.yaml"
  cp "${INSTALLER_ROOT}/templates/nodepool-cpu.yaml.tmpl" "$cpu_out"
  cp "${INSTALLER_ROOT}/templates/nodepool-gpu.yaml.tmpl" "$gpu_out"
  oc apply -f "$cpu_out"
  oc apply -f "$gpu_out"
  oc get nodepool 2>/dev/null || oc get nodepools.karpenter.sh 2>/dev/null || true
  ok "CPU + GPU on-demand NodePools applied"
}

# ─── NFD + GPU Operator ──────────────────────────────────────────────
step_nfd_gpu() {
  log "Step nfd_gpu — Node Feature Discovery + NVIDIA GPU Operator"
  echo "Note: GPU driver DaemonSets become Ready only after a GPU node exists."

  oc apply -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-nfd
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-nfd
  namespace: openshift-nfd
spec:
  targetNamespaces:
    - openshift-nfd
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: nfd
  namespace: openshift-nfd
spec:
  channel: stable
  installPlanApproval: Automatic
  name: nfd
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

  wait_csv_succeeded openshift-nfd 'nfd' 60 15 && ok "NFD CSV Succeeded" || warn "NFD CSV not Succeeded yet — continuing"

  oc apply -f - <<'EOF'
apiVersion: nfd.openshift.io/v1
kind: NodeFeatureDiscovery
metadata:
  name: nfd-instance
  namespace: openshift-nfd
spec:
  operand:
    servicePort: 12000
  workerConfig:
    configData: |
      core:
        sleepInterval: 60s
EOF

  oc apply -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: nvidia-gpu-operator
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: nvidia-gpu-operator
  namespace: nvidia-gpu-operator
spec:
  targetNamespaces:
    - nvidia-gpu-operator
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: gpu-operator-certified
  namespace: nvidia-gpu-operator
spec:
  channel: stable
  installPlanApproval: Automatic
  name: gpu-operator-certified
  source: certified-operators
  sourceNamespace: openshift-marketplace
EOF

  local i
  for i in $(seq 1 80); do
    oc get crd clusterpolicies.nvidia.com >/dev/null 2>&1 && break
    sleep 15
    [[ $i -eq 80 ]] && die "Timed out waiting for clusterpolicies.nvidia.com CRD"
  done
  ok "NVIDIA ClusterPolicy CRD present"
  wait_csv_succeeded nvidia-gpu-operator 'gpu-operator' 60 15 && ok "GPU Operator CSV Succeeded" || warn "GPU Operator CSV not Succeeded yet"

  # daemonsets: {} required — do not omit
  oc apply -f - <<'EOF'
apiVersion: nvidia.com/v1
kind: ClusterPolicy
metadata:
  name: gpu-cluster-policy
spec:
  daemonsets: {}
  operator:
    defaultRuntime: crio
    use_ocp_driver_toolkit: true
  driver:
    enabled: true
  toolkit:
    enabled: true
  devicePlugin:
    enabled: true
  dcgm:
    enabled: true
  dcgmExporter:
    enabled: true
  gfd:
    enabled: true
  nodeStatusExporter:
    enabled: true
  migManager:
    enabled: true
  validator:
    plugin:
      env:
        - name: WITH_WORKLOAD
          value: "false"
EOF
  ok "NFD + GPU Operator + ClusterPolicy applied"
}

# ─── RHODS operator + DSC ────────────────────────────────────────────
step_rhods() {
  log "Step rhods — OpenShift AI operator channel ${RHOAI_CHANNEL}"

  oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: redhat-ods-operator
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: rhods-operator
  namespace: redhat-ods-operator
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: rhods-operator
  namespace: redhat-ods-operator
spec:
  channel: ${RHOAI_CHANNEL}
  installPlanApproval: Automatic
  name: rhods-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

  wait_csv_succeeded redhat-ods-operator 'rhods' 90 20 || die "Timed out waiting for RHODS CSV on ${RHOAI_CHANNEL}"
  ok "RHODS CSV Succeeded"
  oc get csv -n redhat-ods-operator

  log "Waiting for default-dsci / default-dsc…"
  local i
  for i in $(seq 1 36); do
    oc get dscinitialization default-dsci >/dev/null 2>&1 && break
    sleep 10
  done
  oc get dscinitialization default-dsci >/dev/null 2>&1 && ok "default-dsci present" || warn "default-dsci missing — operator still reconciling"

  if ! oc get datasciencecluster default-dsc >/dev/null 2>&1; then
    log "Applying baseline default-dsc from templates/"
    oc apply -f "${INSTALLER_ROOT}/templates/datasciencecluster-baseline.yaml" \
      || warn "Baseline DSC apply failed — sno-enable may still patch once DSC exists"
  else
    ok "default-dsc already exists"
  fi

  # Worker pressure guard (Karpenter should absorb; machinepool is fallback)
  local pending
  pending="$(oc get pods -A --field-selector=status.phase=Pending --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "${pending:-0}" -ge 8 ]]; then
    warn "Detected ${pending} Pending pods — waiting briefly for Karpenter CPU NodePool…"
    sleep 60
    pending="$(oc get pods -A --field-selector=status.phase=Pending --no-headers 2>/dev/null | wc -l | tr -d ' ')"
    if [[ "${pending:-0}" -ge 8 && -n "${CLUSTER_NAME:-}" ]]; then
      if confirm_yes "Still ${pending} Pending — scale ROSA workers to 4 as fallback?"; then
        require_cmd rosa
        ensure_aws_profile
        rosa edit machinepool -c "$CLUSTER_NAME" workers --replicas=4 \
          || rosa edit machinepool workers -c "$CLUSTER_NAME" --replicas=4 \
          || warn "rosa edit machinepool failed — see INSTALL.md"
      fi
    fi
  fi
  ok "RHODS / DSC baseline step done"
}

# ─── sno-enable + MaaS ───────────────────────────────────────────────
step_sno() {
  log "Step sno — enable features + MaaS helpers"
  echo "Calls upstream scripts (not vendored). Undo is best-effort (destroy cluster for clean slate)."

  [[ -d "$SNO_GUIDE_DIR" ]] || die "Missing SNO guide dir: $SNO_GUIDE_DIR"
  local enable_sh="${SNO_GUIDE_DIR}/scripts/sno-enable-all-features-35.sh"
  local maas_sh="${SNO_GUIDE_DIR}/scripts/sno-setup-maas-35.sh"
  [[ -f "$enable_sh" ]] || die "Missing $enable_sh"
  [[ -f "$maas_sh" ]] || die "Missing $maas_sh"

  # DSC must exist for sno-enable
  if ! oc get datasciencecluster default-dsc >/dev/null 2>&1; then
    die "default-dsc not found. Re-run with --from=rhods or create DSC manually."
  fi

  local logf="${LOG_DIR}/sno-enable-$(timestamp).log"
  log "Running sno-enable-all-features-35.sh (log: $logf)"
  bash "$enable_sh" 2>&1 | tee "$logf"

  logf="${LOG_DIR}/sno-maas-$(timestamp).log"
  log "Running sno-setup-maas-35.sh (log: $logf)"
  bash "$maas_sh" 2>&1 | tee "$logf"

  ok "SNO enable + MaaS scripts finished"
}

# ─── HardwareProfile ─────────────────────────────────────────────────
step_hardware() {
  log "Step hardware — GPU HardwareProfile"
  local hp="${TOOLKIT_DIR}/lib/manifests/rhoai/hardware-profile-gpu.yaml"
  [[ -f "$hp" ]] || die "Missing $hp"
  oc apply -f "$hp"
  ok "HardwareProfile applied from RHOAI-Toolkit"
}

# ─── verify platform-ready ───────────────────────────────────────────
step_verify() {
  log "Step verify — platform-ready checklist (no model smoke)"
  local fail=0

  echo "--- RHODS CSV ---"
  oc get csv -n redhat-ods-operator || fail=1

  echo "--- DataScienceCluster ---"
  if oc get datasciencecluster default-dsc >/dev/null 2>&1; then
    oc get datasciencecluster default-dsc -o wide || true
    oc get datasciencecluster default-dsc -o jsonpath='{range .status.conditions[*]}{.type}{"="}{.status}{"\n"}{end}' 2>/dev/null || true
  else
    warn "default-dsc missing"; fail=1
  fi

  echo "--- MaaS / maas-api ---"
  oc get deploy -A 2>/dev/null | grep -i maas || warn "maas-api deploy not found yet"
  oc get deploy -n maas-api maas-api >/dev/null 2>&1 \
    || oc get deploy -n redhat-ods-applications -l app=maas-api >/dev/null 2>&1 \
    || warn "Could not confirm maas-api Available"

  echo "--- Dashboard route ---"
  local dash
  dash="$(oc get route -n redhat-ods-applications -o jsonpath='{.items[0].spec.host}' 2>/dev/null || true)"
  if [[ -n "$dash" ]]; then
    ok "Dashboard host: https://${dash}"
  else
    warn "Dashboard route not found in redhat-ods-applications"
  fi

  echo "--- NodePools ---"
  oc get nodepool 2>/dev/null || oc get nodepools.karpenter.sh 2>/dev/null || warn "No NodePools listed"

  echo
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo " Phase 2 complete — OpenShift AI platform-ready"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  Channel:     ${RHOAI_CHANNEL}"
  echo "  Dashboard:   ${dash:+https://$dash}"
  echo "  NodePools:   rhoai-cpu-ondemand + rhoai-gpu-ondemand (on-demand)"
  echo "  Out of scope: model deploy, Playground, inference curl"
  echo
  echo "Undo / teardown:"
  echo "  cd ${VALIDATED_PATTERN_DIR} && make cluster.\${CLUSTER_NAME}.destroy"
  echo "  (Phase 2 operator uninstall is best-effort; destroy is the clean rollback.)"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  [[ "$fail" -eq 0 ]] || warn "Some checks incomplete — review warnings above."
  ok "Phase 2 verify finished"
}

# ─── main ────────────────────────────────────────────────────────────
log "Phase 2 — OpenShift AI 3.5 platform-ready"
echo "Guide: INSTALL.md | Resume: --from=nodepools|nfd_gpu|rhods|sno|hardware|verify"
prepare_kube
ensure_dependency_repos phase2

should_run nodepools && step_nodepools
should_run nfd_gpu && step_nfd_gpu
should_run rhods && step_rhods
should_run sno && step_sno
should_run hardware && step_hardware
should_run verify && step_verify

ok "Phase 2 finished"
