# rosa-rhoai-installer — Spec & engineering principles

Audience: RHDP “new guy” on **macOS**. Product: guided **Phase 1 ROSA HCP 4.22 (public)** → optional **Phase 2 OpenShift AI 3.5 platform-ready**.

This document is the binding product + engineering spec for agentic implementation. `INSTALL.md` is the human runbook. Scripts must obey these principles.

---

## Product boundaries (locked)

| In | Out (v1) |
|----|----------|
| Public ROSA HCP via `validated-pattern-terraform-rosa` | Private / ZE / BYO-VPC |
| Manual browser gates: ROSA enable, billing link; OCM token **pasted like AK** into installer | Automating those console flows |
| One entry: `install.sh`; Phase scripts: `phase1/install_rosa.sh`, `phase2/install_rhoai.sh` | Many numbered step scripts as user surface |
| Phase 1 ends with Console/API URL + admin username/password | Model deploy / Playground / inference smoke |
| On-demand Karpenter NodePools (Phase 2 only) | Spot-first (RHDP SCP often denies Spot) |
| Default workers: **2× m6a.xlarge** (platform floor) | Always-on 3× m6a.2xlarge for AI headroom |

**Source of truth for cluster create/destroy:** validated-pattern `make cluster.<name>.*` — this installer is a **guided wrapper**, not a Terraform fork.

### Worker / NodePool sizing (locked)

| When | What | Why |
|------|------|-----|
| Phase 1 (always) | ROSA default machine pool **2× `m6a.xlarge`** | Cheap platform floor for control-plane agents, ingress, monitoring |
| Phase 2 (only if user installs OpenShift AI) | Karpenter **CPU on-demand** NodePool (`m6a.2xlarge`+ family, **no GPU taint**) | Absorbs RHOAI operator / MaaS / dashboard pressure via Pending → scale-from-zero |
| Phase 2 (same) | Karpenter **GPU on-demand** NodePool (taint `nvidia.com/gpu`) | GPU workloads only; stays at 0 until demand |

**Order in Phase 2 (important):** apply CPU (+ GPU) NodePools **before** heavy RHODS/MaaS install so Pending pods can trigger Karpenter. Fallback if AutoNode broken or still starved: prompt `rosa edit machinepool … --replicas=4` (or bump instance size).

**Not the default:** 3× `m6a.2xlarge` always-on — simpler install, but pays AI-sized capacity even when the user stops after Phase 1.

---

## Principles you called out

### 1. Easy rollback

Rollback is **layered**. Do not pretend one button undoes AWS + OCM + operators perfectly.

| Layer | What “rollback” means | How |
|-------|------------------------|-----|
| **Local** | Clear installer state, re-run from a step | `state/` is disposable; `--from=`; no secrets in git |
| **Phase 2** | Remove day-2 operators/CRs when feasible | Documented uninstall notes; best-effort `oc delete` helpers later — not silent |
| **Phase 1** | Destroy the ROSA cluster + pattern resources | `make cluster.<name>.destroy` (user-confirmed); document S3 leftovers |
| **Credentials** | Rotate/revoke | User deletes `~/.aws` profile / OCM token; never committed |

**Rules**

- Every irreversible step (terraform apply, destroy, scale workers) requires an explicit confirm.
- Installer must print **how to undo** after Phase 1 and Phase 2 success (teardown section).
- Prefer **resume** (`--from=`) over half-automated compensatory deletes mid-failure.
- Do **not** auto-destroy on failure (surprise cost + data loss).

**Challenge:** Full “transactional” rollback across ROSA + OperatorHub is false comfort. Spec success = *predictable teardown path*, not ACID undo.

### 2. Shell best practice

- `set -euo pipefail` in every entry script; `shellcheck`-clean (or documented exceptions).
- Quote variables; prefer `"${var}"`; no unquoted globs on user input.
- Functions for steps; `main` orchestration at bottom; no duplicated copy-paste across phases.
- Explicit `AWS_PROFILE` / `KUBECONFIG` / `RHCS_TOKEN` — never assume defaults silently without printing them.
- Fail with **actionable** messages that cite `INSTALL.md` section/step.
- No secrets in argv of logged commands; redact passwords in logs; access file mode `600`.
- Prefer calling upstream tools (`make`, `rosa`, `oc`, sno scripts) over reimplementing them.

### 3. Simple folder structure

User-facing mental model ≤ **5** things:

```text
INSTALL.md                 # how a human runs it
SPEC.md                    # this file (principles + accept criteria)
install.sh                 # orchestrator
phase1/install_rosa.sh     # all of Phase 1
phase2/install_rhoai.sh    # all of Phase 2
lib/                       # shared helpers + defaults (not run directly)
templates/                 # tfvars + NodePool + DSC templates
tests/smoke.sh             # static checks (no cloud)
state/                     # gitignored runtime (env, logs, access-*.txt)
```

No `01_`, `02_` user-facing scripts. Optional `--from=` replaces “run script 4 of 7”.

### 4. Comments on critical steps

Comment **why / risk / undo**, not “increment i”.

Required comment blocks before:

- Manual gates (ROSA / billing / OCM)
- Terraform plan → apply confirm
- Password / secret retrieval and writing `state/access-*.txt`
- Operator installs that wait on CSVs
- Any `rosa edit` / machinepool scale
- Teardown instructions echoed to the user

### 5. Testable

Testing pyramid for this repo (no live cluster required for CI-ish checks):

| Level | What | Command / artifact |
|-------|------|--------------------|
| Static | syntax + shell best practice | `bash -n`, `shellcheck` |
| Unit-ish | pure helpers (prompt defaults, sed render, step ranking) | small `tests/*.bats` or `tests/test_*.sh` |
| Dry-run | no apply / no cluster mutate | `--tools-only`, `--plan-only` / skip apply, template render to temp dir |
| Contract | templates render; sibling paths exist | assert `validated-pattern`, sno scripts, toolkit YAML present |
| Integration (manual) | real RHDP | checklist in INSTALL.md; never default in automation |

**Rules**

- Every Phase script supports dry capabilities: `--tools-only`, `--from=`, and provision must not apply without confirm (and ideally `--plan-only`).
- Tests must not require network or real AWS credentials in the default `tests/` target.
- “Green” in CI ≠ “cluster created”.

---

## Additional principles (recommended)

### 6. Idempotent where safe; explicit where not

- Re-running operator `oc apply` and verify steps should be safe.
- Re-running terraform apply is **not** “free idempotent” from a UX view — always show plan + confirm.
- Refuse existing `clusters/<name>` unless `--force`.

### 7. Dry-run / plan-first by default for costly ops

- Default path: init → plan → **human confirm** → apply.
- Offer `--plan-only` to stop after plan (agentic + teaching use).
- Never set `AUTO_APPROVE` until after confirm (or document `--yes` as explicit escape hatch).

### 8. Observability: logs, state, printed summary

- All long operations tee to `state/logs/`.
- Phase 1 **must** print Console URL, API URL, username, password (and save `state/access-<name>.txt`).
- Phase 2 **must** print platform-ready checklist (CSV, DSC/MaaS, dashboard route, NodePools).
- On failure: last log path + which `--from=` to resume.

### 9. Secrets & privacy hygiene

- OCM token only from `~/.config/ocm/offline-token` (user-created).
- AK/SK only via `aws configure` profile — never write into repo templates.
- Password in `state/access-*.txt` only (gitignored), not in `cluster.env`.
- Entire `state/` runtime tree is gitignored (except `.gitkeep` + `state/README.md`).
- Docs use `/path/to/...` placeholders — no personal home directories or lab account IDs.
- README/INSTALL warn: do not paste tokens into chat/tickets or GitHub.

### 10. Explicit human gates for irreversible / non-automatable steps

Keep as hard human gates:

1. ROSA HCP enabled in AWS — confirm `YES`  
2. AWS ↔ Red Hat billing linked — confirm `YES`  
3. OCM offline token — **prompt paste** (like AK/SK) into `~/.config/ocm/offline-token`, then `rosa whoami` must match expected user/account  

**Automated in preflight (no YES gate):** `rosa create ocm-role --admin` when no linked OCM role exists; ELB service-linked role if missing.  

### 11. Compatibility & pins documented

- macOS + Homebrew only (v1).
- OpenShift **4.22.x**; RHOAI channel **stable-3.5**.
- Document minimum CLI expectations (`rosa`, `oc`, `terraform >= 1.5`, `aws`, `jq`).
- Sibling repo paths configurable via env; fail clearly if missing.

### 12. Least surprise UX

- Print current `AWS_PROFILE` and account id before mutate.
- Defaults match Tokyo public lab (`ap-northeast-1`, `m6a.2xlarge`, 2 replicas).
- Single language in scripts: clear English; INSTALL.md is the long form.
- Progress labels: `Step tools|aws|preflight|inputs|provision|verify`.

### 13. Timeouts & waits are bounded

- CSV / CRD waits use capped loops with message + continue-or-die policy stated in comments.
- No infinite `while true` without a max.

### 14. Destroy is a peer path, not an afterthought

- Document teardown next to install (INSTALL.md).
- Optional later: `./uninstall.sh` that only wraps `make cluster.<name>.destroy` + prints Phase 2 cleanup notes — still confirm-gated.
- v1 minimum: documented destroy, not necessarily a fancy uninstall script.

### 15. Wrapper honesty (no fake abstraction)

- Do not re-vendor Terraform modules.
- Do not silently patch sno scripts; call them and surface their errors.
- If upstream behavior changes, fix the wrapper or pin a known-good sibling revision — record assumption in SPEC.

### 16. Exit codes & automation-friendly flags

- `0` success; non-zero on gate failure / missing tools / apply cancel.
- Support non-interactive later via env (`AWS_PROFILE`, pre-filled `state/cluster.env`) but v1 may remain interactive for gates.
- `--help` on every entry script.

### 17. Verification before “done”

Accept criteria for claiming Phase 1 complete:

- [ ] `rosa` state `ready`
- [ ] Workers Ready (or warned)
- [ ] Access block printed + `state/access-*.txt` written
- [ ] Undo/teardown command printed

Accept criteria for Phase 2 platform-ready:

- [ ] RHODS CSV Succeeded on `stable-3.5`
- [ ] `default-dsc` Ready / MaaS condition ready (as applicable)
- [ ] `maas-api` Available (or documented skip)
- [ ] CPU+GPU NodePools applied (on-demand)
- [ ] Explicit “no model smoke” note

---

## Folder & command surface (normative)

```bash
./install.sh                      # Phase 1 → confirm → optional Phase 2
./phase1/install_rosa.sh          # Phase 1 only
./phase1/install_rosa.sh --tools-only
./phase1/install_rosa.sh --plan-only
./phase1/install_rosa.sh --from=verify
./phase2/install_rhoai.sh         # Phase 2 only (kubeconfig required)
```

---

## Open risks (call out, don’t hide)

1. **Billing / ROSA enable** cannot be automated reliably — gates stay manual.  
2. **Destroy ≠ instant** (Secrets Manager, S3 log buckets, ENIs).  
3. **Operator uninstall** may leave CRDs/namespaces; Phase 2 rollback is best-effort.  
4. **Spot SCP** on RHDP → on-demand only until org policy changes.  
5. **Wrong OCM user** is a common failure — username/account match is a hard stop.

---

## What we intentionally do *not* add (v1)

- Browser automation for Marketplace / token pages  
- Full GitOps bootstrap during create  
- Windows/Linux bootstrap parity  
- Automated GPU model functional tests  
