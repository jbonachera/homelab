# Worker Node + KubeSpan Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ajouter un noeud worker Talos provisionné via PXE avec une IP DHCP, en activant KubeSpan pour stabiliser les communications inter-noeuds via WireGuard.

**Architecture:** KubeSpan est activé dans `talos/patches/all.yaml` (s'applique à tous les noeuds). Le worker est défini dans `tofu/bootstrap/main.tf` avec sa propre `data.talos_machine_configuration` et `talos_machine_configuration_apply`. L'IP DHCP du worker est passée au moment du provisioning uniquement — après que KubeSpan est actif, les communications passent par le tunnel WireGuard indépendamment de l'IP physique.

**Tech Stack:** OpenTofu, provider siderolabs/talos ~> 0.11, Talos Linux v1.13, KubeSpan (WireGuard managé)

---

### Task 1: Activer KubeSpan dans le patch all.yaml et re-appliquer au control plane

**Goal:** Ajouter KubeSpan à `talos/patches/all.yaml` et pousser la config mise à jour au control plane existant.

**Files:**
- Modify: `talos/patches/all.yaml`

**Acceptance Criteria:**
- [ ] `talos/patches/all.yaml` contient le bloc `network.kubespan.enabled: true`
- [ ] `tofu apply` dans `tofu/bootstrap/` se termine sans erreur
- [ ] La resource `KubespanIdentity` est visible sur le control plane via `talosctl get kubespanidentities -n <node_ip>`

**Verify:** `talosctl get kubespanidentities -n <NODE_IP> --talosconfig tofu/bootstrap/talosconfig.yaml` → retourne une ligne avec l'identité KubeSpan du noeud

**Steps:**

- [ ] **Step 1: Modifier `talos/patches/all.yaml`**

Contenu final du fichier :

```yaml
---
machine:
  time:
    servers:
      - time.cloudflare.com
      - pool.ntp.org
  nodeLabels:
    homelab/iot-gateway: "true"
  network:
    kubespan:
      enabled: true
```

- [ ] **Step 2: Appliquer au control plane**

```bash
cd tofu/bootstrap
tofu apply
```

`apply_mode = "auto"` — Talos décide si un reboot est nécessaire (ne pas forcer).

- [ ] **Step 3: Vérifier KubeSpan actif sur le control plane**

```bash
talosctl get kubespanidentities -n <NODE_IP> --talosconfig tofu/bootstrap/talosconfig.yaml
```

Résultat attendu : une ligne avec un ID et une clé publique WireGuard.

- [ ] **Step 4: Commit**

```bash
git add talos/patches/all.yaml
git commit -m "feat: enable KubeSpan on all Talos nodes"
```

---

### Task 2: Créer le patch worker et les ressources OpenTofu du worker

**Goal:** Ajouter le patch `talos/patches/worker.yaml` et les ressources OpenTofu pour provisionner le worker.

**Files:**
- Create: `talos/patches/worker.yaml`
- Modify: `tofu/bootstrap/variables.tf`
- Modify: `tofu/bootstrap/main.tf`

**Acceptance Criteria:**
- [ ] `talos/patches/worker.yaml` existe (patch vide valide)
- [ ] `variables.tf` contient la variable `worker_ip`
- [ ] `main.tf` contient `data.talos_machine_configuration.worker` et `talos_machine_configuration_apply.worker`
- [ ] `tofu validate` dans `tofu/bootstrap/` passe sans erreur
- [ ] `tofu plan -var worker_ip=1.2.3.4` montre les nouvelles ressources sans erreur

**Verify:** `cd tofu/bootstrap && tofu validate` → `Success! The configuration is valid.`

**Steps:**

- [ ] **Step 1: Créer `talos/patches/worker.yaml`**

```yaml
---
machine: {}
```

- [ ] **Step 2: Ajouter la variable `worker_ip` dans `tofu/bootstrap/variables.tf`**

Ajouter à la fin du fichier :

```hcl
variable "worker_ip" {
  description = "IP address of the Talos worker node at provisioning time (DHCP — used only for initial config push)"
  type        = string
}
```

- [ ] **Step 3: Ajouter les ressources worker dans `tofu/bootstrap/main.tf`**

Ajouter après le bloc `talos_machine_configuration_apply.controlplane` :

```hcl
data "talos_machine_configuration" "worker" {
  cluster_name     = var.cluster_name
  cluster_endpoint = "https://${var.node_ip}:6443"
  machine_type     = "worker"
  machine_secrets  = talos_machine_secrets.this.machine_secrets
  talos_version    = var.talos_version

  config_patches = [
    file("${path.module}/../../talos/patches/all.yaml"),
    file("${path.module}/../../talos/patches/worker.yaml"),
  ]
}

resource "talos_machine_configuration_apply" "worker" {
  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.worker.machine_configuration
  node                        = var.worker_ip
  apply_mode                  = "auto"
  depends_on                  = [talos_machine_bootstrap.this]
}
```

- [ ] **Step 4: Mettre à jour `talos_client_configuration` pour inclure le worker dans `nodes`**

Remplacer le bloc `data "talos_client_configuration" "this"` existant par :

```hcl
data "talos_client_configuration" "this" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration
  nodes                = [var.node_ip, var.worker_ip]
  endpoints            = [var.node_ip]
}
```

- [ ] **Step 5: Ajouter `worker_ip` à `terraform.tfvars.example`**

Ajouter dans `tofu/bootstrap/terraform.tfvars.example` (après `node_ip`) :

```hcl
worker_ip = "192.168.1.XXX"  # IP DHCP du worker au moment du provisioning
```

- [ ] **Step 6: Valider la configuration**

```bash
cd tofu/bootstrap
tofu validate
```

Résultat attendu : `Success! The configuration is valid.`

```bash
tofu plan -var worker_ip=1.2.3.4
```

Résultat attendu : plan montrant `talos_machine_configuration_apply.worker` à créer, sans erreur.

- [ ] **Step 7: Commit**

```bash
git add talos/patches/worker.yaml tofu/bootstrap/variables.tf tofu/bootstrap/main.tf tofu/bootstrap/terraform.tfvars.example
git commit -m "feat: add worker node OpenTofu resources with KubeSpan support"
```

---

### Task 3: Booter le noeud worker et le joindre au cluster

**Goal:** Démarrer le noeud worker en PXE, pousser sa machineconfig, et vérifier qu'il rejoint le cluster avec KubeSpan actif.

**Files:**
- Modify: `tofu/bootstrap/terraform.tfvars` (non-commité, gitignored)

**Acceptance Criteria:**
- [ ] `kubectl get nodes` montre le worker avec statut `Ready`
- [ ] `talosctl get kubespanidentities -n <WORKER_IP>` retourne une identité KubeSpan
- [ ] `talosctl get kubespanpeers -n <NODE_IP>` montre le worker comme peer connecté

**Verify:** `kubectl get nodes --kubeconfig tofu/bootstrap/kubeconfig.yaml` → deux lignes, les deux en `Ready`

**Steps:**

- [ ] **Step 1: Booter le noeud worker en PXE**

Démarrer la machine physique. Elle boot en vanilla Talos et attend en maintenance mode sur le port 50000.

Vérifier qu'elle est accessible :
```bash
talosctl --talosconfig /dev/null get version -n <WORKER_IP> --insecure
```
Résultat attendu : version Talos affichée (mode maintenance).

- [ ] **Step 2: Ajouter `worker_ip` dans `terraform.tfvars`**

Dans `tofu/bootstrap/terraform.tfvars`, ajouter :
```hcl
worker_ip = "<IP_ACTUELLE_DU_WORKER>"
```

- [ ] **Step 3: Pousser la machineconfig au worker**

```bash
cd tofu/bootstrap
tofu apply
```

Tofu va exécuter `talos_machine_configuration_apply.worker` et pousser la config. Le noeud va redémarrer avec sa configuration définitive.

- [ ] **Step 4: Attendre que le worker rejoigne le cluster**

```bash
kubectl get nodes --kubeconfig tofu/bootstrap/kubeconfig.yaml -w
```

Attendre que le worker passe de `NotReady` à `Ready` (peut prendre 1-2 minutes).

- [ ] **Step 5: Vérifier KubeSpan entre les deux noeuds**

```bash
# Identité KubeSpan du worker
talosctl get kubespanidentities -n <WORKER_IP> --talosconfig tofu/bootstrap/talosconfig.yaml

# Peers KubeSpan vus depuis le control plane
talosctl get kubespanpeers -n <NODE_IP> --talosconfig tofu/bootstrap/talosconfig.yaml
```

Résultat attendu : le worker apparaît comme peer avec statut `up`.
