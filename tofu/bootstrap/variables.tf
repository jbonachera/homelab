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

variable "worker_ip" {
  description = "IP address of the Talos worker node at provisioning time (DHCP — used only for initial config push)"
  type        = string
}
