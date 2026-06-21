# Servarr Stack — Design Spec
*Date: 2026-06-21*

## Scope

Déploiement de la stack Servarr complète sur le homelab Talos/Flux existant.

**Applications incluses :**
- Prowlarr — proxy d'indexeurs
- Radarr — gestionnaire de films
- Sonarr — gestionnaire de séries TV
- Lidarr — gestionnaire de musique
- Readarr — gestionnaire de livres/ebooks
- Bazarr — sous-titres automatiques
- qBittorrent — client torrent

## Architecture

Option retenue : **namespace unique `media`** — toutes les apps dans `kubernetes/apps/media/`, cohérent avec le pattern existant (`home-assistant/`). Flux GitOps gère tout.

## Structure des fichiers

```
kubernetes/apps/
└── media/
    ├── kustomization.yaml
    ├── namespace.yaml
    ├── prowlarr/
    │   ├── kustomization.yaml
    │   ├── deployment.yaml
    │   ├── service.yaml
    │   ├── pvc.yaml
    │   └── ingress.yaml
    ├── radarr/
    ├── sonarr/
    ├── lidarr/
    ├── readarr/
    ├── bazarr/
    └── qbittorrent/
        ├── kustomization.yaml
        ├── deployment.yaml
        ├── service.yaml
        ├── pvc.yaml
        └── ingress.yaml
```

`kubernetes/apps/media.yaml` — Flux `Kustomization` CRD pointant vers `kubernetes/apps/media/`.

## Stockage

### Configs (PVCs dynamiques — nfs-provisioner)

Un PVC par app, `ReadWriteOnce`, 1Gi :
- `prowlarr-config`, `radarr-config`, `sonarr-config`, `lidarr-config`, `readarr-config`, `bazarr-config`, `qbittorrent-config`

### Médias (PVs statiques NFS, `ReadWriteMany`)

| PV | Chemin NFS | Utilisé par |
|----|-----------|------------|
| `media-downloads` | `/media/downloads` | qBittorrent (écriture), tous les *arr (lecture/déplacement) |
| `media-movies` | `/media/movies` | Radarr |
| `media-tv` | `/media/tv` | Sonarr |
| `media-music` | `/media/music` | Lidarr |
| `media-books` | `/media/books` | Readarr |

Le partage `downloads` en `ReadWriteMany` permet les hardlinks entre qBittorrent et les *arr (évite la copie de fichiers).

> **À renseigner à l'implémentation :** IP du serveur NFS et chemins d'export exacts.

## Réseau

### Communication interne

Les *arr pointent vers leurs dépendances via DNS Kubernetes :
- `http://prowlarr.media.svc.cluster.local:9696`
- `http://qbittorrent.media.svc.cluster.local:8080`

### Exposition Traefik

Une `IngressRoute` par app, domaine interne `homelab.lan` :

| App | URL |
|-----|-----|
| Prowlarr | `prowlarr.homelab.lan` |
| Radarr | `radarr.homelab.lan` |
| Sonarr | `sonarr.homelab.lan` |
| Lidarr | `lidarr.homelab.lan` |
| Readarr | `readarr.homelab.lan` |
| Bazarr | `bazarr.homelab.lan` |
| qBittorrent | `qbittorrent.homelab.lan` |

## Images et ports

| App | Image | Port |
|-----|-------|------|
| Prowlarr | `ghcr.io/hotio/prowlarr:latest` | 9696 |
| Radarr | `ghcr.io/hotio/radarr:latest` | 7878 |
| Sonarr | `ghcr.io/hotio/sonarr:latest` | 8989 |
| Lidarr | `ghcr.io/hotio/lidarr:latest` | 8686 |
| Readarr | `ghcr.io/hotio/readarr:latest` | 8787 |
| Bazarr | `ghcr.io/hotio/bazarr:latest` | 6767 |
| qBittorrent | `ghcr.io/hotio/qbittorrent:latest` | 8080 |

Toutes les apps : `PUID=1000`, `PGID=1000` — à aligner avec l'UID propriétaire des exports NFS.

## Secrets

Pas de secrets SOPS nécessaires pour le déploiement initial :
- Les API keys *arr sont générées au premier démarrage et stockées dans les configs.
- Le mot de passe qBittorrent est configuré via l'UI après premier démarrage.

Si une pré-configuration programmatique est souhaitée ultérieurement, des `Secret` SOPS peuvent être ajoutés.

## Dépendances Flux

```
infrastructure (wait: true)
  └── apps (dependsOn: infrastructure)
        └── media (nouveau)
```

`media.yaml` suit le même pattern que les Kustomizations existantes dans `kubernetes/apps/`.
