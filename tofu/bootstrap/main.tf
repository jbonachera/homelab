terraform {
  required_providers {
    talos = {
      source  = "siderolabs/talos"
      version = "~> 0.11"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

resource "talos_machine_secrets" "this" {
  talos_version = var.talos_version
}

data "talos_machine_configuration" "controlplane" {
  cluster_name     = var.cluster_name
  cluster_endpoint = "https://${var.node_ip}:6443"
  machine_type     = "controlplane"
  machine_secrets  = talos_machine_secrets.this.machine_secrets
  talos_version    = var.talos_version

  config_patches = [
    file("${path.module}/../../talos/patches/all.yaml"),
    file("${path.module}/../../talos/patches/controlplane.yaml"),
  ]
}

resource "talos_machine_configuration_apply" "controlplane" {
  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.controlplane.machine_configuration
  node                        = var.node_ip
  apply_mode                  = "auto"
}

data "talos_machine_configuration" "worker" {
  cluster_name     = var.cluster_name
  cluster_endpoint = "https://${var.node_ip}:6443"
  machine_type     = "worker"
  machine_secrets  = talos_machine_secrets.this.machine_secrets
  talos_version    = var.talos_version

  config_patches = [
    file("${path.module}/../../talos/patches/all.yaml"),
    file("${path.module}/../../talos/patches/worker.yaml"),
  ]
}

resource "talos_machine_configuration_apply" "worker" {
  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.worker.machine_configuration
  node                        = var.worker_ip
  apply_mode                  = "auto"
  depends_on                  = [talos_machine_bootstrap.this]
}

resource "talos_machine_bootstrap" "this" {
  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = var.node_ip
  depends_on           = [talos_machine_configuration_apply.controlplane]
}

resource "talos_cluster_kubeconfig" "this" {
  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = var.node_ip
  depends_on           = [talos_machine_bootstrap.this]
}

resource "local_sensitive_file" "kubeconfig" {
  content              = talos_cluster_kubeconfig.this.kubeconfig_raw
  filename             = "${path.module}/kubeconfig.yaml"
  file_permission      = "0600"
  directory_permission = "0700"
}

data "talos_client_configuration" "this" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration
  nodes = [
    var.node_ip,
    var.worker_ip
  ]
  endpoints = [var.node_ip]
}

resource "local_sensitive_file" "talosconfig" {
  content              = data.talos_client_configuration.this.talos_config
  filename             = "${path.module}/talosconfig.yaml"
  file_permission      = "0600"
  directory_permission = "0700"
}
