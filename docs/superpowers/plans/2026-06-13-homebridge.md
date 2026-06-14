# Homebridge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Déployer Homebridge sur le cluster Talos via Flux CD, avec hostNetwork pour mDNS et UI accessible via Ingress Traefik.

**Architecture:** Namespace dédié `homebridge`, Deployment avec `hostNetwork: true` pour la découverte mDNS/Bonjour des appareils HomeKit, PVC NFS pour la persistance de la config et des plugins, Service ClusterIP + Ingress Traefik pour l'UI web.

**Tech Stack:** Kubernetes, Flux CD (Kustomize), Traefik, NFS storage class, image `ghcr.io/homebridge/homebridge`

---

### Task 1: Créer les manifests Kubernetes Homebridge

**Goal:** Créer les 6 fichiers manifests dans `kubernetes/apps/homebridge/` et enregistrer l'app dans Flux.

**Files:**
- Create: `kubernetes/apps/homebridge/namespace.yaml`
- Create: `kubernetes/apps/homebridge/pvc.yaml`
- Create: `kubernetes/apps/homebridge/deployment.yaml`
- Create: `kubernetes/apps/homebridge/service.yaml`
- Create: `kubernetes/apps/homebridge/ingress.yaml`
- Create: `kubernetes/apps/homebridge/kustomization.yaml`
- Create: `kubernetes/apps/homebridge.yaml`
- Modify: `kubernetes/apps/kustomization.yaml`

**Acceptance Criteria:**
- [ ] `yamllint kubernetes/apps/homebridge/` passe sans erreur
- [ ] Le Deployment a `hostNetwork: true` et `dnsPolicy: ClusterFirstWithHostNet`
- [ ] Le namespace a le label `pod-security.kubernetes.io/enforce: privileged` (requis pour hostNetwork)
- [ ] La kustomization Flux `homebridge.yaml` référence le bon path et dépend de `infrastructure`

**Verify:** `mise exec -- yamllint kubernetes/apps/homebridge/ kubernetes/apps/homebridge.yaml` → no errors

**Steps:**

- [ ] **Step 1: Créer namespace.yaml**

```yaml
# kubernetes/apps/homebridge/namespace.yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: homebridge
  labels:
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/enforce-version: latest
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/warn-version: latest
```

- [ ] **Step 2: Créer pvc.yaml**

```yaml
# kubernetes/apps/homebridge/pvc.yaml
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: homebridge-config
  namespace: homebridge
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: nfs-client
  resources:
    requests:
      storage: 2Gi
```

- [ ] **Step 3: Créer deployment.yaml**

```yaml
# kubernetes/apps/homebridge/deployment.yaml
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: homebridge
  namespace: homebridge
spec:
  replicas: 1
  selector:
    matchLabels:
      app: homebridge
  template:
    metadata:
      labels:
        app: homebridge
    spec:
      hostNetwork: true
      dnsPolicy: ClusterFirstWithHostNet
      containers:
        - name: homebridge
          image: ghcr.io/homebridge/homebridge:2024-11-19
          ports:
            - containerPort: 8581
          env:
            - name: HOMEBRIDGE_CONFIG_UI_PORT
              value: "8581"
          readinessProbe:
            httpGet:
              path: /
              port: 8581
            initialDelaySeconds: 30
            periodSeconds: 10
            failureThreshold: 6
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              memory: 512Mi
          volumeMounts:
            - name: config
              mountPath: /homebridge
      volumes:
        - name: config
          persistentVolumeClaim:
            claimName: homebridge-config
```

- [ ] **Step 4: Créer service.yaml**

```yaml
# kubernetes/apps/homebridge/service.yaml
---
apiVersion: v1
kind: Service
metadata:
  name: homebridge
  namespace: homebridge
spec:
  type: ClusterIP
  selector:
    app: homebridge
  ports:
    - port: 8581
      targetPort: 8581
```

- [ ] **Step 5: Créer ingress.yaml**

```yaml
# kubernetes/apps/homebridge/ingress.yaml
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: homebridge
  namespace: homebridge
spec:
  ingressClassName: traefik
  rules:
    - host: homebridge.homelab.lan
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: homebridge
                port:
                  number: 8581
```

- [ ] **Step 6: Créer kustomization.yaml local**

```yaml
# kubernetes/apps/homebridge/kustomization.yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - pvc.yaml
  - deployment.yaml
  - service.yaml
  - ingress.yaml
```

- [ ] **Step 7: Créer la Flux Kustomization homebridge.yaml**

```yaml
# kubernetes/apps/homebridge.yaml
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: homebridge
  namespace: flux-system
spec:
  interval: 10m0s
  path: ./kubernetes/apps/homebridge
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
  dependsOn:
    - name: infrastructure
```

- [ ] **Step 8: Enregistrer dans kubernetes/apps/kustomization.yaml**

Modifier le fichier existant pour ajouter `homebridge.yaml` :

```yaml
# kubernetes/apps/kustomization.yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - demo.yaml
  - home-assistant.yaml
  - homebridge.yaml
```

- [ ] **Step 9: Linter**

```bash
mise exec -- yamllint kubernetes/apps/homebridge/ kubernetes/apps/homebridge.yaml kubernetes/apps/kustomization.yaml
```

Expected: no output (pas d'erreur)

- [ ] **Step 10: Commit**

```bash
git add kubernetes/apps/homebridge/ kubernetes/apps/homebridge.yaml kubernetes/apps/kustomization.yaml
git commit -m "feat: add homebridge deployment with hostNetwork for mDNS"
```
