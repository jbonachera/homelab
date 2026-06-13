output "kubeconfig" {
  description = "Kubeconfig for the cluster (also written to tofu/bootstrap/kubeconfig.yaml)"
  value       = talos_cluster_kubeconfig.this.kubeconfig_raw
  sensitive   = true
}

output "talosconfig" {
  description = "Talosconfig for talosctl access"
  value       = talos_machine_secrets.this.client_configuration
  sensitive   = true
}
