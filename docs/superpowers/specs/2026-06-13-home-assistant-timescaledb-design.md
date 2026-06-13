# Home Assistant + TimescaleDB — Design Spec

**Date:** 2026-06-13
**Status:** Approved

## Goal

Deploy Home Assistant on the homelab cluster with TimescaleDB as its primary database, replacing the default SQLite backend. TimescaleDB handles both core HA data (states, events, automations) and long-term historical metrics via its native compression. Credentials are managed entirely in-cluster by External Secrets Operator — no secrets are committed to git.

## Architecture

Four new components, all deployed via Flux GitOps:

```
kubernetes/infrastructure/
├── nfs-provisioner/          # HelmRelease: nfs-subdir-external-provisioner
├── nfs-provisioner.yaml      # Flux Kustomization
├── external-secrets/         # HelmRelease: external-secrets operator
├── external-secrets.yaml     # Flux Kustomization
├── timescaledb/              # StatefulSet + Service + ESO resources
└── timescaledb.yaml          # Flux Kustomization

kubernetes/apps/
├── home-assistant/           # Deployment + Service + Ingress + PVC + ESO ExternalSecret
└── home-assistant.yaml       # Flux Kustomization
```

### Flux dependency chain

```
nfs-provisioner ─┐
                 ├──→ timescaledb ──→ [infrastructure complete] ──→ home-assistant
external-secrets ┘
```

`timescaledb.yaml` declares `dependsOn: [nfs-provisioner, external-secrets]`.
`apps.yaml` already declares `dependsOn: infrastructure` — no change needed.

### Namespaces

| Namespace       | Contents                        |
|-----------------|---------------------------------|
| `nfs-provisioner` | NFS provisioner controller    |
| `external-secrets` | ESO controller               |
| `database`      | TimescaleDB StatefulSet + Secrets |
| `home-assistant` | Home Assistant + copied Secret |

## Storage (NFS Provisioner)

- **Chart:** `nfs-subdir-external-provisioner` from the official Helm repo
- **StorageClass name:** `nfs-client` (default, set as cluster default)
- **NFS server + path:** configured via `values` in the HelmRelease (not committed — injected via a ConfigMap or Flux variable substitution referencing a gitignored file)
- All PVCs in the cluster use `storageClassName: nfs-client`

## TimescaleDB

- **Image:** `timescale/timescaledb-ha:pg16`
- **Kind:** StatefulSet, 1 replica
- **Namespace:** `database`
- **PVC:** 20Gi on `nfs-client`
- **Mount:** `/home/postgres/pgdata` (default data dir for this image)
- **Database:** `homeassistant` — single database for all HA data
- **Service:** ClusterIP `timescaledb.database.svc.cluster.local:5432`

### TimescaleDB compression

A TimescaleDB compression policy is applied post-init via a Kubernetes Job that runs `ALTER TABLE ... SET (timescaledb.compress)` and `add_compression_policy()` on the HA history tables. The Job runs once after the StatefulSet is ready, triggered by a Flux dependency. Data older than 30 days is compressed automatically.

### Environment variables

The StatefulSet reads credentials from the ESO-generated Secret:

| Env var            | Source                        |
|--------------------|-------------------------------|
| `POSTGRES_USER`    | `timescaledb-credentials` → `username` |
| `POSTGRES_PASSWORD`| `timescaledb-credentials` → `password` |
| `POSTGRES_DB`      | `homeassistant` (hardcoded)   |

## Secret Management (External Secrets Operator)

ESO is installed via HelmRelease from the official chart. No `SecretStore` pointing to an external vault is needed — credentials are generated in-cluster.

### Password generation (database namespace)

```
generators.external-secrets.io/v1alpha1 / Password
  name: timescaledb-password
  namespace: database
  spec:
    length: 32
    digits: 5
    symbols: 0       # no special chars — safe in connection strings
    noUpper: false
    allowRepeat: true
```

```
external-secrets.io/v1beta1 / ExternalSecret
  name: timescaledb-credentials
  namespace: database
  refreshInterval: 0   # generate once, no automatic rotation
  target:
    name: timescaledb-credentials
    creationPolicy: Owner
  dataFrom:
    - sourceRef.generatorRef → Password/timescaledb-password
```

Resulting secret keys: `username` (static value `homeassistant`), `password` (generated).

### Cross-namespace copy (home-assistant namespace)

A `ClusterSecretStore` with the `Kubernetes` provider reads secrets from the `database` namespace. A dedicated ServiceAccount with a ClusterRole binding grants read access to `secrets` in `database`.

A second `ExternalSecret` in `home-assistant` namespace references this `ClusterSecretStore` to copy `timescaledb-credentials` locally. Home Assistant reads from this copy.

```
ClusterSecretStore: kubernetes-reader
  provider.kubernetes.remoteNamespace: database
  provider.kubernetes.auth.serviceAccount: eso-reader (namespace: external-secrets)

ExternalSecret (home-assistant namespace)
  secretStoreRef: kubernetes-reader (ClusterSecretStore)
  data:
    - remoteRef.key: timescaledb-credentials
      remoteRef.property: password
```

The password exists only in etcd — never in git.

## Home Assistant

- **Image:** `ghcr.io/home-assistant/home-assistant:stable`
- **Kind:** Deployment, 1 replica (HA does not support multi-replica)
- **Namespace:** `home-assistant`
- **PVC:** 5Gi on `nfs-client`, mounted at `/config`

### Database configuration

HA's `configuration.yaml` (stored on the PVC) configures the recorder:

```yaml
recorder:
  db_url: !env_var DATABASE_URL
```

The `DATABASE_URL` env var is injected from the copied Secret:

```
postgresql://homeassistant:<password>@timescaledb.database.svc.cluster.local/homeassistant
```

The Deployment constructs this URL in an init container or via `envFrom` + `valueFrom.secretKeyRef`, concatenating the static prefix with the secret `password` key.

### Networking

- **Service:** ClusterIP on port 8123
- **Ingress:** Traefik `Ingress` resource, host `homeassistant.homelab.lan`, ingressClassName `traefik`

## Constraints

- Single-replica TimescaleDB: no automatic failover. Acceptable for a single-node homelab.
- NFS latency: acceptable for HA workloads; not a concern at homelab scale.
- Password rotation: `refreshInterval: 0` means no automatic rotation. Manual rotation requires deleting the ESO-managed Secret and letting ESO regenerate it, then restarting both pods.
- `timescaledb-ha` image manages its own PostgreSQL init — the `POSTGRES_USER` / `POSTGRES_PASSWORD` / `POSTGRES_DB` env vars are only read on first start (empty data dir).
