# MetalLB → Cilium Migration Design

## Context

Single-node Talos homelab. MetalLB currently provides LoadBalancer IP assignment in L2 mode. Cilium replaces both the CNI (flannel) and MetalLB via its native L2 announcement feature. The cluster is being reset, so no live migration is required.

## Goals

- Replace flannel CNI with Cilium (eBPF dataplane)
- Replace MetalLB with Cilium LB IPAM + L2 announcements
- Ensure Traefik gets its LoadBalancer IP at `tofu apply` time, without depending on Flux

## Non-Goals

- BGP mode (L2 is sufficient for single-node)
- Hubble UI or advanced observability setup
- Cilium network policies

## Architecture

### Talos patches (`talos/patches/controlplane.yaml`)

Disable flannel and kube-proxy so Cilium can take over both:

```yaml
cluster:
  allowSchedulingOnControlPlanes: true
  proxy:
    disabled: true
  network:
    cni:
      name: none
```

Remove `proxy.mode: ipvs` and `ipvs-strict-arp` (MetalLB-specific).

### OpenTofu operators (`tofu/operators/operators.tf`)

Remove:
- `kubernetes_namespace.metallb_system`
- `helm_release.metallb`

Add:
- `helm_release.cilium` — deployed to `kube-system`, with:
  - `kubeProxyReplacement: true`
  - `k8sServiceHost` and `k8sServicePort` set to the node IP and 6443
  - `l2announcements.enabled: true`
  - `externalIPs.enabled: true`
  - `operator.replicas: 1` (single-node)
- `kubernetes_manifest.cilium_ip_pool` — `CiliumLoadBalancerIPPool` for range `172.20.1.160–172.20.1.170`
- `kubernetes_manifest.cilium_l2_policy` — `CiliumL2AnnouncementPolicy` selecting all services

Dependency chain:
```
cilium → cilium_ip_pool → cilium_l2_policy → traefik
```

`helm_release.traefik` updated to `depends_on` Cilium resources instead of MetalLB.

### Flux / Kubernetes manifests (`kubernetes/infrastructure/`)

Remove:
- `kubernetes/infrastructure/metallb-config.yaml`
- `kubernetes/infrastructure/metallb-config/` directory
- Entry in `kubernetes/infrastructure/kustomization.yaml`

The IP pool and L2 policy live exclusively in tofu — Flux has no role in network bootstrapping.

## Deployment Order After Reset

```
talos bootstrap
  └── tofu/bootstrap apply
        └── tofu/operators apply
              ├── cilium (Helm)
              ├── CiliumLoadBalancerIPPool
              ├── CiliumL2AnnouncementPolicy
              └── traefik (gets IP immediately)
                    └── [Flux reconciles apps/]
```

## Variables

`tofu/operators/variables.tf` gains:
- `chart_cilium_version` — pinned Cilium chart version
- `node_ip` — already exists in bootstrap, needs to be added to operators for `k8sServiceHost`

## Key Decisions

- **Pool in tofu, not Flux**: eliminates the chicken-and-egg problem where Traefik requests a LoadBalancer IP before the pool CRD exists.
- **`kubeProxyReplacement: true`**: Cilium fully replaces kube-proxy; requires `proxy.disabled: true` in Talos.
- **`cni.name: none`**: tells Talos not to install flannel; Cilium must be deployed before any pod scheduling works.
