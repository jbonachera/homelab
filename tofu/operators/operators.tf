resource "kubernetes_namespace" "metallb_system" {
  metadata {
    name = "metallb-system"
    labels = {
      "pod-security.kubernetes.io/enforce" = "privileged"
      "pod-security.kubernetes.io/audit"   = "privileged"
      "pod-security.kubernetes.io/warn"    = "privileged"
    }
  }
}

resource "helm_release" "metallb" {
  depends_on    = [kubernetes_namespace.metallb_system]
  name          = "metallb"
  repository    = "https://metallb.github.io/metallb"
  chart         = "metallb"
  version       = var.chart_metallb_version
  namespace     = "metallb-system"
  wait          = true
  wait_for_jobs = true
  timeout       = 600

  values = [
    yamlencode({
      speaker = {
        ignoreExcludeLB = true
      }
    })
  ]
}

resource "helm_release" "traefik" {
  depends_on       = [helm_release.metallb]
  name             = "traefik"
  repository       = "https://traefik.github.io/charts"
  chart            = "traefik"
  version          = var.chart_traefik_version
  namespace        = "traefik-system"
  create_namespace = true
  wait             = true
  wait_for_jobs    = true
  timeout          = 600

  values = [
    yamlencode({
      service = {
        type = "LoadBalancer"
      }
      ports = {
        web = {
          exposedPort = 80
        }
      }
      ingressRoute = {
        dashboard = {
          enabled = false
        }
      }
      ingressClass = {
        name = "traefik"
      }
      providers = {
        kubernetesCRD = {
          enabled = true
        }
        kubernetesIngress = {
          enabled = true
        }
      }
    })
  ]
}

# NOTE: Helm does not upgrade CRDs on `helm upgrade`. When bumping chart_eso_version,
# manually apply updated CRDs first:
# kubectl apply --server-side -f https://raw.githubusercontent.com/external-secrets/external-secrets/<version>/deploy/crds/
resource "helm_release" "external_secrets" {
  name             = "external-secrets"
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  version          = var.chart_eso_version
  namespace        = "external-secrets"
  create_namespace = true
  wait             = true
  wait_for_jobs    = true
  timeout          = 600

  values = [
    yamlencode({
      installCRDs = true
    })
  ]
}

resource "helm_release" "nfs_provisioner" {
  name             = "nfs-subdir-external-provisioner"
  repository       = "https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner"
  chart            = "nfs-subdir-external-provisioner"
  version          = var.chart_nfs_version
  namespace        = "nfs-provisioner"
  create_namespace = true
  wait             = true
  wait_for_jobs    = true
  timeout          = 600

  values = [
    yamlencode({
      nfs = {
        server = var.nfs_server
        path   = var.nfs_path
      }
      storageClass = {
        name          = "nfs-client"
        defaultClass  = true
        reclaimPolicy = "Retain"
        mountOptions  = ["hard", "nfsvers=4.1", "noatime"]
      }
    })
  ]
}
