resource "helm_release" "cilium" {
  name       = "cilium"
  repository = "https://helm.cilium.io"
  chart      = "cilium"
  version    = var.chart_cilium_version
  namespace  = "kube-system"
  wait       = true
  timeout    = 600

  values = [
    yamlencode({
      kubeProxyReplacement = true
      k8sServiceHost       = var.node_ip
      k8sServicePort       = 6443
      operator = {
        replicas = 1
      }
      l2announcements = {
        enabled = true
      }
      externalIPs = {
        enabled = true
      }
      # Talos-specific: cgroup is pre-mounted by Talos, don't let Cilium remount it
      cgroup = {
        autoMount = { enabled = false }
        hostRoot  = "/sys/fs/cgroup"
      }
      # Talos-specific: explicit capabilities required since Talos restricts defaults
      securityContext = {
        capabilities = {
          ciliumAgent      = ["CHOWN", "KILL", "NET_ADMIN", "NET_RAW", "IPC_LOCK", "SYS_ADMIN", "SYS_RESOURCE", "DAC_OVERRIDE", "FOWNER", "SETGID", "SETUID"]
          cleanCiliumState = ["NET_ADMIN", "SYS_ADMIN", "SYS_RESOURCE"]
        }
      }
    })
  ]
}

resource "kubernetes_manifest" "cilium_ip_pool" {
  depends_on = [helm_release.cilium]

  manifest = {
    apiVersion = "cilium.io/v2alpha1"
    kind       = "CiliumLoadBalancerIPPool"
    metadata = {
      name = "default-pool"
    }
    spec = {
      blocks = [
        { cidr = "172.20.1.160/28" }
      ]
    }
  }
}

resource "kubernetes_manifest" "cilium_l2_policy" {
  depends_on = [kubernetes_manifest.cilium_ip_pool]

  manifest = {
    apiVersion = "cilium.io/v2alpha1"
    kind       = "CiliumL2AnnouncementPolicy"
    metadata = {
      name = "default"
    }
    spec = {
      serviceSelector = {
        matchLabels = {}
      }
      nodeSelector = {
        matchLabels = {}
      }
      externalIPs     = true
      loadBalancerIPs = true
    }
  }
}

resource "helm_release" "traefik" {
  depends_on = [
    helm_release.cilium,
    kubernetes_manifest.cilium_ip_pool,
    kubernetes_manifest.cilium_l2_policy,
  ]
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
