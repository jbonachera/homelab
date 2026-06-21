# Servarr Stack Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Déployer la stack Servarr complète (Prowlarr, Radarr, Sonarr, Lidarr, Readarr, Bazarr, qBittorrent) dans le namespace `media` via Flux GitOps.

**Architecture:** Namespace unique `media`, chaque app dans son propre sous-répertoire `kubernetes/apps/media/<app>/`. Configs en PVCs dynamiques NFS (`nfs-client`), médias en PVs statiques NFS partagés (`ReadWriteMany`). Exposition via Ingress Traefik standard (pattern identique à `home-assistant`).

**Tech Stack:** Talos Linux, Flux CD, Kubernetes, images hotio/*arr, Traefik Ingress, nfs-client StorageClass.

**User decisions (already made):**
- Apps : Prowlarr + Radarr + Sonarr + Lidarr + Readarr + Bazarr + qBittorrent
- Pas de serveur média pour l'instant (Jellyfin/Plex reporté)
- Client torrent uniquement : qBittorrent
- Exposition via Traefik IngressRoute (`ingressClassName: traefik`)
- Stockage NFS (configs via nfs-client dynamique, médias via PVs statiques)
- Domaine interne : `homelab.lan`
- Images : `ghcr.io/hotio/*`, PUID=1000, PGID=1000

---

## Prérequis

Avant de commencer, noter :
- `NFS_SERVER_IP` : IP du serveur NFS (ex: `192.168.1.10`)
- `NFS_BASE_PATH` : Chemin racine sur le NFS (ex: `/mnt/pool/media`)

Ces deux valeurs doivent remplacer les placeholders dans Task 2.

---

### Task 1 : Scaffold namespace + Flux Kustomization

**Goal:** Créer le namespace `media`, le `kustomization.yaml` racine du dossier, et enregistrer la Flux Kustomization CRD dans `kubernetes/apps/`.

**Files:**
- Create: `kubernetes/apps/media/namespace.yaml`
- Create: `kubernetes/apps/media/kustomization.yaml`
- Create: `kubernetes/apps/media.yaml`
- Modify: `kubernetes/apps/kustomization.yaml`

**Acceptance Criteria:**
- [ ] `kubernetes/apps/media/namespace.yaml` crée le namespace `media`
- [ ] `kubernetes/apps/media/kustomization.yaml` liste tous les sous-dossiers (sera complété au fil des tâches)
- [ ] `kubernetes/apps/media.yaml` est une Flux Kustomization CRD valide avec `dependsOn: infrastructure`
- [ ] `kubernetes/apps/kustomization.yaml` référence `media.yaml`
- [ ] `mise exec -- yamllint kubernetes/apps/media/ kubernetes/apps/media.yaml` passe sans erreur

**Verify:** `mise exec -- yamllint kubernetes/apps/media/ kubernetes/apps/media.yaml` → aucune erreur

**Steps:**

- [ ] **Step 1 : Créer `kubernetes/apps/media/namespace.yaml`**

```yaml
# kubernetes/apps/media/namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: media
  labels:
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/enforce-version: latest
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/warn-version: latest
```

- [ ] **Step 2 : Créer `kubernetes/apps/media/kustomization.yaml` (squelette)**

```yaml
# kubernetes/apps/media/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - nfs-volumes.yaml
  - qbittorrent
  - prowlarr
  - radarr
  - sonarr
  - lidarr
  - readarr
  - bazarr
```

- [ ] **Step 3 : Créer `kubernetes/apps/media.yaml`**

```yaml
# kubernetes/apps/media.yaml
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: media
  namespace: flux-system
spec:
  interval: 10m0s
  path: ./kubernetes/apps/media
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
  dependsOn:
    - name: infrastructure
```

- [ ] **Step 4 : Ajouter `media.yaml` dans `kubernetes/apps/kustomization.yaml`**

Ajouter `- media.yaml` à la liste `resources` existante.

- [ ] **Step 5 : Linter**

```bash
mise exec -- yamllint kubernetes/apps/media/ kubernetes/apps/media.yaml
```

- [ ] **Step 6 : Commit**

```bash
git add kubernetes/apps/media/ kubernetes/apps/media.yaml kubernetes/apps/kustomization.yaml
git commit -m "feat(media): scaffold namespace and Flux Kustomization"
```

---

### Task 2 : PVs et PVCs NFS partagés pour les médias

**Goal:** Créer les PersistentVolumes et PersistentVolumeClaims NFS statiques partagés (`ReadWriteMany`) pour les répertoires médias.

**Files:**
- Create: `kubernetes/apps/media/nfs-volumes.yaml`

**Acceptance Criteria:**
- [ ] 5 PVs NFS créés : `media-downloads`, `media-movies`, `media-tv`, `media-music`, `media-books`
- [ ] 5 PVCs correspondants en `ReadWriteMany` dans le namespace `media`
- [ ] `mise exec -- yamllint kubernetes/apps/media/nfs-volumes.yaml` passe sans erreur

**Verify:** `mise exec -- yamllint kubernetes/apps/media/nfs-volumes.yaml` → aucune erreur

**Steps:**

- [ ] **Step 1 : Remplacer les placeholders**

Avant de créer le fichier, obtenir auprès de l'utilisateur :
- `NFS_SERVER_IP` (ex: `192.168.1.10`)
- `NFS_BASE_PATH` (ex: `/mnt/pool/media`)

- [ ] **Step 2 : Créer `kubernetes/apps/media/nfs-volumes.yaml`**

Remplacer `<NFS_SERVER_IP>` et `<NFS_BASE_PATH>` par les vraies valeurs.

```yaml
# kubernetes/apps/media/nfs-volumes.yaml
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: media-downloads
spec:
  capacity:
    storage: 500Gi
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Retain
  nfs:
    server: <NFS_SERVER_IP>
    path: <NFS_BASE_PATH>/downloads
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: media-downloads
  namespace: media
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 500Gi
  volumeName: media-downloads
  storageClassName: ""
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: media-movies
spec:
  capacity:
    storage: 2Ti
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Retain
  nfs:
    server: <NFS_SERVER_IP>
    path: <NFS_BASE_PATH>/movies
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: media-movies
  namespace: media
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 2Ti
  volumeName: media-movies
  storageClassName: ""
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: media-tv
spec:
  capacity:
    storage: 2Ti
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Retain
  nfs:
    server: <NFS_SERVER_IP>
    path: <NFS_BASE_PATH>/tv
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: media-tv
  namespace: media
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 2Ti
  volumeName: media-tv
  storageClassName: ""
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: media-music
spec:
  capacity:
    storage: 500Gi
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Retain
  nfs:
    server: <NFS_SERVER_IP>
    path: <NFS_BASE_PATH>/music
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: media-music
  namespace: media
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 500Gi
  volumeName: media-music
  storageClassName: ""
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: media-books
spec:
  capacity:
    storage: 100Gi
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Retain
  nfs:
    server: <NFS_SERVER_IP>
    path: <NFS_BASE_PATH>/books
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: media-books
  namespace: media
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 100Gi
  volumeName: media-books
  storageClassName: ""
```

- [ ] **Step 3 : Linter**

```bash
mise exec -- yamllint kubernetes/apps/media/nfs-volumes.yaml
```

- [ ] **Step 4 : Commit**

```bash
git add kubernetes/apps/media/nfs-volumes.yaml
git commit -m "feat(media): add NFS PVs and PVCs for media directories"
```

---

### Task 3 : qBittorrent

**Goal:** Déployer qBittorrent (client torrent) avec sa config en PVC dynamique et accès aux `downloads` NFS.

**Files:**
- Create: `kubernetes/apps/media/qbittorrent/kustomization.yaml`
- Create: `kubernetes/apps/media/qbittorrent/pvc.yaml`
- Create: `kubernetes/apps/media/qbittorrent/deployment.yaml`
- Create: `kubernetes/apps/media/qbittorrent/service.yaml`
- Create: `kubernetes/apps/media/qbittorrent/ingress.yaml`

**Acceptance Criteria:**
- [ ] PVC `qbittorrent-config` en `ReadWriteOnce` 1Gi via `nfs-client`
- [ ] Deployment monte `/config` (PVC) et `/downloads` (PVC `media-downloads`)
- [ ] Service ClusterIP exposé sur port 8080
- [ ] Ingress sur `qbittorrent.homelab.lan`
- [ ] `mise exec -- yamllint kubernetes/apps/media/qbittorrent/` → aucune erreur

**Verify:** `mise exec -- yamllint kubernetes/apps/media/qbittorrent/` → aucune erreur

**Steps:**

- [ ] **Step 1 : `kubernetes/apps/media/qbittorrent/kustomization.yaml`**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - pvc.yaml
  - deployment.yaml
  - service.yaml
  - ingress.yaml
```

- [ ] **Step 2 : `kubernetes/apps/media/qbittorrent/pvc.yaml`**

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: qbittorrent-config
  namespace: media
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: nfs-client
  resources:
    requests:
      storage: 1Gi
```

- [ ] **Step 3 : `kubernetes/apps/media/qbittorrent/deployment.yaml`**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: qbittorrent
  namespace: media
spec:
  replicas: 1
  selector:
    matchLabels:
      app: qbittorrent
  template:
    metadata:
      labels:
        app: qbittorrent
    spec:
      containers:
        - name: qbittorrent
          image: ghcr.io/hotio/qbittorrent:latest
          ports:
            - containerPort: 8080
          env:
            - name: PUID
              value: "1000"
            - name: PGID
              value: "1000"
            - name: UMASK
              value: "002"
            - name: TZ
              value: "Europe/Paris"
          readinessProbe:
            httpGet:
              path: /
              port: 8080
            initialDelaySeconds: 20
            periodSeconds: 10
            failureThreshold: 6
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              memory: 512Mi
          volumeMounts:
            - name: config
              mountPath: /config
            - name: downloads
              mountPath: /downloads
      volumes:
        - name: config
          persistentVolumeClaim:
            claimName: qbittorrent-config
        - name: downloads
          persistentVolumeClaim:
            claimName: media-downloads
```

- [ ] **Step 4 : `kubernetes/apps/media/qbittorrent/service.yaml`**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: qbittorrent
  namespace: media
spec:
  type: ClusterIP
  selector:
    app: qbittorrent
  ports:
    - port: 8080
      targetPort: 8080
```

- [ ] **Step 5 : `kubernetes/apps/media/qbittorrent/ingress.yaml`**

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: qbittorrent
  namespace: media
spec:
  ingressClassName: traefik
  rules:
    - host: qbittorrent.homelab.lan
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: qbittorrent
                port:
                  number: 8080
```

- [ ] **Step 6 : Linter**

```bash
mise exec -- yamllint kubernetes/apps/media/qbittorrent/
```

- [ ] **Step 7 : Commit**

```bash
git add kubernetes/apps/media/qbittorrent/
git commit -m "feat(media): add qBittorrent deployment"
```

---

### Task 4 : Prowlarr

**Goal:** Déployer Prowlarr (proxy d'indexeurs) avec sa config en PVC dynamique.

**Files:**
- Create: `kubernetes/apps/media/prowlarr/kustomization.yaml`
- Create: `kubernetes/apps/media/prowlarr/pvc.yaml`
- Create: `kubernetes/apps/media/prowlarr/deployment.yaml`
- Create: `kubernetes/apps/media/prowlarr/service.yaml`
- Create: `kubernetes/apps/media/prowlarr/ingress.yaml`

**Acceptance Criteria:**
- [ ] PVC `prowlarr-config` en `ReadWriteOnce` 1Gi via `nfs-client`
- [ ] Deployment exposé sur port 9696
- [ ] Service ClusterIP sur port 9696
- [ ] Ingress sur `prowlarr.homelab.lan`
- [ ] `mise exec -- yamllint kubernetes/apps/media/prowlarr/` → aucune erreur

**Verify:** `mise exec -- yamllint kubernetes/apps/media/prowlarr/` → aucune erreur

**Steps:**

- [ ] **Step 1 : `kubernetes/apps/media/prowlarr/kustomization.yaml`**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - pvc.yaml
  - deployment.yaml
  - service.yaml
  - ingress.yaml
```

- [ ] **Step 2 : `kubernetes/apps/media/prowlarr/pvc.yaml`**

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: prowlarr-config
  namespace: media
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: nfs-client
  resources:
    requests:
      storage: 1Gi
```

- [ ] **Step 3 : `kubernetes/apps/media/prowlarr/deployment.yaml`**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: prowlarr
  namespace: media
spec:
  replicas: 1
  selector:
    matchLabels:
      app: prowlarr
  template:
    metadata:
      labels:
        app: prowlarr
    spec:
      containers:
        - name: prowlarr
          image: ghcr.io/hotio/prowlarr:latest
          ports:
            - containerPort: 9696
          env:
            - name: PUID
              value: "1000"
            - name: PGID
              value: "1000"
            - name: UMASK
              value: "002"
            - name: TZ
              value: "Europe/Paris"
          readinessProbe:
            httpGet:
              path: /
              port: 9696
            initialDelaySeconds: 20
            periodSeconds: 10
            failureThreshold: 6
          resources:
            requests:
              cpu: 50m
              memory: 128Mi
            limits:
              memory: 256Mi
          volumeMounts:
            - name: config
              mountPath: /config
      volumes:
        - name: config
          persistentVolumeClaim:
            claimName: prowlarr-config
```

- [ ] **Step 4 : `kubernetes/apps/media/prowlarr/service.yaml`**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: prowlarr
  namespace: media
spec:
  type: ClusterIP
  selector:
    app: prowlarr
  ports:
    - port: 9696
      targetPort: 9696
```

- [ ] **Step 5 : `kubernetes/apps/media/prowlarr/ingress.yaml`**

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: prowlarr
  namespace: media
spec:
  ingressClassName: traefik
  rules:
    - host: prowlarr.homelab.lan
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: prowlarr
                port:
                  number: 9696
```

- [ ] **Step 6 : Linter et commit**

```bash
mise exec -- yamllint kubernetes/apps/media/prowlarr/
git add kubernetes/apps/media/prowlarr/
git commit -m "feat(media): add Prowlarr deployment"
```

---

### Task 5 : Radarr

**Goal:** Déployer Radarr (gestionnaire de films) avec accès à `downloads` et `movies`.

**Files:**
- Create: `kubernetes/apps/media/radarr/kustomization.yaml`
- Create: `kubernetes/apps/media/radarr/pvc.yaml`
- Create: `kubernetes/apps/media/radarr/deployment.yaml`
- Create: `kubernetes/apps/media/radarr/service.yaml`
- Create: `kubernetes/apps/media/radarr/ingress.yaml`

**Acceptance Criteria:**
- [ ] PVC `radarr-config` en `ReadWriteOnce` 1Gi via `nfs-client`
- [ ] Deployment monte `/config`, `/downloads` (`media-downloads`), `/movies` (`media-movies`)
- [ ] Service ClusterIP sur port 7878
- [ ] Ingress sur `radarr.homelab.lan`
- [ ] `mise exec -- yamllint kubernetes/apps/media/radarr/` → aucune erreur

**Verify:** `mise exec -- yamllint kubernetes/apps/media/radarr/` → aucune erreur

**Steps:**

- [ ] **Step 1 : `kubernetes/apps/media/radarr/kustomization.yaml`**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - pvc.yaml
  - deployment.yaml
  - service.yaml
  - ingress.yaml
```

- [ ] **Step 2 : `kubernetes/apps/media/radarr/pvc.yaml`**

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: radarr-config
  namespace: media
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: nfs-client
  resources:
    requests:
      storage: 1Gi
```

- [ ] **Step 3 : `kubernetes/apps/media/radarr/deployment.yaml`**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: radarr
  namespace: media
spec:
  replicas: 1
  selector:
    matchLabels:
      app: radarr
  template:
    metadata:
      labels:
        app: radarr
    spec:
      containers:
        - name: radarr
          image: ghcr.io/hotio/radarr:latest
          ports:
            - containerPort: 7878
          env:
            - name: PUID
              value: "1000"
            - name: PGID
              value: "1000"
            - name: UMASK
              value: "002"
            - name: TZ
              value: "Europe/Paris"
          readinessProbe:
            httpGet:
              path: /
              port: 7878
            initialDelaySeconds: 20
            periodSeconds: 10
            failureThreshold: 6
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              memory: 512Mi
          volumeMounts:
            - name: config
              mountPath: /config
            - name: downloads
              mountPath: /downloads
            - name: movies
              mountPath: /movies
      volumes:
        - name: config
          persistentVolumeClaim:
            claimName: radarr-config
        - name: downloads
          persistentVolumeClaim:
            claimName: media-downloads
        - name: movies
          persistentVolumeClaim:
            claimName: media-movies
```

- [ ] **Step 4 : `kubernetes/apps/media/radarr/service.yaml`**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: radarr
  namespace: media
spec:
  type: ClusterIP
  selector:
    app: radarr
  ports:
    - port: 7878
      targetPort: 7878
```

- [ ] **Step 5 : `kubernetes/apps/media/radarr/ingress.yaml`**

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: radarr
  namespace: media
spec:
  ingressClassName: traefik
  rules:
    - host: radarr.homelab.lan
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: radarr
                port:
                  number: 7878
```

- [ ] **Step 6 : Linter et commit**

```bash
mise exec -- yamllint kubernetes/apps/media/radarr/
git add kubernetes/apps/media/radarr/
git commit -m "feat(media): add Radarr deployment"
```

---

### Task 6 : Sonarr

**Goal:** Déployer Sonarr (gestionnaire de séries TV) avec accès à `downloads` et `tv`.

**Files:**
- Create: `kubernetes/apps/media/sonarr/kustomization.yaml`
- Create: `kubernetes/apps/media/sonarr/pvc.yaml`
- Create: `kubernetes/apps/media/sonarr/deployment.yaml`
- Create: `kubernetes/apps/media/sonarr/service.yaml`
- Create: `kubernetes/apps/media/sonarr/ingress.yaml`

**Acceptance Criteria:**
- [ ] PVC `sonarr-config` en `ReadWriteOnce` 1Gi via `nfs-client`
- [ ] Deployment monte `/config`, `/downloads` (`media-downloads`), `/tv` (`media-tv`)
- [ ] Service ClusterIP sur port 8989
- [ ] Ingress sur `sonarr.homelab.lan`
- [ ] `mise exec -- yamllint kubernetes/apps/media/sonarr/` → aucune erreur

**Verify:** `mise exec -- yamllint kubernetes/apps/media/sonarr/` → aucune erreur

**Steps:**

- [ ] **Step 1 : `kubernetes/apps/media/sonarr/kustomization.yaml`**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - pvc.yaml
  - deployment.yaml
  - service.yaml
  - ingress.yaml
```

- [ ] **Step 2 : `kubernetes/apps/media/sonarr/pvc.yaml`**

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: sonarr-config
  namespace: media
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: nfs-client
  resources:
    requests:
      storage: 1Gi
```

- [ ] **Step 3 : `kubernetes/apps/media/sonarr/deployment.yaml`**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sonarr
  namespace: media
spec:
  replicas: 1
  selector:
    matchLabels:
      app: sonarr
  template:
    metadata:
      labels:
        app: sonarr
    spec:
      containers:
        - name: sonarr
          image: ghcr.io/hotio/sonarr:latest
          ports:
            - containerPort: 8989
          env:
            - name: PUID
              value: "1000"
            - name: PGID
              value: "1000"
            - name: UMASK
              value: "002"
            - name: TZ
              value: "Europe/Paris"
          readinessProbe:
            httpGet:
              path: /
              port: 8989
            initialDelaySeconds: 20
            periodSeconds: 10
            failureThreshold: 6
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              memory: 512Mi
          volumeMounts:
            - name: config
              mountPath: /config
            - name: downloads
              mountPath: /downloads
            - name: tv
              mountPath: /tv
      volumes:
        - name: config
          persistentVolumeClaim:
            claimName: sonarr-config
        - name: downloads
          persistentVolumeClaim:
            claimName: media-downloads
        - name: tv
          persistentVolumeClaim:
            claimName: media-tv
```

- [ ] **Step 4 : `kubernetes/apps/media/sonarr/service.yaml`**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: sonarr
  namespace: media
spec:
  type: ClusterIP
  selector:
    app: sonarr
  ports:
    - port: 8989
      targetPort: 8989
```

- [ ] **Step 5 : `kubernetes/apps/media/sonarr/ingress.yaml`**

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: sonarr
  namespace: media
spec:
  ingressClassName: traefik
  rules:
    - host: sonarr.homelab.lan
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: sonarr
                port:
                  number: 8989
```

- [ ] **Step 6 : Linter et commit**

```bash
mise exec -- yamllint kubernetes/apps/media/sonarr/
git add kubernetes/apps/media/sonarr/
git commit -m "feat(media): add Sonarr deployment"
```

---

### Task 7 : Lidarr

**Goal:** Déployer Lidarr (gestionnaire de musique) avec accès à `downloads` et `music`.

**Files:**
- Create: `kubernetes/apps/media/lidarr/kustomization.yaml`
- Create: `kubernetes/apps/media/lidarr/pvc.yaml`
- Create: `kubernetes/apps/media/lidarr/deployment.yaml`
- Create: `kubernetes/apps/media/lidarr/service.yaml`
- Create: `kubernetes/apps/media/lidarr/ingress.yaml`

**Acceptance Criteria:**
- [ ] PVC `lidarr-config` en `ReadWriteOnce` 1Gi via `nfs-client`
- [ ] Deployment monte `/config`, `/downloads` (`media-downloads`), `/music` (`media-music`)
- [ ] Service ClusterIP sur port 8686
- [ ] Ingress sur `lidarr.homelab.lan`
- [ ] `mise exec -- yamllint kubernetes/apps/media/lidarr/` → aucune erreur

**Verify:** `mise exec -- yamllint kubernetes/apps/media/lidarr/` → aucune erreur

**Steps:**

- [ ] **Step 1–5 : Même pattern que Radarr/Sonarr**

`kustomization.yaml` — identique aux autres apps.

`pvc.yaml` :
```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: lidarr-config
  namespace: media
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: nfs-client
  resources:
    requests:
      storage: 1Gi
```

`deployment.yaml` :
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: lidarr
  namespace: media
spec:
  replicas: 1
  selector:
    matchLabels:
      app: lidarr
  template:
    metadata:
      labels:
        app: lidarr
    spec:
      containers:
        - name: lidarr
          image: ghcr.io/hotio/lidarr:latest
          ports:
            - containerPort: 8686
          env:
            - name: PUID
              value: "1000"
            - name: PGID
              value: "1000"
            - name: UMASK
              value: "002"
            - name: TZ
              value: "Europe/Paris"
          readinessProbe:
            httpGet:
              path: /
              port: 8686
            initialDelaySeconds: 20
            periodSeconds: 10
            failureThreshold: 6
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              memory: 512Mi
          volumeMounts:
            - name: config
              mountPath: /config
            - name: downloads
              mountPath: /downloads
            - name: music
              mountPath: /music
      volumes:
        - name: config
          persistentVolumeClaim:
            claimName: lidarr-config
        - name: downloads
          persistentVolumeClaim:
            claimName: media-downloads
        - name: music
          persistentVolumeClaim:
            claimName: media-music
```

`service.yaml` :
```yaml
apiVersion: v1
kind: Service
metadata:
  name: lidarr
  namespace: media
spec:
  type: ClusterIP
  selector:
    app: lidarr
  ports:
    - port: 8686
      targetPort: 8686
```

`ingress.yaml` :
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: lidarr
  namespace: media
spec:
  ingressClassName: traefik
  rules:
    - host: lidarr.homelab.lan
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: lidarr
                port:
                  number: 8686
```

- [ ] **Step 6 : Linter et commit**

```bash
mise exec -- yamllint kubernetes/apps/media/lidarr/
git add kubernetes/apps/media/lidarr/
git commit -m "feat(media): add Lidarr deployment"
```

---

### Task 8 : Readarr

**Goal:** Déployer Readarr (gestionnaire de livres/ebooks) avec accès à `downloads` et `books`.

**Files:**
- Create: `kubernetes/apps/media/readarr/kustomization.yaml`
- Create: `kubernetes/apps/media/readarr/pvc.yaml`
- Create: `kubernetes/apps/media/readarr/deployment.yaml`
- Create: `kubernetes/apps/media/readarr/service.yaml`
- Create: `kubernetes/apps/media/readarr/ingress.yaml`

**Acceptance Criteria:**
- [ ] PVC `readarr-config` en `ReadWriteOnce` 1Gi via `nfs-client`
- [ ] Deployment monte `/config`, `/downloads` (`media-downloads`), `/books` (`media-books`)
- [ ] Service ClusterIP sur port 8787
- [ ] Ingress sur `readarr.homelab.lan`
- [ ] `mise exec -- yamllint kubernetes/apps/media/readarr/` → aucune erreur

**Verify:** `mise exec -- yamllint kubernetes/apps/media/readarr/` → aucune erreur

**Steps:**

- [ ] **Step 1–5 : Même pattern**

`pvc.yaml` :
```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: readarr-config
  namespace: media
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: nfs-client
  resources:
    requests:
      storage: 1Gi
```

`deployment.yaml` :
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: readarr
  namespace: media
spec:
  replicas: 1
  selector:
    matchLabels:
      app: readarr
  template:
    metadata:
      labels:
        app: readarr
    spec:
      containers:
        - name: readarr
          image: ghcr.io/hotio/readarr:latest
          ports:
            - containerPort: 8787
          env:
            - name: PUID
              value: "1000"
            - name: PGID
              value: "1000"
            - name: UMASK
              value: "002"
            - name: TZ
              value: "Europe/Paris"
          readinessProbe:
            httpGet:
              path: /
              port: 8787
            initialDelaySeconds: 20
            periodSeconds: 10
            failureThreshold: 6
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              memory: 512Mi
          volumeMounts:
            - name: config
              mountPath: /config
            - name: downloads
              mountPath: /downloads
            - name: books
              mountPath: /books
      volumes:
        - name: config
          persistentVolumeClaim:
            claimName: readarr-config
        - name: downloads
          persistentVolumeClaim:
            claimName: media-downloads
        - name: books
          persistentVolumeClaim:
            claimName: media-books
```

`service.yaml` :
```yaml
apiVersion: v1
kind: Service
metadata:
  name: readarr
  namespace: media
spec:
  type: ClusterIP
  selector:
    app: readarr
  ports:
    - port: 8787
      targetPort: 8787
```

`ingress.yaml` :
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: readarr
  namespace: media
spec:
  ingressClassName: traefik
  rules:
    - host: readarr.homelab.lan
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: readarr
                port:
                  number: 8787
```

- [ ] **Step 6 : Linter et commit**

```bash
mise exec -- yamllint kubernetes/apps/media/readarr/
git add kubernetes/apps/media/readarr/
git commit -m "feat(media): add Readarr deployment"
```

---

### Task 9 : Bazarr

**Goal:** Déployer Bazarr (sous-titres automatiques) avec accès aux répertoires `movies` et `tv`.

**Files:**
- Create: `kubernetes/apps/media/bazarr/kustomization.yaml`
- Create: `kubernetes/apps/media/bazarr/pvc.yaml`
- Create: `kubernetes/apps/media/bazarr/deployment.yaml`
- Create: `kubernetes/apps/media/bazarr/service.yaml`
- Create: `kubernetes/apps/media/bazarr/ingress.yaml`

**Acceptance Criteria:**
- [ ] PVC `bazarr-config` en `ReadWriteOnce` 1Gi via `nfs-client`
- [ ] Deployment monte `/config`, `/movies` (`media-movies`), `/tv` (`media-tv`)
- [ ] Service ClusterIP sur port 6767
- [ ] Ingress sur `bazarr.homelab.lan`
- [ ] `mise exec -- yamllint kubernetes/apps/media/bazarr/` → aucune erreur

**Verify:** `mise exec -- yamllint kubernetes/apps/media/bazarr/` → aucune erreur

**Steps:**

- [ ] **Step 1–5 :**

`pvc.yaml` :
```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: bazarr-config
  namespace: media
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: nfs-client
  resources:
    requests:
      storage: 1Gi
```

`deployment.yaml` :
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: bazarr
  namespace: media
spec:
  replicas: 1
  selector:
    matchLabels:
      app: bazarr
  template:
    metadata:
      labels:
        app: bazarr
    spec:
      containers:
        - name: bazarr
          image: ghcr.io/hotio/bazarr:latest
          ports:
            - containerPort: 6767
          env:
            - name: PUID
              value: "1000"
            - name: PGID
              value: "1000"
            - name: UMASK
              value: "002"
            - name: TZ
              value: "Europe/Paris"
          readinessProbe:
            httpGet:
              path: /
              port: 6767
            initialDelaySeconds: 20
            periodSeconds: 10
            failureThreshold: 6
          resources:
            requests:
              cpu: 50m
              memory: 128Mi
            limits:
              memory: 256Mi
          volumeMounts:
            - name: config
              mountPath: /config
            - name: movies
              mountPath: /movies
            - name: tv
              mountPath: /tv
      volumes:
        - name: config
          persistentVolumeClaim:
            claimName: bazarr-config
        - name: movies
          persistentVolumeClaim:
            claimName: media-movies
        - name: tv
          persistentVolumeClaim:
            claimName: media-tv
```

`service.yaml` :
```yaml
apiVersion: v1
kind: Service
metadata:
  name: bazarr
  namespace: media
spec:
  type: ClusterIP
  selector:
    app: bazarr
  ports:
    - port: 6767
      targetPort: 6767
```

`ingress.yaml` :
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: bazarr
  namespace: media
spec:
  ingressClassName: traefik
  rules:
    - host: bazarr.homelab.lan
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: bazarr
                port:
                  number: 6767
```

- [ ] **Step 6 : Linter et commit**

```bash
mise exec -- yamllint kubernetes/apps/media/bazarr/
git add kubernetes/apps/media/bazarr/
git commit -m "feat(media): add Bazarr deployment"
```

---

### Task 10 : Lint global et commit final

**Goal:** Vérifier la cohérence YAML de l'ensemble du dossier `media` et committer le tout.

**Files:**
- Read: `kubernetes/apps/media/` (tous les fichiers)

**Acceptance Criteria:**
- [ ] `mise exec -- yamllint kubernetes/apps/media/` → 0 erreur
- [ ] `mise exec -- yamllint kubernetes/apps/media.yaml` → 0 erreur
- [ ] `git log --oneline -10` montre tous les commits des tâches précédentes

**Verify:** `mise exec -- yamllint kubernetes/apps/media/ kubernetes/apps/media.yaml` → aucune erreur

**Steps:**

- [ ] **Step 1 : Lint global**

```bash
mise exec -- yamllint kubernetes/apps/media/ kubernetes/apps/media.yaml
```

- [ ] **Step 2 : Corriger toute erreur éventuelle**

Si erreur de type `wrong indentation` ou `too many spaces`, corriger le fichier incriminé puis relancer le lint.

- [ ] **Step 3 : Commit final si nécessaire**

```bash
git add -u
git commit -m "fix(media): yamllint corrections"
```
