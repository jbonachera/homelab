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
      bgpControlPlane = {
        enabled = true
      }
      directRoutingDevice  = var.node_interface
      autoDirectNodeRoutes = false
      # Talos-specific: cgroup is pre-mounted by Talos, don't let Cilium remount it
      cgroup = {
        autoMount = { enabled = false }
        hostRoot  = "/sys/fs/cgroup"
      }
      # Talos-specific: explicit capabilities required since Talos restricts defaults
      securityContext = {
        capabilities = {
          ciliumAgent      = ["CHOWN", "KILL", "NET_ADMIN", "NET_RAW", "IPC_LOCK", "SYS_ADMIN", "SYS_RESOURCE", "DAC_OVERRIDE", "FOWNER", "SETGID", "SETUID", "NET_BIND_SERVICE"]
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
        { cidr = "172.20.150.1/24" }
      ]
    }
  }
}

resource "kubernetes_manifest" "cilium_bgp_cluster_config" {
  depends_on = [kubernetes_manifest.cilium_ip_pool]

  manifest = {
    apiVersion = "cilium.io/v2alpha1"
    kind       = "CiliumBGPClusterConfig"
    metadata = {
      name = "default"
    }
    spec = {
      nodeSelector = {
        matchLabels = {
          "kubernetes.io/os" = "linux"
        }
      }
      bgpInstances = [
        {
          name     = "default"
          localASN = var.cilium_asn
          peers = [
            {
              name             = "udmp"
              peerASN          = var.udmp_asn
              peerAddress      = var.udmp_ip
              advertisementRef = { name = "default" }
            }
          ]
        }
      ]
    }
  }
}

resource "kubernetes_manifest" "cilium_bgp_advertisement" {
  depends_on = [kubernetes_manifest.cilium_bgp_cluster_config]

  manifest = {
    apiVersion = "cilium.io/v2alpha1"
    kind       = "CiliumBGPAdvertisement"
    metadata = {
      name = "default"
      labels = {
        "bgp" = "default"
      }
    }
    spec = {
      advertisements = [
        {
          advertisementType = "Service"
          service = {
            addresses = ["LoadBalancerIP"]
          }
        }
      ]
    }
  }
}

resource "local_sensitive_file" "udmp_frr_config" {
  depends_on = [kubernetes_manifest.cilium_bgp_advertisement]
  filename   = "${path.module}/udmp-frr.conf"
  content = templatefile("${path.module}/templates/udmp-frr.conf.tftpl", {
    udmp_asn   = var.udmp_asn
    udmp_ip    = var.udmp_ip
    cilium_asn = var.cilium_asn
    node_ip    = var.node_ip
  })
}

resource "helm_release" "traefik" {
  depends_on = [
    helm_release.cilium,
    kubernetes_manifest.cilium_ip_pool,
    kubernetes_manifest.cilium_bgp_cluster_config,
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
