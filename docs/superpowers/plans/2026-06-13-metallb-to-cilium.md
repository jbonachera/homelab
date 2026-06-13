# MetalLB → Cilium Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace MetalLB and flannel with Cilium as CNI + LB IPAM, deploying the IP pool via OpenTofu so Traefik gets its LoadBalancer IP at `tofu apply` time.

**Architecture:** Talos patches disable flannel and kube-proxy; Cilium is deployed via Helm in `tofu/operators/` with L2 announcements enabled; `CiliumLoadBalancerIPPool` and `CiliumL2AnnouncementPolicy` are created as `kubernetes_manifest` resources in the same tofu apply, before Traefik. MetalLB config is removed from Flux entirely.

**Tech Stack:** OpenTofu, Helm (Cilium chart), Talos strategic-merge patches, Kubernetes CRDs (`CiliumLoadBalancerIPPool`, `CiliumL2AnnouncementPolicy`)

---

### Task 1: Update Talos patches — disable flannel and kube-proxy

**Goal:** Patch Talos controlplane config to use `cni.name: none` and `proxy.disabled: true` so Cilium can own both.

**Files:**
- Modify: `talos/patches/controlplane.yaml`

**Acceptance Criteria:**
- [ ] `proxy.mode` and `ipvs-strict-arp` lines are removed
- [ ] `proxy.disabled: true` is present under `cluster`
- [ ] `cluster.network.cni.name: none` is present
- [ ] `yamllint talos/` passes

**Verify:** `mise exec -- yamllint talos/` → no errors

**Steps:**

- [ ] **Step 1: Replace controlplane.yaml content**

Replace the entire file with:

```yaml
---
cluster:
  allowSchedulingOnControlPlanes: true
  proxy:
    disabled: true
  network:
    cni:
      name: none
```

- [ ] **Step 2: Lint**

```bash
mise exec -- yamllint talos/
```

Expected: no output (clean).

- [ ] **Step 3: Commit**

```bash
git add talos/patches/controlplane.yaml
git commit -m "feat(talos): disable flannel and kube-proxy for Cilium"
```

---

### Task 2: Add Cilium Helm release and CRD resources to tofu/operators

**Goal:** Replace `helm_release.metallb` + `kubernetes_namespace.metallb_system` with `helm_release.cilium`, `kubernetes_manifest.cilium_ip_pool`, and `kubernetes_manifest.cilium_l2_policy` in `operators.tf`; update Traefik's `depends_on` accordingly.

**Files:**
- Modify: `tofu/operators/operators.tf`
- Modify: `tofu/operators/variables.tf`
- Modify: `tofu/operators/terraform.tfvars.example`
- Modify: `tofu/operators/terraform.tfvars`

**Acceptance Criteria:**
- [ ] `helm_release.metallb` and `kubernetes_namespace.metallb_system` are removed
- [ ] `helm_release.cilium` targets `kube-system`, sets `kubeProxyReplacement`, `l2announcements`, `externalIPs`, `k8sServiceHost`, `k8sServicePort`
- [ ] `kubernetes_manifest.cilium_ip_pool` creates a `CiliumLoadBalancerIPPool` with range `172.20.1.160-172.20.1.170`
- [ ] `kubernetes_manifest.cilium_l2_policy` creates a `CiliumL2AnnouncementPolicy` matching all services
- [ ] `helm_release.traefik` depends on `helm_release.cilium`, `kubernetes_manifest.cilium_ip_pool`, `kubernetes_manifest.cilium_l2_policy`
- [ ] `variable.chart_cilium_version` and `variable.node_ip` exist in `variables.tf`
- [ ] `tofu -chdir=tofu/operators fmt -recursive` produces no diff
- [ ] `tofu -chdir=tofu/operators validate` passes

**Verify:** `tofu -chdir=tofu/operators validate` → `Success! The configuration is valid.`

**Steps:**

- [ ] **Step 1: Remove MetalLB resources from operators.tf**

Delete the `resource "kubernetes_namespace" "metallb_system"` block and the `resource "helm_release" "metallb"` block entirely.

- [ ] **Step 2: Add Cilium Helm release**

Add before the Traefik release:

```hcl
resource "helm_release" "cilium" {
  name       = "cilium"
  repository = "https://helm.cilium.io"
  chart      = "cilium"
  version    = var.chart_cilium_version
  namespace  = "kube-system"
  wait       = true
  timeout    = 600

  values = [
    yamlencode({
      kubeProxyReplacement = true
      k8sServiceHost       = var.node_ip
      k8sServicePort       = 6443
      operator = {
        replicas = 1
      }
      l2announcements = {
        enabled = true
      }
      externalIPs = {
        enabled = true
      }
    })
  ]
}

resource "kubernetes_manifest" "cilium_ip_pool" {
  depends_on = [helm_release.cilium]

  manifest = {
    apiVersion = "cilium.io/v2alpha1"
    kind       = "CiliumLoadBalancerIPPool"
    metadata = {
      name = "default-pool"
    }
    spec = {
      blocks = [
        { cidr = "172.20.1.160/28" }
      ]
    }
  }
}

resource "kubernetes_manifest" "cilium_l2_policy" {
  depends_on = [kubernetes_manifest.cilium_ip_pool]

  manifest = {
    apiVersion = "cilium.io/v2alpha1"
    kind       = "CiliumL2AnnouncementPolicy"
    metadata = {
      name = "default"
    }
    spec = {
      serviceSelector = {
        matchLabels = {}
      }
      nodeSelector = {
        matchLabels = {}
      }
      interfaces               = []
      externalIPs              = true
      loadBalancerIPs          = true
    }
  }
}
```

Note: `172.20.1.160/28` covers `.160`–`.175`, which includes the original range `.160`–`.170`.

- [ ] **Step 3: Update Traefik depends_on**

Change the `depends_on` on `helm_release.traefik` from:

```hcl
depends_on = [helm_release.metallb]
```

to:

```hcl
depends_on = [
  helm_release.cilium,
  kubernetes_manifest.cilium_ip_pool,
  kubernetes_manifest.cilium_l2_policy,
]
```

- [ ] **Step 4: Add variables**

In `variables.tf`, remove `variable "chart_metallb_version"` and add:

```hcl
variable "chart_cilium_version" {
  description = "Cilium Helm chart version — verify latest at https://artifacthub.io/packages/helm/cilium/cilium"
  type        = string
  default     = "1.17.3"
}

variable "node_ip" {
  description = "IP address of the Kubernetes API server node (used for kubeProxyReplacement)"
  type        = string
}
```

- [ ] **Step 5: Update terraform.tfvars.example**

Replace `# chart_metallb_version` line with:

```hcl
node_ip = ""  # IP of the Talos node / kube-apiserver (e.g. "172.20.1.100")

# Chart versions — override defaults here if pinning to specific versions
# chart_cilium_version  = "1.17.3"
# chart_traefik_version = "34.4.0"
# chart_eso_version     = "0.11.0"
# chart_nfs_version     = "4.0.18"
```

- [ ] **Step 6: Update terraform.tfvars**

Add `node_ip = "<your-node-ip>"` and remove any `chart_metallb_version` line.

- [ ] **Step 7: Format and validate**

```bash
tofu -chdir=tofu/operators fmt -recursive
tofu -chdir=tofu/operators validate
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 8: Commit**

```bash
git add tofu/operators/operators.tf tofu/operators/variables.tf tofu/operators/terraform.tfvars.example
git commit -m "feat(tofu): replace MetalLB with Cilium LB IPAM + L2 announcements"
```

---

### Task 3: Remove MetalLB from Flux infrastructure

**Goal:** Delete the MetalLB config resources from Flux so it no longer tries to manage MetalLB CRDs that no longer exist.

**Files:**
- Modify: `kubernetes/infrastructure/kustomization.yaml`
- Delete: `kubernetes/infrastructure/metallb-config.yaml`
- Delete: `kubernetes/infrastructure/metallb-config/` (directory)

**Acceptance Criteria:**
- [ ] `metallb-config.yaml` is gone from `kubernetes/infrastructure/`
- [ ] `kubernetes/infrastructure/metallb-config/` directory is gone
- [ ] `metallb-config.yaml` is removed from `kubernetes/infrastructure/kustomization.yaml`
- [ ] `mise exec -- yamllint kubernetes/` passes

**Verify:** `mise exec -- yamllint kubernetes/` → no errors

**Steps:**

- [ ] **Step 1: Remove metallb-config entry from kustomization.yaml**

Edit `kubernetes/infrastructure/kustomization.yaml` to remove the `- metallb-config.yaml` line:

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - traefik-config.yaml
  - timescaledb.yaml
  - timescaledb-config.yaml
```

- [ ] **Step 2: Delete MetalLB files**

```bash
rm kubernetes/infrastructure/metallb-config.yaml
rm -rf kubernetes/infrastructure/metallb-config/
```

- [ ] **Step 3: Lint**

```bash
mise exec -- yamllint kubernetes/
```

Expected: no output (clean).

- [ ] **Step 4: Commit**

```bash
git add -u kubernetes/infrastructure/
git commit -m "feat(flux): remove MetalLB config — IP pool now managed by tofu"
```

---
