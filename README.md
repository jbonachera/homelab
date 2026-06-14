# homelab

Single-node Kubernetes homelab running [Talos Linux](https://www.talos.dev/), provisioned via PXE boot and managed with infrastructure-as-code and GitOps.

## Stack

| Layer | Tool |
|-------|------|
| OS | [Talos Linux](https://www.talos.dev/) v1.13 — immutable, API-only, no SSH |
| Infra-as-code | [OpenTofu](https://opentofu.org/) — Talos bootstrap + infrastructure operators (Helm) |
| CNI / LB | [Cilium](https://cilium.io/) — eBPF dataplane, LB IPAM, eBGP route announcements |
| BGP peer | Unifi Dream Machine Pro — receives LoadBalancer routes via eBGP |
| GitOps | [Flux CD](https://fluxcd.io/) — watches `kubernetes/` (CRD configs + apps) |
| Ingress | [Traefik](https://traefik.io/) — LoadBalancer service, gets IP from Cilium IPAM |
| Secrets | [SOPS](https://github.com/getsops/sops) + [age](https://age-encryption.org/) |
| PXE | dnsmasq on router (UEFI HTTP boot) |
| Tool versions | [mise](https://mise.jdx.dev/) |
| Pre-commit hooks | [hk](https://hk.jdx.dev/) |

## Prerequisites

**Hardware**

- One physical machine with UEFI and PXE/HTTP boot support
- A Unifi Dream Machine Pro (or any router supporting BGP) configured to peer with the cluster

**Workstation**

- [mise](https://mise.jdx.dev/) — installs every other tool automatically

## Repository structure

```
.
├── hk.pkl                          # Pre-commit hook definitions
├── mise.toml                       # Tool versions + common tasks
├── .sops.yaml                      # SOPS encryption rules (age, public key only)
├── talos/
│   └── patches/
│       ├── all.yaml                # Patches applied to every node
│       └── controlplane.yaml      # Control-plane-specific patches (Cilium CNI, no kube-proxy)
├── tofu/
│   ├── bootstrap/                  # Day-0: Talos secrets, machineconfig, etcd bootstrap, kubeconfig
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   └── terraform.tfvars.example
│   └── operators/                  # Day-2: Helm operators + Kubernetes CRDs
│       ├── operators.tf            # Cilium, Traefik, ESO, NFS provisioner
│       ├── variables.tf
│       ├── terraform.tfvars.example
│       └── templates/
│           └── udmp-frr.conf.tftpl # FRR BGP config template for the UDMP
└── kubernetes/
    ├── infrastructure.yaml         # Flux Kustomization — infra layer
    ├── apps.yaml                   # Flux Kustomization — apps layer
    ├── infrastructure/             # CRD-layer configs (TimescaleDB, etc.)
    └── apps/                       # Application manifests (Home Assistant, Homebridge, etc.)
```

## Getting started

```bash
# 1. Install all tools
mise install

# 2. Configure PXE — point your router's UEFI HTTP boot at the Talos assets for the
#    version in tofu/bootstrap/terraform.tfvars.example. The node boots into maintenance
#    mode (port 50000); no config is baked into the PXE image.

# 3. Generate an age keypair — the public key goes into .sops.yaml, the private key stays local
age-keygen -o age.key
# Edit .sops.yaml: replace the placeholder age1xxx... with the public key printed above

# 4. Copy and fill in variables for both Tofu state roots
cp tofu/bootstrap/terraform.tfvars.example tofu/bootstrap/terraform.tfvars
cp tofu/operators/terraform.tfvars.example tofu/operators/terraform.tfvars
# Edit both files: set node_ip, nfs_server, nfs_path, BGP ASNs, etc.

# 5. Initialise OpenTofu
tofu -chdir=tofu/bootstrap init
tofu -chdir=tofu/operators init

# 6. Provision the node (push machineconfig, bootstrap etcd, write kubeconfig)
mise run bootstrap

# 7. Deploy infrastructure operators (Cilium, Traefik, ESO, NFS provisioner)
mise run apply

# 8. Configure BGP on the UDMP
#    After step 7, tofu generates tofu/operators/udmp-frr.conf (gitignored).
#    Copy its contents into the UDMP: Settings → Routing → BGP → Custom FRR config.

# 9. Bootstrap Flux (requires an active gh session: gh auth login)
mise run bootstrap-flux

# 10. Push the SOPS decryption key to the cluster so Flux can decrypt secrets
kubectl create secret generic sops-age \
  --namespace=flux-system \
  --from-file=age.agekey=age.key
```

## Networking

LoadBalancer IPs are served from the `172.20.150.0/24` pool, managed by Cilium's LB IPAM. Routes are announced to the UDMP via eBGP:

| Parameter | Value |
|-----------|-------|
| Cilium ASN | `64872` |
| UDMP ASN | `64521` |
| UDMP peer IP | `172.20.3.1` |
| LB IP pool | `172.20.150.0/24` |

After `tofu apply`, verify the BGP session is up:

```bash
kubectl -n kube-system exec -it ds/cilium -- cilium bgp peers
```

Expected: neighbor `172.20.3.1` in `Established` state.

## Day 2 — operations

**Preview changes without applying**

```bash
mise run plan
```

**Update machineconfig (e.g. after editing patches)**

```bash
mise run apply
```

Talos uses `apply_mode = auto` — it only reboots if the change requires it.

**Reprovision from scratch**

```bash
NODE_IP=<node-ip> mise run reset   # wipes the node; it reboots into maintenance mode
mise run apply                     # re-applies machineconfig and re-bootstraps
```

**Add infrastructure operators**

Operators (anything that installs CRDs) go in `tofu/operators/operators.tf` as `helm_release` resources. Their Custom Resources (configs, routes, secret stores) go in `kubernetes/infrastructure/`.

**Add applications**

Drop manifests into `kubernetes/apps/` and commit. Flux reconciles automatically. Encrypt secrets before committing:

```bash
sops --encrypt --in-place kubernetes/<path>/<name>.secret.yaml
```

**Lint YAML**

```bash
mise exec -- yamllint kubernetes/ talos/
```

**Upgrade Talos**

1. Update `talos_version` in `tofu/bootstrap/terraform.tfvars`
2. Update PXE assets on the router to the new version
3. `mise run apply`

**Upgrade an operator chart** (Cilium, Traefik, ESO, NFS)

1. Update the relevant `chart_*_version` variable in `tofu/operators/terraform.tfvars`
2. `mise run apply`

> Note: ESO CRDs are not upgraded automatically by `helm upgrade`. When bumping `chart_eso_version`, apply the new CRDs manually first:
> ```bash
> kubectl apply --server-side -f https://raw.githubusercontent.com/external-secrets/external-secrets/<version>/deploy/crds/
> ```

## Security

This repository is public. The following **never** leave your workstation:

| Secret | Location |
|--------|----------|
| age private key | `age.key` (gitignored) |
| Talos secrets (CA, tokens, etcd key) | `tofu/bootstrap/terraform.tfstate` (gitignored) |
| kubeconfig | `tofu/bootstrap/kubeconfig.yaml` (gitignored) |
| Variable values (node IP, ASNs, etc.) | `tofu/*/terraform.tfvars` (gitignored) |
| UDMP FRR config | `tofu/operators/udmp-frr.conf` (gitignored) |

Kubernetes secrets committed to this repo must be SOPS-encrypted. The pre-commit hook (`sops-check`) rejects any `*.secret.yaml` file that lacks a `sops:` header.
