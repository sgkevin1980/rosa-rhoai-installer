# rosa-rhoai-installer

Thin macOS wrapper: prompts → write configs → run `make cluster.*` in the sibling Terraform pattern repo. Optional OpenShift AI Phase 2.

```bash
./install.sh                 # main entry
./phase1/install_rosa.sh     # ROSA only
./phase2/install_rhoai.sh    # OpenShift AI only
```

Full guide: [INSTALL.md](./INSTALL.md)

## Layout

```text
install.sh          # orchestrator
phase1/             # ROSA
phase2/             # OpenShift AI
lib/                # shared helpers + defaults.env
templates/          # files the installer writes/applies (see below)
docs/images/        # screenshots for INSTALL.md manual steps
tests/smoke.sh      # static checks
state/              # local runtime (gitignored)
```

Sibling (outside this repo):

```text
parent/
  rosa-rhoai-installer/
  validated-pattern-terraform-rosa/   # Terraform — clone once by install.sh
  rhoai-sno-setup-guide/              # Phase 2
  RHOAI-Toolkit/                      # Phase 2
```

## What `templates/` is for

Filled-in / copied by the installer — **not** Terraform modules:

| File | Used by |
|------|---------|
| `terraform.tfvars.tmpl` | Phase 1 → `clusters/<name>/terraform.tfvars` |
| `nodepool-cpu.yaml.tmpl` / `nodepool-gpu.yaml.tmpl` | Phase 2 → Karpenter NodePools |
| `datasciencecluster-baseline.yaml` | Phase 2 → DSC |

Change defaults for new clusters in `lib/defaults.env` and these templates.

## Re-pull upstream (plain git)

```bash
git -C ../validated-pattern-terraform-rosa pull
# optional Phase 2:
git -C ../rhoai-sno-setup-guide pull
git -C ../RHOAI-Toolkit pull
```

## Security

Never commit keys, OCM tokens, kubeconfigs, or `state/`.
