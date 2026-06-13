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
              name      = "init-sql"
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
