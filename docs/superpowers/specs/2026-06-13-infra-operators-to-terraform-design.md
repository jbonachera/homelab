# Design : Déplacement des opérateurs infrastructure vers Terraform

**Date :** 2026-06-13  
**Statut :** Approuvé

## Contexte et motivation

L'infrastructure est actuellement entièrement gérée par Flux CD via des `HelmRelease` et `Kustomization` imbriquées. Plusieurs bugs de production ont mis en évidence une fragilité structurelle : les opérateurs (MetalLB, Traefik, ESO, NFS) et leurs Custom Resources sont réconciliés dans le même cycle Flux, provoquant des races entre l'enregistrement des CRDs et la création des CRs qui en dépendent.

Exemples de fixes symptomatiques dans l'historique git :
- Séparation de `timescaledb-config` en Kustomization indépendante pour éviter la race CRD ESO
- Suppression du `wait: true` sur TimescaleDB pour briser une dépendance circulaire
- Ajout de `healthChecks` CRD sur ESO

## Approche retenue : Hybrid Terraform + Flux

Les opérateurs (installation de CRDs + controllers via Helm) passent dans Terraform. Flux conserve les Custom Resources qui consomment ces CRDs et les workloads applicatifs.

**Principe :** Terraform garantit que les opérateurs sont `Ready` (CRDs enregistrés) avant que Flux commence à réconcilier. Les races disparaissent structurellement.

---

## Frontière de découpage

### Terraform gère (nouveaux `helm_release`)

| Composant | Chart | Namespace |
|---|---|---|
| MetalLB | `metallb/metallb` | `metallb-system` |
| Traefik | `traefik/traefik` | `traefik-system` |
| External Secrets Operator | `external-secrets/external-secrets` | `external-secrets` |
| NFS subdir provisioner | `nfs-subdir-external-provisioner/nfs-subdir-external-provisioner` | `nfs-provisioner` |

### Flux conserve

| Composant | Raison |
|---|---|
| `metallb-config/` | Consomme CRDs MetalLB (`IPAddressPool`, `L2Advertisement`) |
| `traefik-config/` | Consomme CRD Traefik (`IngressRoute`) |
| `timescaledb/` | StatefulSet stateful, dépend du secret créé par ESO |
| `timescaledb-config/` | Consomme CRDs ESO (`Password`, `ClusterSecretStore`, `ExternalSecret`) |
| `apps/` | Inchangé |

---

## Changements Terraform

### Nouveau provider dans `tofu/main.tf`

```hcl
terraform {
  required_providers {
    talos = { source = "siderolabs/talos", version = "~> 0.11" }
    local = { source = "hashicorp/local",  version = "~> 2.5" }
    helm  = { source = "hashicorp/helm",   version = "~> 2.16" }
  }
}

provider "helm" {
  kubernetes {
    config_path = "${path.module}/kubeconfig.yaml"
  }
}
```

Le provider Helm réutilise `kubeconfig.yaml` déjà généré par la ressource `talos_cluster_kubeconfig`.

### Nouveau fichier `tofu/operators.tf`

Contient les 4 `helm_release`. Points clés :
- `wait = true` sur chaque release — bloque jusqu'à `Ready` + CRDs enregistrés
- `depends_on = [talos_machine_bootstrap.this]` — garantit que le cluster existe
- NFS provisioner : `depends_on = [helm_release.traefik]` (conserve l'ordering existant)

### Nouvelles variables (`tofu/variables.tf` + `tofu/terraform.tfvars`)

```hcl
# Versions de chart — pinned explicitement (le provider Helm n'accepte pas les globs)
variable "chart_metallb_version"  { default = "0.14.9" }
variable "chart_traefik_version"  { default = "34.4.0" }
variable "chart_eso_version"      { default = "0.11.0" }
variable "chart_nfs_version"      { default = "4.0.18" }

# NFS — remplacent le ConfigMap cluster-vars.yaml gitignored
variable "nfs_server" {}
variable "nfs_path"   {}
```

`nfs_server` et `nfs_path` migrent de `kubernetes/infrastructure/nfs-provisioner/cluster-vars.yaml` (ConfigMap manuel, gitignored) vers `terraform.tfvars` (gitignored).

---

## Structure Flux simplifiée

### `kubernetes/infrastructure/kustomization.yaml` (cible)

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - metallb-config.yaml
  - traefik-config.yaml
  - timescaledb.yaml
  - timescaledb-config.yaml
```

### Fichiers et dossiers supprimés

- `kubernetes/infrastructure/sources/` (4 `HelmRepository` Flux)
- `kubernetes/infrastructure/metallb-operator/` + `metallb-operator.yaml`
- `kubernetes/infrastructure/traefik-operator/` + `traefik-operator.yaml`
- `kubernetes/infrastructure/external-secrets/` + `external-secrets.yaml`
- `kubernetes/infrastructure/nfs-provisioner/` + `nfs-provisioner.yaml`

### Graphe de dépendances Flux (cible)

```
metallb-config      → aucune dépendance (CRDs MetalLB présents via Terraform)
traefik-config      → aucune dépendance (CRDs Traefik présents via Terraform)
timescaledb         → aucune dépendance (nfs-client StorageClass présent via Terraform)
timescaledb-config  → dependsOn: timescaledb
home-assistant      → dependsOn: infrastructure
```

### Ajout : `healthChecks` sur `timescaledb-config`

```yaml
# kubernetes/infrastructure/timescaledb-config.yaml
healthChecks:
  - apiVersion: external-secrets.io/v1beta1
    kind: ExternalSecret
    name: timescaledb-credentials
    namespace: database
```

Garantit que le secret est effectivement créé avant que Flux marque l'infrastructure comme `Ready` et débloque `home-assistant`.

---

## Séquence de bootstrap (from scratch)

```
1. tofu apply
   ├── Talos : secrets + machineconfig + bootstrap + kubeconfig
   └── Operators : MetalLB + Traefik + ESO + NFS (bloque jusqu'à Ready)

2. Flux auto-réconcilie
   ├── metallb-config   → IPAddressPool + L2Advertisement
   ├── traefik-config   → IngressRoute dashboard
   ├── timescaledb      → namespace + StatefulSet + Service
   ├── timescaledb-config → Password + ClusterSecretStore + ExternalSecret
   │   ESO tourne déjà → secret timescaledb-credentials créé immédiatement
   └── home-assistant   → dependsOn: infrastructure
```

Le `kubectl apply -f cluster-vars.yaml` manuel disparaît du workflow.

---

## Ce qui ne change pas

- `kubernetes/apps/` — inchangé
- `kubernetes/flux-system/` — inchangé
- Secrets SOPS/age — inchangés (Flux continue de déchiffrer via `sops-age`)
- `kubernetes/infrastructure/timescaledb/` — inchangé
- `kubernetes/infrastructure/timescaledb-config/` — inchangé (sauf `dependsOn` simplifié)
- `kubernetes/apps.yaml` / root Kustomizations — inchangés

---

## Compromis acceptés

- **Versions de chart pinned** : Terraform ne supporte pas les globs (`34.*`). Les mises à jour de chart nécessitent un `tofu apply` plutôt qu'un commit YAML. Acceptable pour des composants infrastructure qui changent rarement.
- **Pas de drift detection pour les opérateurs** : Terraform ne réconcilie pas en continu. Une modification manuelle d'un déploiement MetalLB ne serait pas auto-corrigée. Acceptable pour un homelab single-node.
- **Deux outils** : Bootstrap nécessite `tofu` ET Flux. L'ordre est documenté et simple.
