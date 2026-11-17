# rosa-rhoai-installer

Guided macOS installer for a **public ROSA HCP 4.22** cluster (Tokyo default, **2× m6a.xlarge**) plus optional **OpenShift AI 3.5** platform-ready (Karpenter CPU/GPU on-demand NodePools, NFD, GPU Operator, RHODS, MaaS).

| Doc | Purpose |
|-----|---------|
| [INSTALL.md](./INSTALL.md) | Step-by-step human guide |
| [SPEC.md](./SPEC.md) | Product boundaries + engineering principles |

```bash
./install.sh                 # Phase 1 → confirm → optional Phase 2
./phase1/install_rosa.sh     # ROSA only
./phase2/install_rhoai.sh    # OpenShift AI only (existing kubeconfig)
./tests/smoke.sh             # Static checks (no cloud / no secrets)
```

## Layout

```text
install.sh              # Orchestrator
phase1/install_rosa.sh  # ROSA HCP
phase2/install_rhoai.sh # OpenShift AI 3.5
lib/                    # Shared helpers + defaults
templates/              # tfvars, NodePools, DSC (no secrets)
docs/images/            # Console screenshots for manual gates
examples/               # Non-secret examples only
state/                  # LOCAL ONLY — gitignored runtime data
tests/smoke.sh          # bash -n + structure checks
```

## Sibling repositories (required)

This installer is a **wrapper**. It does **not** contain the Terraform Makefiles.  
By default it expects these directories **next to** `rosa-rhoai-installer/`:

```text
parent/
  rosa-rhoai-installer/                 # this repo
  validated-pattern-terraform-rosa/     # REQUIRED for Phase 1 (make cluster.<name>.*)
  rhoai-sno-setup-guide/                # REQUIRED for Phase 2
  RHOAI-Toolkit/                        # REQUIRED for HardwareProfile
```

If you only clone this GitHub repo, Phase 1 fails with:

`make: *** No rule to make target 'cluster.<name>.init'`

because `make` was not run from `validated-pattern-terraform-rosa/` (that repo defines `cluster.%`).

Override paths if needed:

```bash
export VALIDATED_PATTERN_DIR=/path/to/validated-pattern-terraform-rosa
export SNO_GUIDE_DIR=/path/to/rhoai-sno-setup-guide
export TOOLKIT_DIR=/path/to/RHOAI-Toolkit
```

## Security

- **Never commit** Access Keys, Secret Keys, OCM tokens, kubeconfigs, or `state/access-*.txt`.
- Secrets are prompted at runtime and stored under `~/.aws/`, `~/.config/ocm/`, or gitignored `state/`.
- Before publishing: run `./tests/smoke.sh` and confirm `git status` does not list `state/` files.
- Console screenshots under `docs/images/` are generic UI examples; account IDs are redacted where shown.

**Manual (browser only):** enable ROSA HCP, link AWS↔Red Hat billing, paste OCM offline token.  
**Automated in preflight:** OCM IAM role link (`rosa create ocm-role`) when missing.

**Out of scope (v1):** private/zero-egress, model smoke, Playground, Spot NodePools.
