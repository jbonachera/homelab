# Cilium L2 → eBGP Migration Design

## Context

Single-node Talos homelab. Cilium is already deployed as CNI and LB IPAM in L2 announcement mode (`CiliumL2AnnouncementPolicy`). This design replaces L2 with eBGP peering toward a Unifi Dream Machine Pro (UDMP), allowing service IPs to live on a dedicated subnet routed via BGP rather than announced via ARP.

## Goals

- Replace Cilium L2 announcements with eBGP (`bgpControlPlane`)
- Move LoadBalancer IP pool to a dedicated subnet (`172.20.150.0/24`)
- Generate the UDMP FRR config from tofu (gitignored, like kubeconfig)

## Non-Goals

- Cilium network policies
- BGP route redistribution from UDMP to Cilium
- Hubble or observability changes

## BGP Parameters

| Parameter | Value |
|-----------|-------|
| UDMP ASN | `64521` |
| Cilium ASN | `64872` |
| UDMP IP (peer) | `172.20.3.1` |
| Node IP | `172.20.3.157` |
| Service pool | `172.20.150.0/24` |

## Architecture

```
Service type=LoadBalancer
  └── Cilium IPAM → attribue IP depuis 172.20.150.0/24
        └── Cilium BGP → annonce le /32 vers UDMP (172.20.3.1, ASN 64521)
              └── UDMP route le trafic vers 172.20.3.157
```

## Changes

### `tofu/operators/operators.tf`

**Cilium Helm values:**
```diff
- l2announcements = {
-   enabled = true
- }
+ bgpControlPlane = {
+   enabled = true
+ }
```

**Kubernetes manifests:**
```diff
- kubernetes_manifest.cilium_l2_policy        # CiliumL2AnnouncementPolicy
+ kubernetes_manifest.cilium_bgp_cluster_config  # CiliumBGPClusterConfig
```

**`CiliumLoadBalancerIPPool`:**
```diff
- blocks = [{ cidr = "172.20.3.208/28" }]
+ blocks = [{ cidr = "172.20.150.0/24" }]
```

**`CiliumBGPClusterConfig`:**
```yaml
apiVersion: cilium.io/v2alpha1
kind: CiliumBGPClusterConfig
metadata:
  name: default
spec:
  nodeSelector:
    matchLabels: {}
  bgpInstances:
  - name: default
    localASN: 64872
    peers:
    - name: udmp
      peerASN: 64521
      peerAddress: 172.20.3.1
      peerConfigRef:
        name: udmp-peer-config
```

Note: `CiliumBGPPeeringPolicy` is not needed for Cilium ≥1.15; `CiliumBGPClusterConfig` is sufficient.

**Dependency chain:**
```
cilium → cilium_ip_pool → cilium_bgp_cluster_config → traefik
```

**UDMP FRR config generation:**
```hcl
resource "local_sensitive_file" "udmp_frr_config" {
  filename = "${path.module}/udmp-frr.conf"
  content  = templatefile("${path.module}/templates/udmp-frr.conf.tftpl", {
    udmp_asn   = var.udmp_asn
    udmp_ip    = var.udmp_ip
    cilium_asn = var.cilium_asn
    node_ip    = var.node_ip
  })
}
```

### `tofu/operators/templates/udmp-frr.conf.tftpl` (new, versioned)

```
router bgp ${udmp_asn}
  bgp router-id ${udmp_ip}
  neighbor ${node_ip} remote-as ${cilium_asn}
  neighbor ${node_ip} description cilium-homelab
  !
  address-family ipv4 unicast
    neighbor ${node_ip} activate
    neighbor ${node_ip} soft-reconfiguration inbound
  exit-address-family
```

### `tofu/operators/variables.tf` (additions)

- `udmp_asn` — default `64521`
- `udmp_ip` — default `172.20.3.1`
- `cilium_asn` — default `64872`

### `.gitignore` additions

```
tofu/operators/udmp-frr.conf
```

### Files to remove

- `kubernetes/infrastructure/metallb-config/` — already removed per previous design
- `kubernetes_manifest.cilium_l2_policy` in `operators.tf`

## Deployment Order

```
talos bootstrap
  └── tofu/bootstrap apply
        └── tofu/operators apply
              ├── cilium (Helm, bgpControlPlane enabled)
              ├── CiliumLoadBalancerIPPool (172.20.150.0/24)
              ├── CiliumBGPClusterConfig
              ├── local_sensitive_file → udmp-frr.conf
              └── traefik (gets IP from 172.20.150.0/24)
```

## Manual Step: UDMP FRR Configuration

After `tofu apply`, copy `tofu/operators/udmp-frr.conf` to the UDMP via the UniFi Network interface (Settings → Routing → BGP → Custom FRR config). The UDMP will establish the BGP session with Cilium and install `/32` routes for each service IP into its routing table.
