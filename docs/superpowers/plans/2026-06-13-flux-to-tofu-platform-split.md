# Flux → tofu Platform Split Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrer TimescaleDB et la config Traefik de Flux vers tofu, afin que tofu gère toute la couche plateforme et Flux uniquement les apps.

**Architecture:** Les ressources Kubernetes de TimescaleDB (namespace, StatefulSet, ConfigMap, Service, RBAC) et l'IngressRoute du dashboard Traefik sont déclarées via `kubernetes_manifest` dans deux nouveaux fichiers tofu. Flux perd les dossiers `timescaledb/` et `traefik-config/` de son kustomization infrastructure, mais conserve `timescaledb-config/` (secrets ESO). La migration implique une suppression manuelle du namespace `database` avant le `tofu apply`.

**Tech Stack:** OpenTofu, provider `hashicorp/kubernetes ~> 2.36`, Flux CD, kubectl, Talos Linux

---

## File Map

| Action | Fichier |
|---|---|
| Create | `tofu/operators/timescaledb.tf` |
| Create | `tofu/operators/traefik-config.tf` |
| Modify | `kubernetes/infrastructure/kustomization.yaml` |
| Delete | `kubernetes/infrastructure/timescaledb/` (dossier complet) |
| Delete | `kubernetes/infrastructure/traefik-config/` (dossier complet) |
| Delete | `kubernetes/infrastructure/timescaledb.yaml` (Flux Kustomization CRD) |
| Delete | `kubernetes/infrastructure/traefik-config.yaml` (Flux Kustomization CRD) |

---

### Task 1: Suspendre Flux et supprimer les ressources existantes

**Goal:** Mettre Flux en pause et nettoyer les ressources Kubernetes que tofu va reprendre, pour éviter tout conflit d'ownership.

**Files:**
- Aucun fichier modifié — opérations kubectl uniquement

**Acceptance Criteria:**
- [ ] La Kustomization Flux `infrastructure` est suspendue (`suspended: true`)
- [ ] Le namespace `database` n'existe plus (`kubectl get namespace database` → NotFound)
- [ ] L'IngressRoute `traefik-dashboard` dans `traefik-system` n'existe plus

**Verify:** 
```
kubectl get kustomization -n flux-system infrastructure
kubectl get namespace database
kubectl get ingressroute -n traefik-system traefik-dashboard
```
Expected: infrastructure suspended=True, database NotFound, traefik-dashboard NotFound

**Steps:**

- [ ] **Step 1: Suspendre la réconciliation Flux sur infrastructure**

```bash
flux suspend kustomization infrastructure
```

Expected output: `► suspending kustomization infrastructure in flux-system namespace` puis `✔ kustomization suspended`

- [ ] **Step 2: Vérifier la suspension**

```bash
kubectl get kustomization -n flux-system infrastructure -o jsonpath='{.spec.suspend}'
```

Expected: `true`

- [ ] **Step 3: Supprimer le namespace database (cascade sur tous ses objets et la PVC)**

```bash
kubectl delete namespace database
```

Expected: `namespace "database" deleted` (peut prendre 30-60s)

- [ ] **Step 4: Supprimer l'IngressRoute Traefik dashboard**

```bash
kubectl delete ingressroute -n traefik-system traefik-dashboard
```

Expected: `ingressroute.traefik.io "traefik-dashboard" deleted`

- [ ] **Step 5: Vérifier que les ressources sont bien supprimées**

```bash
kubectl get namespace database 2>&1
kubectl get ingressroute -n traefik-system traefik-dashboard 2>&1
```

Expected: les deux lignes retournent `Error from server (NotFound): ...`

---

### Task 2: Créer `tofu/operators/timescaledb.tf`

**Goal:** Déclarer toutes les ressources Kubernetes de TimescaleDB dans tofu via `kubernetes_manifest`.

**Files:**
- Create: `tofu/operators/timescaledb.tf`

**Acceptance Criteria:**
- [ ] Le fichier contient le namespace `database`, le ConfigMap `timescaledb-init`, le StatefulSet `timescaledb`, le Service `timescaledb`, le ServiceAccount `eso-reader`, le Role `eso-reader` (namespace `database`), le RoleBinding `eso-reader`
- [ ] `tofu validate` dans `tofu/operators/` passe sans erreur
- [ ] `tofu plan` montre 7 ressources à créer (namespace + configmap + statefulset + service + serviceaccount + role + rolebinding)

**Verify:** `tofu -chdir=tofu/operators validate && tofu -chdir=tofu/operators plan | grep "to add"`
Expected: `Plan: 7 to add, 0 to change, 0 to destroy.`

**Steps:**

- [ ] **Step 1: Créer le fichier**

```hcl
# tofu/operators/timescaledb.tf

resource "kubernetes_manifest" "database_namespace" {
  manifest = {
    apiVersion = "v1"
    kind       = "Namespace"
    metadata = {
      name = "database"
    }
  }
}

resource "kubernetes_manifest" "timescaledb_init_configmap" {
  depends_on = [kubernetes_manifest.database_namespace]

  manifest = {
    apiVersion = "v1"
    kind       = "ConfigMap"
    metadata = {
      name      = "timescaledb-init"
      namespace = "database"
    }
    data = {
      "01-timescaledb.sql" = "CREATE EXTENSION IF NOT EXISTS timescaledb;\n"
    }
  }
}

resource "kubernetes_manifest" "timescaledb_statefulset" {
  depends_on = [kubernetes_manifest.database_namespace]

  manifest = {
    apiVersion = "apps/v1"
    kind       = "StatefulSet"
    metadata = {
      name      = "timescaledb"
      namespace = "database"
    }
    spec = {
      selector = {
        matchLabels = { app = "timescaledb" }
      }
      serviceName = "timescaledb"
      replicas    = 1
      template = {
        metadata = {
          labels = { app = "timescaledb" }
        }
        spec = {
          containers = [
            {
              name  = "timescaledb"
              image = "timescale/timescaledb:2.17.2-pg16"
              ports = [{ containerPort = 5432 }]
              env = [
                {
                  name = "POSTGRES_USER"
                  valueFrom = {
                    secretKeyRef = {
                      name = "timescaledb-credentials"
                      key  = "username"
                    }
                  }
                },
                {
                  name = "POSTGRES_PASSWORD"
                  valueFrom = {
                    secretKeyRef = {
                      name = "timescaledb-credentials"
                      key  = "password"
                    }
                  }
                },
                {
                  name  = "POSTGRES_DB"
                  value = "homeassistant"
                }
              ]
              readinessProbe = {
                exec = {
                  command = ["pg_isready", "-U", "homeassistant", "-d", "homeassistant"]
                }
                initialDelaySeconds = 10
                periodSeconds       = 5
              }
              resources = {
                requests = {
                  cpu    = "100m"
                  memory = "256Mi"
                }
                limits = {
                  memory = "1Gi"
                }
              }
              volumeMounts = [
                {
                  name      = "data"
                  mountPath = "/var/lib/postgresql/data"
                },
                {
                  name      = "init-sql"
                  mountPath = "/docker-entrypoint-initdb.d"
                }
              ]
            }
          ]
          volumes = [
            {
              name = "init-sql"
              configMap = { name = "timescaledb-init" }
            }
          ]
        }
      }
      volumeClaimTemplates = [
        {
          metadata = { name = "data" }
          spec = {
            accessModes      = ["ReadWriteOnce"]
            storageClassName = "nfs-client"
            resources = {
              requests = { storage = "20Gi" }
            }
          }
        }
      ]
    }
  }
}

resource "kubernetes_manifest" "timescaledb_service" {
  depends_on = [kubernetes_manifest.database_namespace]

  manifest = {
    apiVersion = "v1"
    kind       = "Service"
    metadata = {
      name      = "timescaledb"
      namespace = "database"
    }
    spec = {
      type     = "ClusterIP"
      selector = { app = "timescaledb" }
      ports = [
        {
          port       = 5432
          targetPort = 5432
        }
      ]
    }
  }
}

resource "kubernetes_manifest" "eso_reader_serviceaccount" {
  manifest = {
    apiVersion = "v1"
    kind       = "ServiceAccount"
    metadata = {
      name      = "eso-reader"
      namespace = "external-secrets"
    }
  }
}

resource "kubernetes_manifest" "eso_reader_role" {
  depends_on = [kubernetes_manifest.database_namespace]

  manifest = {
    apiVersion = "rbac.authorization.k8s.io/v1"
    kind       = "Role"
    metadata = {
      name      = "eso-reader"
      namespace = "database"
    }
    rules = [
      {
        apiGroups     = [""]
        resources     = ["secrets"]
        verbs         = ["get"]
        resourceNames = ["timescaledb-credentials"]
      }
    ]
  }
}

resource "kubernetes_manifest" "eso_reader_rolebinding" {
  depends_on = [
    kubernetes_manifest.eso_reader_role,
    kubernetes_manifest.eso_reader_serviceaccount,
  ]

  manifest = {
    apiVersion = "rbac.authorization.k8s.io/v1"
    kind       = "RoleBinding"
    metadata = {
      name      = "eso-reader"
      namespace = "database"
    }
    roleRef = {
      apiGroup = "rbac.authorization.k8s.io"
      kind     = "Role"
      name     = "eso-reader"
    }
    subjects = [
      {
        kind      = "ServiceAccount"
        name      = "eso-reader"
        namespace = "external-secrets"
      }
    ]
  }
}
```

- [ ] **Step 2: Valider le HCL**

```bash
tofu -chdir=tofu/operators validate
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 3: Commit**

```bash
git add tofu/operators/timescaledb.tf
git commit -m "feat(tofu): add timescaledb as platform resource"
```

---

### Task 3: Créer `tofu/operators/traefik-config.tf`

**Goal:** Déclarer l'IngressRoute du dashboard Traefik dans tofu, avec dépendance sur le helm_release Traefik.

**Files:**
- Create: `tofu/operators/traefik-config.tf`

**Acceptance Criteria:**
- [ ] Le fichier contient un `kubernetes_manifest` pour l'IngressRoute `traefik-dashboard` dans le namespace `traefik-system`
- [ ] Le manifest référence `depends_on = [helm_release.traefik]`
- [ ] `tofu validate` passe sans erreur

**Verify:** `tofu -chdir=tofu/operators validate`
Expected: `Success! The configuration is valid.`

**Steps:**

- [ ] **Step 1: Créer le fichier**

```hcl
# tofu/operators/traefik-config.tf

resource "kubernetes_manifest" "traefik_dashboard_ingressroute" {
  depends_on = [helm_release.traefik]

  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "IngressRoute"
    metadata = {
      name      = "traefik-dashboard"
      namespace = "traefik-system"
    }
    spec = {
      entryPoints = ["web"]
      routes = [
        {
          match = "Host(`dashboard.homelab.lan`)"
          kind  = "Rule"
          services = [
            {
              name = "api@internal"
              kind = "TraefikService"
            }
          ]
        }
      ]
    }
  }
}
```

- [ ] **Step 2: Valider**

```bash
tofu -chdir=tofu/operators validate
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 3: Commit**

```bash
git add tofu/operators/traefik-config.tf
git commit -m "feat(tofu): add traefik dashboard ingressroute as platform resource"
```

---

### Task 4: Appliquer tofu et vérifier TimescaleDB

**Goal:** Déployer les nouvelles ressources plateforme via `tofu apply` et confirmer que TimescaleDB est opérationnel.

**Files:**
- Aucun fichier modifié — opération tofu uniquement

**Acceptance Criteria:**
- [ ] `tofu apply` se termine sans erreur
- [ ] Le pod `timescaledb-0` est en état `Running` et `Ready 1/1`
- [ ] L'IngressRoute `traefik-dashboard` existe dans `traefik-system`

**Verify:**
```bash
kubectl get pod -n database timescaledb-0
kubectl get ingressroute -n traefik-system traefik-dashboard
```
Expected: `timescaledb-0` Running/Ready, ingressroute présente

**Steps:**

- [ ] **Step 1: Appliquer tofu**

```bash
tofu -chdir=tofu/operators apply
```

Taper `yes` à la confirmation. Attendre la fin (peut prendre 1-2 min pour que le PVC soit provisionné et le pod démarre).

- [ ] **Step 2: Vérifier le pod TimescaleDB**

```bash
kubectl get pod -n database timescaledb-0 -w
```

Attendre `STATUS=Running` et `READY=1/1`. Si le pod est en `Pending`, vérifier le PVC :

```bash
kubectl get pvc -n database
kubectl describe pod -n database timescaledb-0
```

- [ ] **Step 3: Vérifier l'IngressRoute**

```bash
kubectl get ingressroute -n traefik-system traefik-dashboard
```

Expected: une ligne avec `traefik-dashboard` et AGE récent.

---

### Task 5: Nettoyer Flux et reprendre la réconciliation

**Goal:** Supprimer les ressources Flux devenues obsolètes et reprendre la réconciliation pour que les secrets TimescaleDB et Home Assistant soient réconciliés.

**Files:**
- Modify: `kubernetes/infrastructure/kustomization.yaml`
- Delete: `kubernetes/infrastructure/timescaledb/` (dossier)
- Delete: `kubernetes/infrastructure/traefik-config/` (dossier)
- Delete: `kubernetes/infrastructure/timescaledb.yaml`
- Delete: `kubernetes/infrastructure/traefik-config.yaml`

**Acceptance Criteria:**
- [ ] `kubernetes/infrastructure/kustomization.yaml` ne référence plus `timescaledb.yaml` ni `traefik-config.yaml`
- [ ] Les dossiers `kubernetes/infrastructure/timescaledb/` et `kubernetes/infrastructure/traefik-config/` sont supprimés
- [ ] La Kustomization Flux `infrastructure` est reprise et `READY=True`
- [ ] La Kustomization Flux `apps` est `READY=True`
- [ ] Home Assistant redémarre et passe `Running`

**Verify:**
```bash
flux get kustomizations
kubectl get pod -n home-assistant
```
Expected: infrastructure et apps READY=True, pod home-assistant Running

**Steps:**

- [ ] **Step 1: Mettre à jour kustomization.yaml**

Contenu final de `kubernetes/infrastructure/kustomization.yaml` :

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - timescaledb-config.yaml
```

- [ ] **Step 2: Supprimer les fichiers et dossiers obsolètes**

```bash
rm -rf kubernetes/infrastructure/timescaledb/
rm -rf kubernetes/infrastructure/traefik-config/
rm kubernetes/infrastructure/timescaledb.yaml
rm kubernetes/infrastructure/traefik-config.yaml
```

- [ ] **Step 3: Vérifier qu'il ne reste que timescaledb-config**

```bash
ls kubernetes/infrastructure/
```

Expected: `kustomization.yaml  timescaledb-config  timescaledb-config.yaml`

- [ ] **Step 4: Commit**

```bash
git add kubernetes/infrastructure/
git commit -m "chore(flux): remove timescaledb and traefik-config from flux infrastructure"
```

- [ ] **Step 5: Reprendre Flux et pusher**

```bash
git push
flux resume kustomization infrastructure
```

- [ ] **Step 6: Surveiller la réconciliation**

```bash
flux get kustomizations --watch
```

Attendre que `infrastructure` et `apps` soient `READY=True`. Si `infrastructure` échoue, inspecter :

```bash
flux logs --kind=Kustomization --name=infrastructure -n flux-system
```

- [ ] **Step 7: Vérifier Home Assistant**

```bash
kubectl get pod -n home-assistant
```

Expected: pod `Running` et `Ready`. Si le pod est en `CrashLoopBackOff`, c'est probablement que les secrets ESO ne sont pas encore réconciliés — attendre 1-2 min et vérifier :

```bash
kubectl get externalsecret -n database
kubectl get secret -n database timescaledb-credentials
```

---

## Ordre d'exécution et dépendances

```
Task 1 (suspend + cleanup) → Task 2 (timescaledb.tf) → Task 3 (traefik-config.tf) → Task 4 (tofu apply) → Task 5 (flux cleanup + resume)
```

Tasks 2 et 3 peuvent être faites en parallèle après Task 1, mais Task 4 doit attendre les deux.
