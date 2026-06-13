# Home Assistant + TimescaleDB Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy Home Assistant with TimescaleDB as its primary database on the homelab cluster, accessible at `homeassistant.homelab.lan`, with credentials managed entirely by External Secrets Operator.

**Architecture:** Four new Flux-managed components deployed in dependency order — NFS provisioner (storage), ESO (secret management), TimescaleDB (database, infra layer), Home Assistant (app layer). ESO generates the DB password in-cluster and copies it across namespaces; no secrets are committed to git.

**Tech Stack:** Flux CD, Helm, nfs-subdir-external-provisioner, External Secrets Operator, timescale/timescaledb:latest-pg16, ghcr.io/home-assistant/home-assistant:stable, Traefik Ingress.

---

### Task 1: NFS Provisioner

**Goal:** Add `nfs-subdir-external-provisioner` as a HelmRelease with Flux variable substitution for the NFS server address and export path, creating the `nfs-client` StorageClass.

**Files:**
- Create: `kubernetes/infrastructure/sources/nfs-provisioner.yaml`
- Create: `kubernetes/infrastructure/nfs-provisioner/helmrelease.yaml`
- Create: `kubernetes/infrastructure/nfs-provisioner/kustomization.yaml`
- Create: `kubernetes/infrastructure/nfs-provisioner.yaml`
- Create: `kubernetes/infrastructure/nfs-provisioner/cluster-vars.yaml.example`
- Modify: `kubernetes/infrastructure/kustomization.yaml`
- Modify: `.gitignore`

**Acceptance Criteria:**
- [ ] `yamllint kubernetes/` exits 0
- [ ] `kubectl get storageclass nfs-client` shows the StorageClass marked as default
- [ ] `kubectl get pods -n nfs-provisioner` shows the provisioner pod Running

**Verify:** `mise exec -- yamllint kubernetes/` → no errors

**Steps:**

- [ ] **Step 1: Add the NFS HelmRepository**

Create `kubernetes/infrastructure/sources/nfs-provisioner.yaml`:
```yaml
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: nfs-subdir-external-provisioner
  namespace: flux-system
spec:
  interval: 24h
  url: https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner/
```

- [ ] **Step 2: Create the HelmRelease**

Create `kubernetes/infrastructure/nfs-provisioner/helmrelease.yaml`:
```yaml
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: nfs-subdir-external-provisioner
  namespace: flux-system
spec:
  interval: 30m
  chart:
    spec:
      chart: nfs-subdir-external-provisioner
      version: "4.*"
      sourceRef:
        kind: HelmRepository
        name: nfs-subdir-external-provisioner
        namespace: flux-system
      interval: 12h
  targetNamespace: nfs-provisioner
  install:
    createNamespace: true
  values:
    nfs:
      server: "${NFS_SERVER}"
      path: "${NFS_PATH}"
    storageClass:
      name: nfs-client
      defaultClass: true
      reclaimPolicy: Retain
```

Create `kubernetes/infrastructure/nfs-provisioner/kustomization.yaml`:
```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - helmrelease.yaml
```

- [ ] **Step 3: Create the Flux Kustomization with variable substitution**

Create `kubernetes/infrastructure/nfs-provisioner.yaml`:
```yaml
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: nfs-provisioner
  namespace: flux-system
spec:
  interval: 10m0s
  path: ./kubernetes/infrastructure/nfs-provisioner
  prune: true
  wait: true
  timeout: 5m0s
  sourceRef:
    kind: GitRepository
    name: flux-system
  postBuild:
    substituteFrom:
      - kind: ConfigMap
        name: cluster-vars
        optional: false
```

- [ ] **Step 4: Create the cluster-vars example file**

Create `kubernetes/infrastructure/nfs-provisioner/cluster-vars.yaml.example`:
```yaml
---
# Copy this file to cluster-vars.yaml, fill in your values, then apply:
#   kubectl apply -f kubernetes/infrastructure/nfs-provisioner/cluster-vars.yaml
# cluster-vars.yaml is gitignored — never commit it.
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-vars
  namespace: flux-system
data:
  NFS_SERVER: "192.168.1.100"   # IP of your NAS / NFS server
  NFS_PATH: "/volume1/k8s"     # NFS export path
```

- [ ] **Step 5: Update .gitignore and infrastructure kustomization**

Add to `.gitignore`:
```
# NFS provisioner local config
kubernetes/infrastructure/nfs-provisioner/cluster-vars.yaml
```

Update `kubernetes/infrastructure/kustomization.yaml` — append the two new lines:
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
  - sources/nfs-provisioner.yaml
  - nfs-provisioner.yaml
```

- [ ] **Step 6: Create and apply cluster-vars ConfigMap (manual, not committed)**

```bash
cp kubernetes/infrastructure/nfs-provisioner/cluster-vars.yaml.example \
   kubernetes/infrastructure/nfs-provisioner/cluster-vars.yaml
# Edit with your actual NFS_SERVER and NFS_PATH, then:
kubectl apply -f kubernetes/infrastructure/nfs-provisioner/cluster-vars.yaml
```

- [ ] **Step 7: Lint and commit**

```bash
mise exec -- yamllint kubernetes/
git add kubernetes/infrastructure/sources/nfs-provisioner.yaml \
        kubernetes/infrastructure/nfs-provisioner/ \
        kubernetes/infrastructure/nfs-provisioner.yaml \
        kubernetes/infrastructure/kustomization.yaml \
        .gitignore
git commit -m "feat: add nfs-subdir-external-provisioner with nfs-client StorageClass"
```

- [ ] **Step 8: Wait for Flux reconciliation**

```bash
export KUBECONFIG=tofu/kubeconfig.yaml
flux reconcile kustomization infrastructure --with-source
kubectl get storageclass nfs-client
# Expected: nfs-client (default)
kubectl get pods -n nfs-provisioner
# Expected: 1/1 Running
```

---

### Task 2: External Secrets Operator

**Goal:** Deploy ESO via HelmRelease so the cluster can generate and manage secrets in-cluster without any external vault.

**Files:**
- Create: `kubernetes/infrastructure/sources/external-secrets.yaml`
- Create: `kubernetes/infrastructure/external-secrets/helmrelease.yaml`
- Create: `kubernetes/infrastructure/external-secrets/kustomization.yaml`
- Create: `kubernetes/infrastructure/external-secrets.yaml`
- Modify: `kubernetes/infrastructure/kustomization.yaml`

**Acceptance Criteria:**
- [ ] `yamllint kubernetes/` exits 0
- [ ] `kubectl get pods -n external-secrets` shows all ESO pods Running
- [ ] `kubectl get crd externalsecrets.external-secrets.io` exists

**Verify:** `mise exec -- yamllint kubernetes/` → no errors

**Steps:**

- [ ] **Step 1: Add the ESO HelmRepository**

Create `kubernetes/infrastructure/sources/external-secrets.yaml`:
```yaml
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: external-secrets
  namespace: flux-system
spec:
  interval: 24h
  url: https://charts.external-secrets.io
```

- [ ] **Step 2: Create the HelmRelease**

Create `kubernetes/infrastructure/external-secrets/helmrelease.yaml`:
```yaml
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: external-secrets
  namespace: flux-system
spec:
  interval: 30m
  chart:
    spec:
      chart: external-secrets
      version: "0.*"
      sourceRef:
        kind: HelmRepository
        name: external-secrets
        namespace: flux-system
      interval: 12h
  targetNamespace: external-secrets
  install:
    createNamespace: true
  values:
    installCRDs: true
```

Create `kubernetes/infrastructure/external-secrets/kustomization.yaml`:
```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - helmrelease.yaml
```

- [ ] **Step 3: Create the Flux Kustomization**

Create `kubernetes/infrastructure/external-secrets.yaml`:
```yaml
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: external-secrets
  namespace: flux-system
spec:
  interval: 10m0s
  path: ./kubernetes/infrastructure/external-secrets
  prune: true
  wait: true
  timeout: 5m0s
  sourceRef:
    kind: GitRepository
    name: flux-system
```

- [ ] **Step 4: Update infrastructure kustomization**

Update `kubernetes/infrastructure/kustomization.yaml`:
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
  - sources/nfs-provisioner.yaml
  - nfs-provisioner.yaml
  - sources/external-secrets.yaml
  - external-secrets.yaml
```

- [ ] **Step 5: Lint and commit**

```bash
mise exec -- yamllint kubernetes/
git add kubernetes/infrastructure/sources/external-secrets.yaml \
        kubernetes/infrastructure/external-secrets/ \
        kubernetes/infrastructure/external-secrets.yaml \
        kubernetes/infrastructure/kustomization.yaml
git commit -m "feat: add External Secrets Operator"
```

- [ ] **Step 6: Wait for Flux reconciliation**

```bash
export KUBECONFIG=tofu/kubeconfig.yaml
flux reconcile kustomization infrastructure --with-source
kubectl get pods -n external-secrets
# Expected: external-secrets, external-secrets-cert-controller, external-secrets-webhook — all Running
kubectl get crd externalsecrets.external-secrets.io
# Expected: resource exists
```

---

### Task 3: TimescaleDB

**Goal:** Deploy TimescaleDB as a StatefulSet in the `database` namespace with ESO-generated credentials and a ClusterSecretStore for cross-namespace secret access.

**Files:**
- Create: `kubernetes/infrastructure/timescaledb/namespace.yaml`
- Create: `kubernetes/infrastructure/timescaledb/init-configmap.yaml`
- Create: `kubernetes/infrastructure/timescaledb/statefulset.yaml`
- Create: `kubernetes/infrastructure/timescaledb/service.yaml`
- Create: `kubernetes/infrastructure/timescaledb/password-generator.yaml`
- Create: `kubernetes/infrastructure/timescaledb/external-secret.yaml`
- Create: `kubernetes/infrastructure/timescaledb/eso-reader-rbac.yaml`
- Create: `kubernetes/infrastructure/timescaledb/cluster-secret-store.yaml`
- Create: `kubernetes/infrastructure/timescaledb/kustomization.yaml`
- Create: `kubernetes/infrastructure/timescaledb.yaml`
- Modify: `kubernetes/infrastructure/kustomization.yaml`

**Acceptance Criteria:**
- [ ] `yamllint kubernetes/` exits 0
- [ ] `kubectl get pods -n database` shows `timescaledb-0` Running
- [ ] `kubectl get secret timescaledb-credentials -n database` exists with keys `username` and `password`
- [ ] `kubectl get clustersecretstore kubernetes-reader` shows Ready

**Verify:** `mise exec -- yamllint kubernetes/` → no errors

**Steps:**

- [ ] **Step 1: Namespace and init script**

Create `kubernetes/infrastructure/timescaledb/namespace.yaml`:
```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: database
```

Create `kubernetes/infrastructure/timescaledb/init-configmap.yaml`:
```yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: timescaledb-init
  namespace: database
data:
  01-timescaledb.sql: |
    CREATE EXTENSION IF NOT EXISTS timescaledb;
```

- [ ] **Step 2: StatefulSet**

Create `kubernetes/infrastructure/timescaledb/statefulset.yaml`:
```yaml
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: timescaledb
  namespace: database
spec:
  selector:
    matchLabels:
      app: timescaledb
  serviceName: timescaledb
  replicas: 1
  template:
    metadata:
      labels:
        app: timescaledb
    spec:
      containers:
        - name: timescaledb
          image: timescale/timescaledb:latest-pg16
          ports:
            - containerPort: 5432
          env:
            - name: POSTGRES_USER
              valueFrom:
                secretKeyRef:
                  name: timescaledb-credentials
                  key: username
            - name: POSTGRES_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: timescaledb-credentials
                  key: password
            - name: POSTGRES_DB
              value: homeassistant
          volumeMounts:
            - name: data
              mountPath: /var/lib/postgresql/data
            - name: init-sql
              mountPath: /docker-entrypoint-initdb.d
      volumes:
        - name: init-sql
          configMap:
            name: timescaledb-init
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: nfs-client
        resources:
          requests:
            storage: 20Gi
```

- [ ] **Step 3: Service**

Create `kubernetes/infrastructure/timescaledb/service.yaml`:
```yaml
---
apiVersion: v1
kind: Service
metadata:
  name: timescaledb
  namespace: database
spec:
  type: ClusterIP
  selector:
    app: timescaledb
  ports:
    - port: 5432
      targetPort: 5432
```

- [ ] **Step 4: ESO password generator and ExternalSecret**

Create `kubernetes/infrastructure/timescaledb/password-generator.yaml`:
```yaml
---
apiVersion: generators.external-secrets.io/v1alpha1
kind: Password
metadata:
  name: timescaledb-password
  namespace: database
spec:
  length: 32
  digits: 5
  symbols: 0
  noUpper: false
  allowRepeat: true
```

Create `kubernetes/infrastructure/timescaledb/external-secret.yaml`:
```yaml
---
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: timescaledb-credentials
  namespace: database
spec:
  refreshInterval: 0
  target:
    name: timescaledb-credentials
    creationPolicy: Owner
    template:
      data:
        username: homeassistant
        password: "{{ .password }}"
  dataFrom:
    - sourceRef:
        generatorRef:
          apiVersion: generators.external-secrets.io/v1alpha1
          kind: Password
          name: timescaledb-password
```

- [ ] **Step 5: RBAC for cross-namespace secret access**

Create `kubernetes/infrastructure/timescaledb/eso-reader-rbac.yaml`:
```yaml
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: eso-reader
  namespace: external-secrets
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: eso-reader
  namespace: database
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get", "list", "watch"]
    resourceNames: ["timescaledb-credentials"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: eso-reader
  namespace: database
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: eso-reader
subjects:
  - kind: ServiceAccount
    name: eso-reader
    namespace: external-secrets
```

- [ ] **Step 6: ClusterSecretStore**

Create `kubernetes/infrastructure/timescaledb/cluster-secret-store.yaml`:
```yaml
---
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: kubernetes-reader
spec:
  provider:
    kubernetes:
      remoteNamespace: database
      auth:
        serviceAccount:
          name: eso-reader
          namespace: external-secrets
```

- [ ] **Step 7: Kustomize manifest**

Create `kubernetes/infrastructure/timescaledb/kustomization.yaml`:
```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - init-configmap.yaml
  - password-generator.yaml
  - external-secret.yaml
  - eso-reader-rbac.yaml
  - cluster-secret-store.yaml
  - statefulset.yaml
  - service.yaml
```

- [ ] **Step 8: Flux Kustomization**

Create `kubernetes/infrastructure/timescaledb.yaml`:
```yaml
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: timescaledb
  namespace: flux-system
spec:
  interval: 10m0s
  path: ./kubernetes/infrastructure/timescaledb
  prune: true
  wait: true
  timeout: 5m0s
  sourceRef:
    kind: GitRepository
    name: flux-system
  dependsOn:
    - name: nfs-provisioner
    - name: external-secrets
```

- [ ] **Step 9: Update infrastructure kustomization**

Update `kubernetes/infrastructure/kustomization.yaml`:
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
  - sources/nfs-provisioner.yaml
  - nfs-provisioner.yaml
  - sources/external-secrets.yaml
  - external-secrets.yaml
  - timescaledb.yaml
```

- [ ] **Step 10: Lint and commit**

```bash
mise exec -- yamllint kubernetes/
git add kubernetes/infrastructure/timescaledb/ \
        kubernetes/infrastructure/timescaledb.yaml \
        kubernetes/infrastructure/kustomization.yaml
git commit -m "feat: add TimescaleDB with ESO-generated credentials"
```

- [ ] **Step 11: Wait for reconciliation and verify**

```bash
export KUBECONFIG=tofu/kubeconfig.yaml
flux reconcile kustomization infrastructure --with-source
kubectl get pods -n database
# Expected: timescaledb-0   1/1   Running
kubectl get secret timescaledb-credentials -n database -o jsonpath='{.data.username}' | base64 -d
# Expected: homeassistant
kubectl get clustersecretstore kubernetes-reader
# Expected: READY True
```

---

### Task 4: Home Assistant

**Goal:** Deploy Home Assistant in the `home-assistant` namespace with NFS-backed config storage, TimescaleDB as its primary database, and a Traefik Ingress at `homeassistant.homelab.lan`.

**Files:**
- Create: `kubernetes/apps/home-assistant/namespace.yaml`
- Create: `kubernetes/apps/home-assistant/pvc.yaml`
- Create: `kubernetes/apps/home-assistant/external-secret.yaml`
- Create: `kubernetes/apps/home-assistant/deployment.yaml`
- Create: `kubernetes/apps/home-assistant/service.yaml`
- Create: `kubernetes/apps/home-assistant/ingress.yaml`
- Create: `kubernetes/apps/home-assistant/kustomization.yaml`
- Create: `kubernetes/apps/home-assistant.yaml`
- Modify: `kubernetes/apps/kustomization.yaml`

**Acceptance Criteria:**
- [ ] `yamllint kubernetes/` exits 0
- [ ] `kubectl get pods -n home-assistant` shows the HA pod Running
- [ ] `kubectl get secret timescaledb-credentials -n home-assistant` exists (copied by ESO)
- [ ] HTTP GET to `http://homeassistant.homelab.lan` returns HTTP 200 (HA onboarding page)

**Verify:** `mise exec -- yamllint kubernetes/` → no errors

**Steps:**

- [ ] **Step 1: Namespace and PVC**

Create `kubernetes/apps/home-assistant/namespace.yaml`:
```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: home-assistant
```

Create `kubernetes/apps/home-assistant/pvc.yaml`:
```yaml
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: home-assistant-config
  namespace: home-assistant
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: nfs-client
  resources:
    requests:
      storage: 5Gi
```

- [ ] **Step 2: ExternalSecret — cross-namespace copy of DB credentials**

Create `kubernetes/apps/home-assistant/external-secret.yaml`:
```yaml
---
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: timescaledb-credentials
  namespace: home-assistant
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: kubernetes-reader
    kind: ClusterSecretStore
  target:
    name: timescaledb-credentials
    creationPolicy: Owner
  data:
    - secretKey: username
      remoteRef:
        key: timescaledb-credentials
        property: username
    - secretKey: password
      remoteRef:
        key: timescaledb-credentials
        property: password
```

- [ ] **Step 3: Deployment**

Create `kubernetes/apps/home-assistant/deployment.yaml`:
```yaml
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: home-assistant
  namespace: home-assistant
spec:
  replicas: 1
  selector:
    matchLabels:
      app: home-assistant
  template:
    metadata:
      labels:
        app: home-assistant
    spec:
      initContainers:
        - name: init-config
          image: busybox:1.36
          command:
            - sh
            - -c
            - |
              if [ ! -f /config/configuration.yaml ]; then
                cat > /config/configuration.yaml << 'EOF'
              default_config:
              recorder:
                db_url: !env_var DATABASE_URL
              EOF
              fi
          volumeMounts:
            - name: config
              mountPath: /config
      containers:
        - name: home-assistant
          image: ghcr.io/home-assistant/home-assistant:stable
          ports:
            - containerPort: 8123
          env:
            - name: DB_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: timescaledb-credentials
                  key: password
            - name: DATABASE_URL
              value: "postgresql://homeassistant:$(DB_PASSWORD)@timescaledb.database.svc.cluster.local/homeassistant"
          volumeMounts:
            - name: config
              mountPath: /config
      volumes:
        - name: config
          persistentVolumeClaim:
            claimName: home-assistant-config
```

- [ ] **Step 4: Service**

Create `kubernetes/apps/home-assistant/service.yaml`:
```yaml
---
apiVersion: v1
kind: Service
metadata:
  name: home-assistant
  namespace: home-assistant
spec:
  type: ClusterIP
  selector:
    app: home-assistant
  ports:
    - port: 8123
      targetPort: 8123
```

- [ ] **Step 5: Ingress**

Create `kubernetes/apps/home-assistant/ingress.yaml`:
```yaml
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: home-assistant
  namespace: home-assistant
spec:
  ingressClassName: traefik
  rules:
    - host: homeassistant.homelab.lan
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: home-assistant
                port:
                  number: 8123
```

- [ ] **Step 6: Kustomize manifest**

Create `kubernetes/apps/home-assistant/kustomization.yaml`:
```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - pvc.yaml
  - external-secret.yaml
  - deployment.yaml
  - service.yaml
  - ingress.yaml
```

- [ ] **Step 7: Flux Kustomization**

Create `kubernetes/apps/home-assistant.yaml`:
```yaml
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: home-assistant
  namespace: flux-system
spec:
  interval: 10m0s
  path: ./kubernetes/apps/home-assistant
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
  dependsOn:
    - name: infrastructure
  decryption:
    provider: sops
    secretRef:
      name: sops-age
```

- [ ] **Step 8: Update apps kustomization**

Update `kubernetes/apps/kustomization.yaml`:
```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - demo.yaml
  - home-assistant.yaml
```

- [ ] **Step 9: Lint and commit**

```bash
mise exec -- yamllint kubernetes/
git add kubernetes/apps/home-assistant/ \
        kubernetes/apps/home-assistant.yaml \
        kubernetes/apps/kustomization.yaml
git commit -m "feat: add Home Assistant with TimescaleDB and Traefik ingress"
```

- [ ] **Step 10: Wait for reconciliation and verify**

```bash
export KUBECONFIG=tofu/kubeconfig.yaml
flux reconcile kustomization apps --with-source
kubectl get pods -n home-assistant
# Expected: home-assistant-<hash>   1/1   Running
kubectl get secret timescaledb-credentials -n home-assistant
# Expected: secret exists
curl -I http://homeassistant.homelab.lan
# Expected: HTTP/1.1 200 OK  (HA onboarding page)
```

Add `homeassistant.homelab.lan` to your local `/etc/hosts` or router DNS if not already resolved:
```
<node-ip>   homeassistant.homelab.lan
```

---

## Day 2 — TimescaleDB Compression Policy

After Home Assistant has been running and has created its tables (`states`, `events`, `statistics`), apply the compression policy manually:

```bash
export KUBECONFIG=tofu/kubeconfig.yaml
kubectl exec -n database timescaledb-0 -- psql -U homeassistant -d homeassistant -c "
  SELECT create_hypertable('states', 'last_updated_ts', if_not_exists => TRUE);
  ALTER TABLE states SET (timescaledb.compress);
  SELECT add_compression_policy('states', INTERVAL '30 days');
"
```

Run similar commands for `events` and `statistics` tables once HA has populated them. This is an optimization step — HA functions correctly without it.
