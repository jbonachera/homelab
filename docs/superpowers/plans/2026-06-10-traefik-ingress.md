# Traefik Ingress Controller Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Déployer Traefik comme ingress controller HTTP via HelmRelease Flux, avec une IP MetalLB dynamique et le dashboard accessible sur `dashboard.homelab.lan`.

**Architecture:** HelmRepository + HelmRelease Flux (même pattern que MetalLB). Traefik reçoit une IP du pool MetalLB via `service.type: LoadBalancer`. Le dashboard est exposé via une `IngressRoute` CRD Traefik. La chaîne de dépendances Flux garantit que MetalLB a son pool configuré avant que Traefik demande une IP.

**Tech Stack:** Traefik v3 (chart `34.*`), Flux CD HelmRelease/Kustomization, MetalLB L2, Kubernetes Ingress + Traefik IngressRoute CRD.

---

## Chaîne de dépendances Flux cible

```
infrastructure
  └── metallb-operator (wait:true)
        └── metallb-config (dependsOn: metallb-operator)
              └── traefik-operator (dependsOn: metallb-config, wait:true, timeout:5m)
                    └── traefik-config (dependsOn: traefik-operator, wait:true, timeout:2m)
```

---

### Task 1: HelmRepository + HelmRelease Traefik

**Goal:** Créer les manifests Flux qui déploient Traefik via Helm avec un Service LoadBalancer MetalLB.

**Files:**
- Create: `kubernetes/infrastructure/sources/traefik.yaml`
- Create: `kubernetes/infrastructure/traefik-operator.yaml`
- Create: `kubernetes/infrastructure/traefik-operator/kustomization.yaml`
- Create: `kubernetes/infrastructure/traefik-operator/helmrelease.yaml`
- Modify: `kubernetes/infrastructure/kustomization.yaml`

**Acceptance Criteria:**
- [ ] `sources/traefik.yaml` est un `HelmRepository` pointant vers `https://traefik.github.io/charts`
- [ ] `traefik-operator/helmrelease.yaml` cible chart `traefik` version `34.*`, namespace `traefik-system`
- [ ] `service.type: LoadBalancer` dans les Helm values
- [ ] `ingressRoute.dashboard.enabled: false` dans les Helm values
- [ ] Flux Kustomization `traefik-operator` a `dependsOn: metallb-config`, `wait: true`, `timeout: 5m`
- [ ] `yamllint` passe sur tous les nouveaux fichiers

**Verify:** `mise exec -- yamllint kubernetes/infrastructure/sources/traefik.yaml kubernetes/infrastructure/traefik-operator.yaml kubernetes/infrastructure/traefik-operator/` → aucune erreur

**Steps:**

- [ ] **Step 1 : Créer `kubernetes/infrastructure/sources/traefik.yaml`**

```yaml
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: traefik
  namespace: flux-system
spec:
  interval: 24h
  url: https://traefik.github.io/charts
```

- [ ] **Step 2 : Créer `kubernetes/infrastructure/traefik-operator/kustomization.yaml`**

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - helmrelease.yaml
```

- [ ] **Step 3 : Créer `kubernetes/infrastructure/traefik-operator/helmrelease.yaml`**

```yaml
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: traefik
  namespace: flux-system
spec:
  interval: 30m
  chart:
    spec:
      chart: traefik
      version: "34.*"
      sourceRef:
        kind: HelmRepository
        name: traefik
        namespace: flux-system
      interval: 12h
  targetNamespace: traefik-system
  install:
    createNamespace: true
  values:
    service:
      type: LoadBalancer
    ports:
      web:
        exposedPort: 80
    ingressRoute:
      dashboard:
        enabled: false
    providers:
      kubernetesCRD:
        enabled: true
      kubernetesIngress:
        enabled: true
```

- [ ] **Step 4 : Créer `kubernetes/infrastructure/traefik-operator.yaml`**

```yaml
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: traefik-operator
  namespace: flux-system
spec:
  interval: 10m0s
  path: ./kubernetes/infrastructure/traefik-operator
  prune: true
  wait: true
  timeout: 5m0s
  sourceRef:
    kind: GitRepository
    name: flux-system
  dependsOn:
    - name: metallb-config
```

- [ ] **Step 5 : Mettre à jour `kubernetes/infrastructure/kustomization.yaml`**

Ajouter les deux nouvelles entrées à la liste `resources` existante :

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - sources/metallb.yaml
  - metallb-operator.yaml
  - metallb-config.yaml
  - sources/traefik.yaml
  - traefik-operator.yaml
```

- [ ] **Step 6 : Vérifier le YAML**

```bash
mise exec -- yamllint kubernetes/infrastructure/sources/traefik.yaml kubernetes/infrastructure/traefik-operator.yaml kubernetes/infrastructure/traefik-operator/
```

Résultat attendu : aucune ligne d'erreur (warnings OK si c'est juste du style).

- [ ] **Step 7 : Commit**

```bash
git add kubernetes/infrastructure/sources/traefik.yaml \
        kubernetes/infrastructure/traefik-operator.yaml \
        kubernetes/infrastructure/traefik-operator/ \
        kubernetes/infrastructure/kustomization.yaml
git commit -m "feat: add Traefik HelmRelease via MetalLB LoadBalancer"
```

---

### Task 2: Flux Kustomization traefik-config + IngressRoute dashboard

**Goal:** Exposer le dashboard Traefik sur `http://dashboard.homelab.lan/dashboard/` via une `IngressRoute` CRD.

**Files:**
- Create: `kubernetes/infrastructure/traefik-config.yaml`
- Create: `kubernetes/infrastructure/traefik-config/kustomization.yaml`
- Create: `kubernetes/infrastructure/traefik-config/dashboard.yaml`
- Modify: `kubernetes/infrastructure/kustomization.yaml`

**Acceptance Criteria:**
- [ ] `traefik-config.yaml` Kustomization Flux a `dependsOn: traefik-operator`, `wait: true`, `timeout: 2m`
- [ ] `dashboard.yaml` est une `IngressRoute` dans `traefik-system`, host `dashboard.homelab.lan`, route vers `api@internal`
- [ ] `yamllint` passe sur tous les nouveaux fichiers

**Verify:** `mise exec -- yamllint kubernetes/infrastructure/traefik-config.yaml kubernetes/infrastructure/traefik-config/` → aucune erreur

**Steps:**

- [ ] **Step 1 : Créer `kubernetes/infrastructure/traefik-config/kustomization.yaml`**

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - dashboard.yaml
```

- [ ] **Step 2 : Créer `kubernetes/infrastructure/traefik-config/dashboard.yaml`**

```yaml
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: traefik-dashboard
  namespace: traefik-system
spec:
  entryPoints:
    - web
  routes:
    - match: Host(`dashboard.homelab.lan`) && (PathPrefix(`/dashboard`) || PathPrefix(`/api`))
      kind: Rule
      services:
        - name: api@internal
          kind: TraefikService
```

Note: le dashboard est accessible sur `http://dashboard.homelab.lan/dashboard/` (avec trailing slash). Ajouter `dashboard.homelab.lan` au fichier `/etc/hosts` local en pointant vers l'IP MetalLB assignée à Traefik.

- [ ] **Step 3 : Créer `kubernetes/infrastructure/traefik-config.yaml`**

```yaml
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: traefik-config
  namespace: flux-system
spec:
  interval: 10m0s
  path: ./kubernetes/infrastructure/traefik-config
  prune: true
  wait: true
  timeout: 2m0s
  sourceRef:
    kind: GitRepository
    name: flux-system
  dependsOn:
    - name: traefik-operator
```

- [ ] **Step 4 : Mettre à jour `kubernetes/infrastructure/kustomization.yaml`**

Ajouter `traefik-config.yaml` à la liste `resources` :

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - sources/metallb.yaml
  - metallb-operator.yaml
  - metallb-config.yaml
  - sources/traefik.yaml
  - traefik-operator.yaml
  - traefik-config.yaml
```

- [ ] **Step 5 : Vérifier le YAML**

```bash
mise exec -- yamllint kubernetes/infrastructure/traefik-config.yaml kubernetes/infrastructure/traefik-config/
```

Résultat attendu : aucune ligne d'erreur.

- [ ] **Step 6 : Commit**

```bash
git add kubernetes/infrastructure/traefik-config.yaml \
        kubernetes/infrastructure/traefik-config/ \
        kubernetes/infrastructure/kustomization.yaml
git commit -m "feat: add Traefik dashboard IngressRoute"
```

---

### Task 3: Corriger demo.yaml — Service LoadBalancer → ClusterIP

**Goal:** Le Service `demo` n'a pas besoin d'une IP MetalLB puisqu'il est exposé via Ingress Traefik ; passer le type à `ClusterIP`.

**Files:**
- Modify: `kubernetes/apps/demo.yaml`

**Acceptance Criteria:**
- [ ] `spec.type` du Service `demo` est `ClusterIP` (au lieu de `LoadBalancer`)
- [ ] L'`Ingress` existant sur `demo.homelab.lan` est inchangé
- [ ] `yamllint` passe

**Verify:** `grep 'type:' kubernetes/apps/demo.yaml` → retourne `type: ClusterIP`

**Steps:**

- [ ] **Step 1 : Modifier `kubernetes/apps/demo.yaml`**

Changer uniquement la ligne `type: LoadBalancer` en `type: ClusterIP` dans la section `spec` du Service :

```yaml
apiVersion: v1
kind: Service
metadata:
  name: demo
  namespace: default
spec:
  type: ClusterIP   # was: LoadBalancer
  selector:
    app: demo
  ports:
    - port: 80
      targetPort: 80
```

- [ ] **Step 2 : Vérifier**

```bash
grep 'type:' kubernetes/apps/demo.yaml
```

Résultat attendu : `  type: ClusterIP`

- [ ] **Step 3 : Commit**

```bash
git add kubernetes/apps/demo.yaml
git commit -m "fix: demo service does not need LoadBalancer, uses Traefik Ingress"
```
