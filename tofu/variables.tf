variable "node_ip" {
  description = "IP address of the Talos node"
  type        = string
}

variable "cluster_name" {
  description = "Kubernetes cluster name"
  type        = string
  default     = "homelab"
}

variable "talos_version" {
  description = "Talos Linux version — must match the version served by PXE"
  type        = string
  default     = "v1.13.0"

  validation {
    condition     = can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+$", var.talos_version))
    error_message = "talos_version must be a semver string like v1.13.0."
  }
}

variable "nfs_server" {
  description = "IP address of the NFS server"
  type        = string
}

variable "nfs_path" {
  description = "NFS export path (e.g. /var/nfs/shared/K8S)"
  type        = string
}

variable "chart_metallb_version" {
  description = "MetalLB Helm chart version — verify latest at https://artifacthub.io/packages/helm/metallb/metallb"
  type        = string
  default     = "0.14.9"
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
