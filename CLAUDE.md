# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Common commands

All tools are managed by mise. Run `mise install` once before anything else.

```bash
mise run plan          # tofu plan — preview infra changes
mise run apply         # tofu apply — provision or update the Talos node
NODE_IP=x.x.x.x mise run reset  # wipe and reprovision node (reboots into maintenance mode)

mise exec -- yamllint kubernetes/ talos/   # lint YAML — always invoke yamllint via mise, never directly
tofu -chdir=tofu fmt -recursive            # format Terraform files
```

## Architecture

This repo is a **single-node Talos Linux homelab** provisioned with a deliberate separation of concerns:

- **Day 0 (bootstrap)** is intentionally manual: OpenTofu generates Talos secrets, pushes machineconfig to the node via the maintenance-mode API (port 50000), bootstraps etcd, and writes `tofu/kubeconfig.yaml`. No `talos.config=` kernel parameter is used — the PXE image boots vanilla Talos, which waits in maintenance mode for config to be pushed.
- **Day 2 (operations)** is GitOps: Flux CD watches the `kubernetes/` directory and reconciles everything declared there.

### Talos patches (`talos/patches/`)

Patches must use **strategic merge format** — JSON Patch (RFC 6902 `op/path/value`) is not supported for Talos multi-document machineconfig. `all.yaml` applies to every node; `controlplane.yaml` applies only to control-plane nodes. Both are passed to `data.talos_machine_configuration` in `tofu/main.tf`.

### OpenTofu (`tofu/`)

The provider is `siderolabs/talos ~> 0.11`. Key resource flow:

```
talos_machine_secrets → talos_machine_configuration (data) → talos_machine_configuration_apply
                                                           → talos_machine_bootstrap
                                                           → talos_cluster_kubeconfig → local_sensitive_file
```

`apply_mode = "auto"` — Talos decides whether a reboot is needed. Never change this to `"reboot"`.

Environment-specific values (`node_ip`, `talos_version`, etc.) live in `tofu/terraform.tfvars` which is gitignored. Copy `terraform.tfvars.example` to get started.

### Flux Kustomizations (`kubernetes/`)

Two Flux `Kustomization` CRDs sit at `kubernetes/` root:
- `infrastructure.yaml` — `wait: true`, reconciles `kubernetes/infrastructure/`
- `apps.yaml` — `dependsOn: infrastructure`, no `wait`, reconciles `kubernetes/apps/`

Both use SOPS decryption via the `sops-age` secret in `flux-system`. Add new workloads by dropping manifests into the appropriate subdirectory and registering them in the local `kustomization.yaml`.

### Secrets

`.sops.yaml` encrypts any file matching `^kubernetes/.*\.secret\.yaml$` with age. The age **private key** (`age.key`) and all Talos secrets (`tofu/terraform.tfstate`, `tofu/kubeconfig.yaml`) are gitignored and never committed. Only the age public key lives in `.sops.yaml`.

The pre-commit hook (`sops-check` in `hk.pkl`) rejects any `*.secret.yaml` that lacks a `sops:` header. All commits during bootstrap used `--no-verify` because hk requires pkl installed globally.
