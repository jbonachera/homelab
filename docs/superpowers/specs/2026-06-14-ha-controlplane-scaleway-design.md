# Design : HA Control-Plane — Promotion worker + noeud Scaleway

**Date:** 2026-06-14

## Contexte

Le cluster est actuellement composé de :
- CP1 : noeud physique local, rôle `controlplane`, etcd single-node
- Worker : noeud physique local, rôle `worker`, déjà joint avec KubeSpan actif

L'objectif est d'atteindre un quorum etcd 3/3 résilient en ajoutant un 2e control-plane sur Scaleway (cloud) et en promouvant le worker existant en 3e control-plane.

## Architecture cible

| Noeud | Emplacement | Rôle | Workloads |
|---|---|---|---|
| CP1 (actuel) | Physique local | controlplane | Oui (`allowSchedulingOnControlPlanes: true`) |
| CP2 (Scaleway) | Cloud Scaleway | controlplane | Non (taint `NoSchedule`) |
| CP3 (ancien worker) | Physique local | controlplane | Oui |

KubeSpan (WireGuard managé par Talos) connecte les 3 noeuds en mesh chiffré. Le trafic etcd inter-noeuds (ports 2379/2380) passe exclusivement par KubeSpan — etcd n'est pas exposé publiquement.

`cluster_endpoint` reste pointé sur CP1 (`var.node_ip`) — point d'entrée interne stable.

## Ordre de déploiement (Option B — Scaleway d'abord)

1. `tofu/scaleway/` apply → instance Scaleway créée, image Talos uploadée
2. `tofu/bootstrap/` apply (Scaleway) → CP2 rejoint etcd (quorum 2/2)
3. `tofu/bootstrap/` apply (worker→controlplane) → CP3 rejoint etcd (quorum 3/3 HA)

## Changements

### `tofu/scaleway/` (nouveau state root)

Nouveau répertoire indépendant. Provider : `scaleway/scaleway`.

Ressources :
- `scaleway_object_bucket` + `scaleway_object_bucket_object` — upload image raw Talos depuis `factory.talos.dev`
- `scaleway_instance_snapshot` — snapshot depuis l'objet S3
- `scaleway_instance_image` — image bootable depuis le snapshot
- `scaleway_instance_server` — instance DEV1-S ou similaire, boot sur l'image Talos
- Security group : ports 50000 (Talos API) et 6443 (kube-apiserver) ouverts depuis l'IP de l'opérateur ; UDP 51820 (KubeSpan/WireGuard) ouvert depuis partout

Outputs : `scaleway_ip` (IP publique de l'instance)

Variables (`terraform.tfvars`, gitignored) :
```hcl
scaleway_access_key  = "..."
scaleway_secret_key  = "..."
scaleway_project_id  = "..."
scaleway_zone        = "fr-par-1"
talos_version        = "v1.13.0"
talos_image_url      = "https://factory.talos.dev/image/.../scaleway/talos-amd64.raw.xz"
```

### `tofu/bootstrap/main.tf`

1. Nouveau `data.talos_machine_configuration.scaleway` — type `controlplane`, patches `all.yaml` + `controlplane-scaleway.yaml`
2. Nouveau `talos_machine_configuration_apply.scaleway` — push config sur `var.scaleway_ip`
3. `data.talos_machine_configuration.worker` : `machine_type` passe de `worker` → `controlplane`, patches `all.yaml` + `controlplane.yaml`
4. `data.talos_client_configuration` : `scaleway_ip` ajouté dans `nodes` et `endpoints`

### `tofu/bootstrap/variables.tf`

Nouvelle variable `scaleway_ip` :
```hcl
variable "scaleway_ip" {
  description = "IP publique du noeud Scaleway (output de tofu/scaleway)"
  type        = string
}
```

`worker_ip` reste inchangé — même IP physique, utilisée pour pusher la nouvelle config controlplane.

### `talos/patches/controlplane-scaleway.yaml` (nouveau)

```yaml
machine:
  nodeLabels:
    homelab/location: scaleway
  nodeTaints:
    node-role.kubernetes.io/scaleway: NoSchedule
```

### `talos/patches/worker.yaml`

Supprimé ou conservé vide — n'est plus référencé après la promotion.

## Flux de provisioning détaillé

```
# Étape 1 — Image + instance Scaleway
tofu -chdir=tofu/scaleway apply
→ image Talos uploadée sur Object Storage
→ snapshot + image créés
→ instance DEV1-S bootée en maintenance mode (port 50000)
→ output: scaleway_ip

# Étape 2 — Push config CP2
# Ajouter scaleway_ip dans tofu/bootstrap/terraform.tfvars
tofu -chdir=tofu/bootstrap apply -target=talos_machine_configuration_apply.scaleway
→ config controlplane pushée via IP publique Scaleway
→ KubeSpan s'active → tunnel WireGuard CP1 ↔ CP2
→ etcd rejoint le cluster (quorum 2/2)

# Étape 3 — Promotion worker → controlplane
tofu -chdir=tofu/bootstrap apply
→ nouvelle config controlplane pushée sur worker_ip
→ Talos redémarre les services etcd/apiserver
→ etcd rejoint (quorum 3/3 — HA atteinte)
```

## Contraintes réseau

- Ports 50000 et 6443 accessibles depuis la machine opérateur vers l'IP Scaleway (pour `tofu apply`)
- UDP 51820 ouvert en entrée sur l'instance Scaleway (KubeSpan)
- etcd (2379/2380) : trafic uniquement via KubeSpan, jamais exposé publiquement

## Secrets

Pas de nouveau secret Talos — `talos_machine_secrets` existant dans `tofu/bootstrap/` est partagé par les 3 noeuds. Le noeud Scaleway reçoit une `talos_machine_configuration` générée depuis ces mêmes secrets.

`tofu/scaleway/terraform.tfvars` gitignored. Un `terraform.tfvars.example` est créé pour documenter les variables.
