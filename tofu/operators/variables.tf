variable "nfs_server" {
  description = "IP address of the NFS server"
  type        = string
}

variable "nfs_path" {
  description = "NFS export path (e.g. /var/nfs/shared/K8S)"
  type        = string
}

variable "chart_cilium_version" {
  description = "Cilium Helm chart version — verify latest at https://artifacthub.io/packages/helm/cilium/cilium"
  type        = string
  default     = "1.17.3"
}

variable "node_ip" {
  description = "IP address of the Kubernetes API server node (used for kubeProxyReplacement)"
  type        = string
}

variable "chart_traefik_version" {
  description = "Traefik Helm chart version — verify latest at https://artifacthub.io/packages/helm/traefik/traefik"
  type        = string
  default     = "34.4.0"
}

variable "chart_eso_version" {
  description = "External Secrets Operator Helm chart version — verify latest at https://artifacthub.io/packages/helm/external-secrets-operator/external-secrets"
  type        = string
  default     = "0.11.0"
}

variable "chart_nfs_version" {
  description = "NFS subdir external provisioner Helm chart version — verify latest at https://artifacthub.io/packages/helm/nfs-subdir-external-provisioner/nfs-subdir-external-provisioner"
  type        = string
  default     = "4.0.18"
}

variable "node_interface" {
  description = "Primary ethernet interface name on the Talos node (e.g. eno1, enp3s0)"
  type        = string
  default     = "eno1"
}

variable "udmp_asn" {
  description = "BGP ASN of the Unifi Dream Machine Pro"
  type        = number
  default     = 64521
}

variable "udmp_ip" {
  description = "IP address of the UDMP BGP peer"
  type        = string
  default     = "172.20.3.1"
}

variable "cilium_asn" {
  description = "BGP ASN assigned to the Cilium BGP control plane"
  type        = number
  default     = 64872
}
