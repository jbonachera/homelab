# Design : Ajout d'un noeud worker Talos avec KubeSpan

**Date:** 2026-06-13

## Contexte

Le cluster est actuellement single-node (control plane uniquement). On ajoute un premier noeud worker physique provisionné via PXE avec une IP DHCP. KubeSpan (WireGuard managé par Talos) assure la stabilité des communications inter-noeuds indépendamment de l'IP physique.

## Architecture réseau

KubeSpan crée un mesh WireGuard automatique entre tous les noeuds. Chaque noeud annonce ses endpoints physiques via des annotations sur l'objet `Node` Kubernetes. Le control plane et le worker se découvrent mutuellement et établissent un tunnel chiffré. Si l'IP DHCP du worker change après un reboot, KubeSpan re-négocie le tunnel sans intervention manuelle.

Le sous-réseau KubeSpan (ex. `192.168.254.0/24`) est distinct du réseau physique et du réseau pod/service — à confirmer lors de l'implémentation selon les réseaux déjà utilisés.

## Changements

### `talos/patches/all.yaml`

Ajout de l'activation KubeSpan — s'applique au control plane existant et au nouveau worker :

```yaml
machine:
  network:
    kubespan:
      enabled: true
```

### `talos/patches/worker.yaml` (nouveau)

Patch vide pour l'instant, prêt à accueillir des configs spécifiques worker (labels, taints, disques, etc.) :

```yaml
machine: {}
```

### `tofu/bootstrap/main.tf`

Nouveau bloc worker :

- `data.talos_machine_configuration.worker` — type `worker`, patches `all.yaml` + `worker.yaml`
- `talos_machine_configuration_apply.worker` — push config via l'IP DHCP du moment du provisioning
- `talos_client_configuration` mis à jour — worker ajouté dans `nodes` et `endpoints`

### `tofu/bootstrap/variables.tf`

Nouvelle variable `worker_ip` — IP temporaire utilisée uniquement au moment du push de config (peut changer après, KubeSpan prend le relais).

## Flux de provisioning

```
PXE boot → maintenance mode (port 50000)
→ tofu apply → talos_machine_configuration_apply.worker (push via worker_ip)
→ KubeSpan s'active sur les deux noeuds
→ tunnel WireGuard control plane ↔ worker établi
→ kubelet rejoint le cluster
```

## Contraintes

- `apply_mode = "auto"` conservé — Talos décide si un reboot est nécessaire
- Le control plane existant recevra la mise à jour KubeSpan via `talos_machine_configuration_apply.controlplane` — pas de reboot attendu pour l'ajout de KubeSpan seul
- Le worker est générique : aucun label, taint, ou stockage spécifique
