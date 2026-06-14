# Cilium L2 → eBGP Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Cilium L2 announcement with eBGP peering toward a Unifi Dream Machine Pro, serving LoadBalancer IPs from the dedicated subnet `172.20.150.0/24`.

**Architecture:** All BGP config lives in `tofu/operators/` — no Flux involvement. `CiliumBGPClusterConfig` replaces `CiliumL2AnnouncementPolicy`. The UDMP FRR config is generated as a `local_sensitive_file` and gitignored, matching the kubeconfig pattern.

**Tech Stack:** OpenTofu, Cilium ≥1.15, FRRouting (UDMP)

---

### Task 1: Add BGP variables to `tofu/operators/`

**Goal:** Add the three new variables (`udmp_asn`, `udmp_ip`, `cilium_asn`) to `variables.tf` and their defaults to `terraform.tfvars.example`.

**Files:**
- Modify: `tofu/operators/variables.tf`
- Modify: `tofu/operators/terraform.tfvars.example`

**Acceptance Criteria:**
- [ ] `variables.tf` declares `udmp_asn` (default `64521`), `udmp_ip` (default `"172.20.3.1"`), `cilium_asn` (default `64872`)
- [ ] `terraform.tfvars.example` has commented-out entries for the three new variables with example values

**Verify:** `tofu -chdir=tofu/operators validate` → `Success! The configuration is valid.`

**Steps:**

- [ ] **Step 1: Add variables to `variables.tf`**

Append to `tofu/operators/variables.tf`:

```hcl
variable "udmp_asn" {
  description = "BGP ASN of the Unifi Dream Machine Pro"
  type        = number
  default     = 64521
}

variable "udmp_ip" {
  description = "IP address of the UDMP BGP peer"
  type        = string
  default     = "172.20.3.1"
}

variable "cilium_asn" {
  description = "BGP ASN assigned to the Cilium BGP control plane"
  type        = number
  default     = 64872
}
```

- [ ] **Step 2: Update `terraform.tfvars.example`**

Add after the `node_ip` line:

```hcl
# BGP peering (eBGP toward UDMP)
# udmp_asn   = 64521   # BGP ASN of the UDMP
# udmp_ip    = "172.20.3.1"  # IP of the UDMP BGP peer
# cilium_asn = 64872   # BGP ASN for Cilium
```

- [ ] **Step 3: Validate**

```bash
tofu -chdir=tofu/operators validate
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 4: Commit**

```bash
git add tofu/operators/variables.tf tofu/operators/terraform.tfvars.example
git commit -m "feat(tofu): add BGP variables for eBGP peering"
```

```json:metadata
{"files": ["tofu/operators/variables.tf", "tofu/operators/terraform.tfvars.example"], "verifyCommand": "tofu -chdir=tofu/operators validate", "acceptanceCriteria": ["variables.tf declares udmp_asn, udmp_ip, cilium_asn", "terraform.tfvars.example has commented entries for the three variables"]}
```

---

### Task 2: Create FRR config template

**Goal:** Add the versioned Jinja/HCL template that `local_sensitive_file` will render into `udmp-frr.conf`.

**Files:**
- Create: `tofu/operators/templates/udmp-frr.conf.tftpl`
- Modify: `.gitignore`

**Acceptance Criteria:**
- [ ] `tofu/operators/templates/udmp-frr.conf.tftpl` exists and contains valid FRR BGP config with template variables
- [ ] `tofu/operators/udmp-frr.conf` is listed in `.gitignore`

**Verify:** File exists at `tofu/operators/templates/udmp-frr.conf.tftpl` and `grep udmp-frr.conf .gitignore` exits 0.

**Steps:**

- [ ] **Step 1: Create template directory and file**

Create `tofu/operators/templates/udmp-frr.conf.tftpl`:

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

- [ ] **Step 2: Add generated file to `.gitignore`**

Append to `.gitignore`:

```
tofu/operators/udmp-frr.conf
```

- [ ] **Step 3: Verify**

```bash
test -f tofu/operators/templates/udmp-frr.conf.tftpl && grep -q udmp-frr.conf .gitignore && echo OK
```

Expected: `OK`

- [ ] **Step 4: Commit**

```bash
git add tofu/operators/templates/udmp-frr.conf.tftpl .gitignore
git commit -m "feat(tofu): add FRR config template for UDMP BGP peering"
```

```json:metadata
{"files": ["tofu/operators/templates/udmp-frr.conf.tftpl", ".gitignore"], "verifyCommand": "test -f tofu/operators/templates/udmp-frr.conf.tftpl && grep -q udmp-frr.conf .gitignore && echo OK", "acceptanceCriteria": ["template file exists with correct FRR syntax", "udmp-frr.conf is gitignored"]}
```

---

### Task 3: Migrate `operators.tf` from L2 to eBGP

**Goal:** Replace `l2announcements` Helm value and `CiliumL2AnnouncementPolicy` with `bgpControlPlane`, `CiliumBGPClusterConfig`, and `local_sensitive_file` for the FRR config. Update the IP pool CIDR and Traefik dependencies.

**Files:**
- Modify: `tofu/operators/operators.tf`

**Acceptance Criteria:**
- [ ] Cilium Helm values contain `bgpControlPlane.enabled = true` and no `l2announcements` key
- [ ] `kubernetes_manifest.cilium_l2_policy` is removed
- [ ] `kubernetes_manifest.cilium_bgp_cluster_config` exists with correct ASNs and peer address
- [ ] `kubernetes_manifest.cilium_ip_pool` uses CIDR `172.20.150.0/24`
- [ ] `local_sensitive_file.udmp_frr_config` generates `udmp-frr.conf` from the template
- [ ] `helm_release.traefik` depends on `cilium_bgp_cluster_config` instead of `cilium_l2_policy`
- [ ] `tofu -chdir=tofu/operators validate` passes

**Verify:** `tofu -chdir=tofu/operators validate` → `Success! The configuration is valid.`

**Steps:**

- [ ] **Step 1: Update Cilium Helm values**

In `tofu/operators/operators.tf`, replace the `l2announcements` block inside `helm_release.cilium`:

```hcl
# Remove:
      l2announcements = {
        enabled = true
      }
      externalIPs = {
        enabled = true
      }

# Add:
      bgpControlPlane = {
        enabled = true
      }
```

- [ ] **Step 2: Update IP pool CIDR**

In `kubernetes_manifest.cilium_ip_pool`, change:

```hcl
# Before:
        { cidr = "172.20.3.208/28" }

# After:
        { cidr = "172.20.150.0/24" }
```

- [ ] **Step 3: Replace L2 policy with BGP cluster config**

Remove the entire `resource "kubernetes_manifest" "cilium_l2_policy"` block and replace with:

```hcl
resource "kubernetes_manifest" "cilium_bgp_cluster_config" {
  depends_on = [kubernetes_manifest.cilium_ip_pool]

  manifest = {
    apiVersion = "cilium.io/v2alpha1"
    kind       = "CiliumBGPClusterConfig"
    metadata = {
      name = "default"
    }
    spec = {
      nodeSelector = {
        matchLabels = {}
      }
      bgpInstances = [
        {
          name     = "default"
          localASN = var.cilium_asn
          peers = [
            {
              name       = "udmp"
              peerASN    = var.udmp_asn
              peerAddress = var.udmp_ip
            }
          ]
        }
      ]
    }
  }
}
```

- [ ] **Step 4: Add FRR config file generation**

Add after `cilium_bgp_cluster_config`:

```hcl
resource "local_sensitive_file" "udmp_frr_config" {
  depends_on = [kubernetes_manifest.cilium_bgp_cluster_config]
  filename   = "${path.module}/udmp-frr.conf"
  content = templatefile("${path.module}/templates/udmp-frr.conf.tftpl", {
    udmp_asn   = var.udmp_asn
    udmp_ip    = var.udmp_ip
    cilium_asn = var.cilium_asn
    node_ip    = var.node_ip
  })
}
```

- [ ] **Step 5: Update Traefik depends_on**

In `helm_release.traefik`, replace `cilium_l2_policy` with `cilium_bgp_cluster_config`:

```hcl
  depends_on = [
    helm_release.cilium,
    kubernetes_manifest.cilium_ip_pool,
    kubernetes_manifest.cilium_bgp_cluster_config,
  ]
```

- [ ] **Step 6: Validate**

```bash
tofu -chdir=tofu/operators validate
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 7: Format**

```bash
tofu -chdir=tofu/operators fmt -recursive
```

- [ ] **Step 8: Commit**

```bash
git add tofu/operators/operators.tf
git commit -m "feat(tofu): migrate Cilium from L2 announcements to eBGP"
```

```json:metadata
{"files": ["tofu/operators/operators.tf"], "verifyCommand": "tofu -chdir=tofu/operators validate", "acceptanceCriteria": ["bgpControlPlane.enabled = true in Helm values", "no l2announcements key", "CiliumBGPClusterConfig with ASN 64872 and peer 172.20.3.1/64521", "IP pool CIDR is 172.20.150.0/24", "local_sensitive_file.udmp_frr_config present", "traefik depends_on cilium_bgp_cluster_config"]}
```

---

## Manual Step: Configure UDMP

After `tofu apply` completes:

1. Copy `tofu/operators/udmp-frr.conf` to the UDMP (Settings → Routing → BGP → Custom FRR config)
2. Verify the BGP session comes up: on the UDMP, check that neighbor `172.20.3.157` shows `Established`
3. Verify routes: the UDMP routing table should contain `/32` entries from `172.20.150.0/24`
