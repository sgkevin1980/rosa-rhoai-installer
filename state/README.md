# Local state (gitignored)

This directory holds **machine-local** installer output. Do not commit it.

Typical files (created at runtime):

| File | Contents |
|------|----------|
| `cluster.env` | Cluster name, AWS profile, paths (no passwords) |
| `access-<cluster>.txt` | Console/API URLs + admin password (mode 600) |
| `logs/` | Provision / sno script logs |
| `nodepool-*.yaml` | Rendered NodePool manifests |

Keep only `.gitkeep` and this README in git.
