terraform {
  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.16"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.36"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
  }
}

provider "kubernetes" {
  config_path = "${path.module}/../bootstrap/kubeconfig.yaml"
}

provider "helm" {
  kubernetes {
    config_path = "${path.module}/../bootstrap/kubeconfig.yaml"
  }
}
