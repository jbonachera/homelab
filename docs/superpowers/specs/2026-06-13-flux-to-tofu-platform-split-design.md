# Design: Migration plateforme Flux → tofu

**Date:** 2026-06-13  
**Statut:** Approuvé

## Contexte

Le repo homelab sépare Day-0 (bootstrap Talos) et Day-2 (GitOps Flux). La logique cible est :

- **tofu** = plateforme (opérateurs Helm + services partagés stateful)
- **Flux** = apps (workloads applicatifs + leurs dépendances de secrets)

Actuellement deux éléments sont dans Flux alors qu'ils appartiennent à la couche plateforme :

1. `kubernetes/infrastructure/timescaledb/` — DB partagée par plusieurs apps futures
2. `kubernetes/infrastructure/traefik-config/` — configuration interne de l'opérateur Traefik

## Périmètre de la migration

### Vers `tofu/operators/`

| Ressource | Type | Fichier source actuel |
|---|---|---|
| Namespace `database` | Namespace | `timescaledb/namespace.yaml` |
| StatefulSet `timescaledb` | StatefulSet | `timescaledb/statefulset.yaml` |
| ConfigMap `timescaledb-init` | ConfigMap | `timescaledb/init-configmap.yaml` |
| Service `timescaledb` | Service | `timescaledb/service.yaml` |
| ServiceAccount `eso-reader` + Role + RoleBinding | RBAC | `timescaledb/eso-reader-rbac.yaml` |
| IngressRoute `traefik-dashboard` | IngressRoute (CRD Traefik) | `traefik-config/dashboard.yaml` |

### Reste dans Flux

- `kubernetes/infrastructure/timescaledb-config/` — ClusterSecretStore, ExternalSecret, password generator. Les secrets sont une dépendance applicative, pas un service plateforme.
- `kubernetes/apps/` — inchangé.

### Supprimé de Flux

- `kubernetes/infrastructure/timescaledb/` (tout le dossier)
- `kubernetes/infrastructure/traefik-config/` (tout le dossier)
- Entrées correspondantes dans `kubernetes/infrastructure/kustomization.yaml`

## Architecture cible

```
tofu/operators/
  operators.tf          # Helm: cilium, traefik, external-secrets, nfs-provisioner
  timescaledb.tf        # NEW: namespace, statefulset, service, configmap, rbac
  traefik-config.tf     # NEW: IngressRoute dashboard

kubernetes/infrastructure/
  timescaledb-config/   # Inchangé: ClusterSecretStore, ExternalSecret, password-generator
  kustomization.yaml    # Nettoyé: plus de timescaledb ni traefik-config

kubernetes/apps/
  home-assistant/       # Inchangé
```

## Ordre des opérations (migration avec coupure acceptée)

1. Suspendre la réconciliation Flux : `flux suspend kustomization infrastructure`
2. Supprimer le namespace database (entraîne la suppression de tout ce qu'il contient, PVC incluse) : `kubectl delete namespace database`
3. Ajouter `timescaledb.tf` et `traefik-config.tf` dans `tofu/operators/`
4. `tofu apply` depuis `tofu/operators/`
5. Vérifier que TimescaleDB est Running : `kubectl get pod -n database`
6. Reprendre Flux : `flux resume kustomization infrastructure`
7. Flux réconcilie `timescaledb-config` (secrets) → Home Assistant redémarre avec DB disponible
8. Supprimer les dossiers Flux devenus obsolètes + commit

## Décisions clés

- **Coupure acceptée** : la PVC est supprimée et recrée. Les données Home Assistant sont perdues.
- **Secrets dans Flux** (option B retenue) : ESO/ClusterSecretStore restent dans Flux pour cohérence avec le pattern home-assistant et pour éviter les problèmes de timing tofu ↔ ESO.
- **RBAC eso-reader dans tofu** : le ServiceAccount et les bindings sont des ressources plateforme (ils permettent à ESO de lire les secrets dans le namespace database), pas des secrets applicatifs.

## Implémentation tofu

Les ressources Kubernetes seront déclarées via `kubernetes_manifest` dans deux nouveaux fichiers :

- `tofu/operators/timescaledb.tf` — namespace, configmap, statefulset, service, rbac
- `tofu/operators/traefik-config.tf` — IngressRoute (dépend de `helm_release.traefik`)
