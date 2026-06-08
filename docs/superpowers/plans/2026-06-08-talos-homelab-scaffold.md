# Talos Homelab — Repo Scaffold Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Scaffold the complete homelab repository — developer tooling (mise, hk), Talos OS patches, OpenTofu infrastructure config, SOPS secrets config, and Kubernetes/Flux directory structure — everything that belongs in git before the first `tofu apply`.

**Architecture:** Four concerns: `talos/` (OS patches), `tofu/` (infra provisioning via siderolabs/talos provider), `kubernetes/` (Flux-managed workloads, Flux watches full `kubernetes/` path), root developer tooling (`mise.toml`, `hk.pkl`, `.sops.yaml`). No IPs, secrets, kubeconfig, or state ever touch git. Infrastructure Kustomization is reconciled before apps via Flux `dependsOn`.

**Tech Stack:** Talos v1.13, OpenTofu + siderolabs/talos ~0.7 + hashicorp/local ~2.5, Flux CD, SOPS + age, mise, hk v1.46.0, yamllint

---

### Task 1: Repository foundations

**Goal:** Update `.gitignore` to cover all generated/sensitive files and create `mise.toml` pinning all required CLI tools with convenience tasks.

**Files:**
- Modify: `.gitignore`
- Create: `mise.toml`

**Acceptance Criteria:**
- [ ] `.gitignore` covers `tofu/terraform.tfvars`, `tofu/terraform.tfstate*`, `tofu/.terraform/`, `tofu/kubeconfig.yaml`, `age.key`, `.env`, `hk.local.pkl`
- [ ] `mise install` completes without errors
- [ ] `mise run --list` shows `apply`, `plan`, `reset` tasks

**Verify:** `mise install && mise run --list`

**Steps:**

- [ ] **Step 1: Append to `.gitignore`**

The file currently contains `result` and `pxe/`. Append:

```
# OpenTofu
tofu/terraform.tfvars
tofu/terraform.tfstate
tofu/terraform.tfstate.backup
tofu/.terraform/
tofu/.terraform.lock.hcl
tofu/kubeconfig.yaml

# Secrets & local state
age.key
.env

# hk local overrides
hk.local.pkl
```

- [ ] **Step 2: Create `mise.toml`**

```toml
[tools]
opentofu = "latest"
talosctl = "latest"
kubectl  = "latest"
flux2    = "latest"
sops     = "latest"
age      = "latest"
hk       = "latest"
yamllint = "latest"

[tasks.apply]
description = "Provision or update the Talos node"
run         = "tofu -chdir=tofu apply"

[tasks.plan]
description = "Preview OpenTofu changes without applying"
run         = "tofu -chdir=tofu plan"

[tasks.reset]
description = "Wipe and reprovision the node — requires NODE_IP env var"
run         = "talosctl reset --reboot --nodes $NODE_IP"
```

If `yamllint` fails to resolve via mise's registry, remove it from `[tools]` and install via `pipx install yamllint` manually (it's a Python tool).

- [ ] **Step 3: Verify**

```bash
mise install
mise run --list
```

Expected output: all tools download, list shows `apply`, `plan`, `reset`.

- [ ] **Step 4: Commit**

```bash
git add .gitignore mise.toml
git commit -m "chore: add mise tooling and gitignore foundations"
```

---

### Task 2: Pre-commit hooks

**Goal:** Create `hk.pkl` defining pre-commit hooks that enforce tofu formatting, SOPS encryption on secret files, YAML lint on manifests, and private key detection.

**Files:**
- Create: `hk.pkl`

**Acceptance Criteria:**
- [ ] `hk install` succeeds (wires `.git/hooks/pre-commit`)
- [ ] `hk run pre-commit` passes on the current repo state
- [ ] Committing a `*.secret.yaml` without SOPS encryption is blocked

**Verify:** `hk install && hk run pre-commit`

**Steps:**

- [ ] **Step 1: Create `hk.pkl`**

```pkl
amends "package://github.com/jdx/hk/releases/download/v1.46.0/hk@1.46.0#/Config.pkl"
import "package://github.com/jdx/hk/releases/download/v1.46.0/hk@1.46.0#/Builtins.pkl"

local steps = new Mapping<String, Step> {
    ["tofu-fmt"] {
        glob  = List("tofu/**/*.tf")
        check = "tofu -chdir=tofu fmt -check -recursive"
        fix   = "tofu -chdir=tofu fmt -recursive"
    }
    ["sops-check"] {
        glob  = List("kubernetes/**/*.secret.yaml")
        check = "for f in {{files}}; do grep -q '^sops:' \"$f\" || (echo \"NOT ENCRYPTED: $f\" && exit 1); done"
    }
    ["yaml-lint"] {
        glob  = List("kubernetes/**/*.yaml", "talos/**/*.yaml")
        check = "yamllint -d relaxed {{files}}"
    }
    ["no-private-keys"] = Builtins.check_private_key
}

hooks {
    ["pre-commit"] {
        stash = "git"
        stage = true
        steps = steps
    }
}
```

- [ ] **Step 2: Install hooks and verify**

```bash
hk install
hk run pre-commit
```

Expected: all steps pass (no tofu files to format yet, no secret yamls to check).

- [ ] **Step 3: Verify sops-check blocks unencrypted secrets**

```bash
mkdir -p kubernetes/apps
cat > /tmp/test.secret.yaml << 'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: test
data:
  password: dGVzdA==
EOF
cp /tmp/test.secret.yaml kubernetes/apps/test.secret.yaml
git add kubernetes/apps/test.secret.yaml
hk run pre-commit
```

Expected: `hk` exits non-zero with `NOT ENCRYPTED: kubernetes/apps/test.secret.yaml`.

```bash
rm kubernetes/apps/test.secret.yaml
git restore --staged kubernetes/apps/test.secret.yaml 2>/dev/null || true
```

- [ ] **Step 4: Commit**

```bash
git add hk.pkl
git commit -m "chore: add hk pre-commit hooks"
```

---

### Task 3: Talos patches

**Goal:** Create Talos machine configuration patches applied by OpenTofu — common settings (hostname, NTP) and controlplane-specific settings (allow workloads on control plane).

**Files:**
- Create: `talos/patches/all.yaml`
- Create: `talos/patches/controlplane.yaml`

**Acceptance Criteria:**
- [ ] Both files pass `yamllint`
- [ ] `all.yaml` contains hostname and NTP servers — no IPs
- [ ] `controlplane.yaml` enables `allowSchedulingOnControlPlanes`

**Verify:** `yamllint talos/patches/`

**Steps:**

- [ ] **Step 1: Create `talos/patches/all.yaml`**

```bash
mkdir -p talos/patches
```

```yaml
# talos/patches/all.yaml
machine:
  network:
    hostname: homelab
  time:
    servers:
      - time.cloudflare.com
      - pool.ntp.org
```

- [ ] **Step 2: Create `talos/patches/controlplane.yaml`**

This patch uses JSON Patch (RFC 6902) syntax — Talos accepts both strategic merge patches and JSON Patch.

```yaml
# talos/patches/controlplane.yaml
- op: add
  path: /cluster/allowSchedulingOnControlPlanes
  value: true
```

- [ ] **Step 3: Verify**

```bash
yamllint talos/patches/
```

Expected: no errors.

- [ ] **Step 4: Commit**

```bash
git add talos/
git commit -m "chore: add Talos machine configuration patches"
```

---

### Task 4: OpenTofu configuration

**Goal:** Create the full OpenTofu module that generates Talos secrets, renders machineconfig with patches, applies config to the node, bootstraps etcd, and writes kubeconfig locally.

**Files:**
- Create: `tofu/variables.tf`
- Create: `tofu/main.tf`
- Create: `tofu/outputs.tf`
- Create: `tofu/terraform.tfvars.example`

**Acceptance Criteria:**
- [ ] `tofu -chdir=tofu init` succeeds (providers downloaded)
- [ ] `tofu -chdir=tofu validate` reports `Success!`
- [ ] `tofu -chdir=tofu fmt -check` exits 0 (no formatting diff)
- [ ] `tofu/terraform.tfvars.example` documents all variables with empty values

**Verify:** `tofu -chdir=tofu init && tofu -chdir=tofu validate && tofu -chdir=tofu fmt -check`

**Steps:**

- [ ] **Step 1: Create `tofu/variables.tf`**

```hcl
variable "node_ip" {
  description = "IP address of the Talos node"
  type        = string
}

variable "cluster_name" {
  description = "Kubernetes cluster name"
  type        = string
  default     = "homelab"
}

variable "talos_version" {
  description = "Talos Linux version — must match the version served by PXE"
  type        = string
  default     = "v1.13.0"
}
```

- [ ] **Step 2: Create `tofu/main.tf`**

```hcl
terraform {
  required_providers {
    talos = {
      source  = "siderolabs/talos"
      version = "~> 0.7"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

resource "talos_machine_secrets" "this" {
  talos_version = var.talos_version
}

data "talos_machine_configuration" "controlplane" {
  cluster_name     = var.cluster_name
  cluster_endpoint = "https://${var.node_ip}:6443"
  machine_type     = "controlplane"
  machine_secrets  = talos_machine_secrets.this.machine_secrets
  talos_version    = var.talos_version

  config_patches = [
    file("${path.module}/../talos/patches/all.yaml"),
    file("${path.module}/../talos/patches/controlplane.yaml"),
  ]
}

resource "talos_machine_configuration_apply" "controlplane" {
  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.controlplane.machine_configuration
  node                        = var.node_ip
  apply_mode                  = "reboot"
}

resource "talos_machine_bootstrap" "this" {
  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = var.node_ip
  depends_on           = [talos_machine_configuration_apply.controlplane]
}

resource "talos_cluster_kubeconfig" "this" {
  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = var.node_ip
  depends_on           = [talos_machine_bootstrap.this]
}

resource "local_sensitive_file" "kubeconfig" {
  content         = talos_cluster_kubeconfig.this.kubeconfig_raw
  filename        = "${path.module}/kubeconfig.yaml"
  file_permission = "0600"
}
```

- [ ] **Step 3: Create `tofu/outputs.tf`**

```hcl
output "kubeconfig" {
  description = "Kubeconfig for the cluster (also written to tofu/kubeconfig.yaml)"
  value       = talos_cluster_kubeconfig.this.kubeconfig_raw
  sensitive   = true
}

output "talosconfig" {
  description = "Talosconfig for talosctl access"
  value       = talos_machine_secrets.this.client_configuration
  sensitive   = true
}
```

- [ ] **Step 4: Create `tofu/terraform.tfvars.example`**

```hcl
# Copy this file to terraform.tfvars and fill in your values.
# terraform.tfvars is gitignored and never committed.

node_ip       = ""         # IP address of the Talos node
cluster_name  = "homelab"  # Kubernetes cluster name
talos_version = "v1.13.0"  # Must match the version served by PXE
```

- [ ] **Step 5: Verify**

```bash
tofu -chdir=tofu init
tofu -chdir=tofu validate
tofu -chdir=tofu fmt -check
```

Expected:
- `init`: providers downloaded to `tofu/.terraform/`
- `validate`: `Success! The configuration is valid.`
- `fmt -check`: exits 0, no output

- [ ] **Step 6: Commit**

```bash
git add tofu/variables.tf tofu/main.tf tofu/outputs.tf tofu/terraform.tfvars.example
git commit -m "chore: add OpenTofu configuration for Talos provisioning"
```

---

### Task 5: SOPS configuration

**Goal:** Create `.sops.yaml` so that `sops` automatically encrypts/decrypts `*.secret.yaml` files under `kubernetes/` using age.

**Files:**
- Create: `.sops.yaml`

**Acceptance Criteria:**
- [ ] `.sops.yaml` exists with a `creation_rules` entry matching `kubernetes/**/*.secret.yaml`
- [ ] A test secret file encrypted with `sops -e` contains a `sops:` root key
- [ ] The same file decrypts cleanly with `sops -d`

**Verify:** Create, encrypt, verify, and delete a test secret — see steps below.

**Steps:**

- [ ] **Step 1: Generate a local age key (if not already done)**

```bash
age-keygen -o age.key
```

Output will include a line like:
```
# public key: age1xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

Copy that public key value (the `age1...` string).

- [ ] **Step 2: Create `.sops.yaml`**

Replace `age1xxxx...` with your actual public key from the previous step:

```yaml
creation_rules:
  - path_regex: kubernetes/.*\.secret\.yaml$
    age: age1xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

- [ ] **Step 3: Verify encrypt/decrypt round-trip**

```bash
# Create a test secret
mkdir -p kubernetes/apps
cat > kubernetes/apps/test.secret.yaml << 'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: test
stringData:
  password: supersecret
EOF

# Encrypt in-place (uses .sops.yaml rules automatically)
SOPS_AGE_KEY_FILE=age.key sops -e -i kubernetes/apps/test.secret.yaml

# Verify sops metadata is present at root
grep -q '^sops:' kubernetes/apps/test.secret.yaml && echo "PASS: file is encrypted"

# Verify it decrypts cleanly
SOPS_AGE_KEY_FILE=age.key sops -d kubernetes/apps/test.secret.yaml | grep -q 'supersecret' && echo "PASS: decryption works"

# Clean up test file
rm kubernetes/apps/test.secret.yaml
```

Expected: both `PASS` lines printed.

- [ ] **Step 4: Commit**

```bash
git add .sops.yaml
git commit -m "chore: add SOPS age encryption configuration"
```

---

### Task 6: Kubernetes/Flux scaffold

**Goal:** Create the Kubernetes directory structure with Flux Kustomization CRDs for infrastructure and apps, and empty kustomize configs ready to receive manifests.

**Files:**
- Create: `kubernetes/infrastructure.yaml` — Flux Kustomization CRD
- Create: `kubernetes/apps.yaml` — Flux Kustomization CRD (dependsOn: infrastructure)
- Create: `kubernetes/infrastructure/kustomization.yaml` — kustomize config
- Create: `kubernetes/infrastructure/sources/.gitkeep`
- Create: `kubernetes/apps/kustomization.yaml` — kustomize config

**Acceptance Criteria:**
- [ ] `yamllint kubernetes/` passes on all yaml files
- [ ] `kubernetes/apps.yaml` contains `dependsOn: [{name: infrastructure}]`
- [ ] Both Kustomization CRDs reference `sourceRef.name: flux-system`
- [ ] Both Kustomization CRDs include `spec.decryption` with `provider: sops`

**Verify:** `yamllint kubernetes/`

**Steps:**

- [ ] **Step 1: Create `kubernetes/infrastructure.yaml`**

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: infrastructure
  namespace: flux-system
spec:
  interval: 10m0s
  path: ./kubernetes/infrastructure
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
  wait: true
  timeout: 5m0s
  decryption:
    provider: sops
    secretRef:
      name: sops-age
```

- [ ] **Step 2: Create `kubernetes/apps.yaml`**

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: apps
  namespace: flux-system
spec:
  interval: 10m0s
  path: ./kubernetes/apps
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
  dependsOn:
    - name: infrastructure
  decryption:
    provider: sops
    secretRef:
      name: sops-age
```

- [ ] **Step 3: Create `kubernetes/infrastructure/kustomization.yaml`**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources: []
```

- [ ] **Step 4: Create `kubernetes/infrastructure/sources/.gitkeep` and `kubernetes/apps/kustomization.yaml`**

```bash
touch kubernetes/infrastructure/sources/.gitkeep
```

```yaml
# kubernetes/apps/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources: []
```

- [ ] **Step 5: Verify**

```bash
yamllint kubernetes/
```

Expected: no errors (the `.gitkeep` file is ignored, yaml files pass lint).

- [ ] **Step 6: Note on `flux bootstrap`**

After `tofu apply` succeeds, bootstrap Flux with `--path=kubernetes` so it watches the full `kubernetes/` directory and picks up `infrastructure.yaml` and `apps.yaml`:

```bash
export KUBECONFIG=tofu/kubeconfig.yaml
flux bootstrap github \
  --owner=<your-github-username> \
  --repository=homelab \
  --branch=main \
  --path=kubernetes \
  --personal
```

Then push the age key so Flux can decrypt secrets:

```bash
cat age.key | kubectl create secret generic sops-age \
  --namespace=flux-system \
  --from-file=age.agekey=/dev/stdin
```

- [ ] **Step 7: Commit**

```bash
git add kubernetes/
git commit -m "chore: add Kubernetes/Flux scaffold with infrastructure and apps Kustomizations"
```

---

## Post-scaffold day 0 checklist

Once the scaffold is committed, this is the full sequence to get a live cluster:

1. `mise install` — install all tools
2. `hk install` — wire pre-commit hooks
3. `age-keygen -o age.key` + fill public key in `.sops.yaml`
4. Download Talos v1.13.0 assets and configure dnsmasq on network server
5. Boot machine via PXE → wait for maintenance mode on `:50000`
6. `cp tofu/terraform.tfvars.example tofu/terraform.tfvars` + fill values
7. `mise run apply` — provisions node, bootstraps etcd, writes `tofu/kubeconfig.yaml`
8. `flux bootstrap github --path=kubernetes ...`
9. Push age key: `cat age.key | kubectl create secret generic sops-age --namespace=flux-system --from-file=age.agekey=/dev/stdin`
