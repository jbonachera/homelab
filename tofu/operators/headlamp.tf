resource "helm_release" "headlamp" {
  name             = "headlamp"
  repository       = "https://kubernetes-sigs.github.io/headlamp/"
  chart            = "headlamp"
  version          = var.chart_headlamp_version
  namespace        = "headlamp"
  create_namespace = true
  wait             = true
  wait_for_jobs    = true
  timeout          = 300
}

resource "kubernetes_manifest" "headlamp_ingressroute" {
  depends_on = [helm_release.headlamp]

  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "IngressRoute"
    metadata = {
      name      = "headlamp"
      namespace = "headlamp"
    }
    spec = {
      entryPoints = ["web"]
      routes = [
        {
          match = "Host(`k8s.homelab.lan`)"
          kind  = "Rule"
          services = [
            {
              name      = "headlamp"
              namespace = "headlamp"
              port      = 80
            }
          ]
        }
      ]
    }
  }
}
