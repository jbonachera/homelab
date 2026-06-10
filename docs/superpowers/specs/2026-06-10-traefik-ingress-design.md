# Traefik Ingress Controller — Design Spec

Date: 2026-06-10

## Contexte

Homelab single-node Talos Linux, GitOps via Flux CD. MetalLB est déjà installé
en mode L2 avec le pool `172.20.1.150–172.20.1.200`. Le cluster a besoin d'un
ingress controller pour router le trafic HTTP vers les applications. Le fichier
`demo.yaml` référence déjà `ingressClassName: traefik` sans que Traefik soit installé.

## Objectifs

- Déployer Traefik comme ingress controller HTTP (port 80, pas de TLS)
- Traefik obtient une IP dynamique du pool MetalLB via un Service `LoadBalancer`
- Dashboard accessible sur `dashboard.homelab.lan` via IngressRoute
- Suivre le pattern existant : HelmRepository + HelmRelease Flux
- Corriger `demo.yaml` qui utilise `type: LoadBalancer` inutilement

## Architecture

```
Internet/LAN
     │
     ▼
MetalLB IP (172.20.1.150+)
     │
     ▼  :80
  Traefik Service (LoadBalancer)
     │
     ├──── Ingress: demo.homelab.lan  → demo:80
     └──── IngressRoute: dashboard.homelab.lan → api@internal
```

## Chaîne de dépendances Flux

```
infrastructure
  └── metallb-operator (wait:true)
        └── metallb-config (dependsOn: metallb-operator)
              └── traefik-operator (dependsOn: metallb-config, wait:true, timeout:5m)
                    └── traefik-config (dependsOn: traefik-operator)
```

Traefik attend `metallb-config` pour s'assurer que le pool IP existe avant de
demander une adresse `LoadBalancer`.

## Fichiers à créer

### `kubernetes/infrastructure/sources/traefik.yaml`

HelmRepository pointant vers `https://traefik.github.io/charts`, intervalle 24h.

### `kubernetes/infrastructure/traefik-operator.yaml`

Flux `Kustomization` :
- `path: ./kubernetes/infrastructure/traefik-operator`
- `dependsOn: metallb-config`
- `wait: true`, `timeout: 5m`
- `prune: true`

### `kubernetes/infrastructure/traefik-operator/helmrelease.yaml`

HelmRelease Traefik :
- Chart : `traefik`, version `34.*` (série stable actuelle)
- `targetNamespace: traefik-system`, `createNamespace: true`
- Helm values :
  - `service.type: LoadBalancer`
  - `ports.web.exposedPort: 80`
  - `ingressRoute.dashboard.enabled: false` (IngressRoute custom créée séparément)
  - `providers.kubernetesIngress.enabled: true`
  - `providers.kubernetesCRD.enabled: true`

### `kubernetes/infrastructure/traefik-config.yaml`

Flux `Kustomization` :
- `path: ./kubernetes/infrastructure/traefik-config`
- `dependsOn: traefik-operator`
- `wait: true`, `timeout: 2m`
- `prune: true`

### `kubernetes/infrastructure/traefik-config/dashboard.yaml`

`IngressRoute` (CRD Traefik) :
- Namespace : `traefik-system`
- Host : `dashboard.homelab.lan`
- Route vers `api@internal`
- EntryPoint : `web` (port 80)

## Fichiers à modifier

### `kubernetes/infrastructure/kustomization.yaml`

Ajouter :
```yaml
- sources/traefik.yaml
- traefik-operator.yaml
- traefik-config.yaml
```

### `kubernetes/apps/demo.yaml`

Changer `spec.type: LoadBalancer` → `spec.type: ClusterIP` sur le Service `demo`.
Le Service n'a pas besoin d'une IP MetalLB puisqu'il est exposé via l'Ingress Traefik.

## Non-couvert (hors scope)

- TLS / HTTPS — à ajouter plus tard avec cert-manager
- IP fixe pour Traefik — dynamique suffit, à fixer si DNS local est configuré
- Middleware Traefik (auth, rate-limit)
- IngressClass par défaut — `ingressClassName: traefik` reste explicite
