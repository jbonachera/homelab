# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Common commands

All tools are managed by mise. Run `mise install` once before anything else.

```bash
mise run bootstrap     # provision Talos node — push machineconfig, bootstrap etcd, write kubeconfig
mise run apply         # deploy operators onto an already-bootstrapped cluster
NODE_IP=x.x.x.x mise run reset  # wipe and reprovision node (reboots into maintenance mode)

mise exec -- yamllint kubernetes/ talos/   # lint YAML — always invoke yamllint via mise, never directly
tofu -chdir=tofu/bootstrap fmt -recursive  # format bootstrap Terraform files
tofu -chdir=tofu/operators fmt -recursive  # format operators Terraform files
```

## Architecture

This repo is a **single-node Talos Linux homelab** provisioned with a deliberate separation of concerns:

- **Day 0 (bootstrap)** is intentionally manual: `tofu/bootstrap/` generates Talos secrets, pushes machineconfig to the node via the maintenance-mode API (port 50000), bootstraps etcd, and writes `tofu/bootstrap/kubeconfig.yaml`. No `talos.config=` kernel parameter is used — the PXE image boots vanilla Talos, which waits in maintenance mode for config to be pushed.
- **Day 2 (operations)** is GitOps: Flux CD watches the `kubernetes/` directory and reconciles everything declared there.

### Talos patches (`talos/patches/`)

Patches must use **strategic merge format** — JSON Patch (RFC 6902 `op/path/value`) is not supported for Talos multi-document machineconfig. `all.yaml` applies to every node; `controlplane.yaml` applies only to control-plane nodes. Both are passed to `data.talos_machine_configuration` in `tofu/main.tf`.

### OpenTofu (`tofu/`)

Split into two independent state roots:

**`tofu/bootstrap/`** — Talos only. Provider: `siderolabs/talos ~> 0.11`. Resource flow:

```
talos_machine_secrets → talos_machine_configuration (data) → talos_machine_configuration_apply
                                                           → talos_machine_bootstrap
                                                           → talos_cluster_kubeconfig → local_sensitive_file (kubeconfig.yaml)
```

`apply_mode = "auto"` — Talos decides whether a reboot is needed. Never change this to `"reboot"`.

**`tofu/operators/`** — Helm operators only. Reads `../bootstrap/kubeconfig.yaml` via `config_path` — no cross-state dependency. Contains metallb, traefik, external-secrets, nfs-provisioner.

Each directory has its own `terraform.tfvars` (gitignored) and `terraform.tfvars.example`. Copy the example to get started.

### Flux Kustomizations (`kubernetes/`)

Two Flux `Kustomization` CRDs sit at `kubernetes/` root:
- `infrastructure.yaml` — `wait: true`, reconciles `kubernetes/infrastructure/`
- `apps.yaml` — `dependsOn: infrastructure`, no `wait`, reconciles `kubernetes/apps/`

Both use SOPS decryption via the `sops-age` secret in `flux-system`. Add new workloads by dropping manifests into the appropriate subdirectory and registering them in the local `kustomization.yaml`.

### Secrets

`.sops.yaml` encrypts any file matching `^kubernetes/.*\.secret\.yaml$` with age. The age **private key** (`age.key`) and all Talos secrets (`tofu/bootstrap/terraform.tfstate`, `tofu/bootstrap/kubeconfig.yaml`, `tofu/bootstrap/talosconfig.yaml`) are gitignored and never committed. Only the age public key lives in `.sops.yaml`.

The pre-commit hook (`sops-check` in `hk.pkl`) rejects any `*.secret.yaml` that lacks a `sops:` header. All commits during bootstrap used `--no-verify` because hk requires pkl installed globally.
