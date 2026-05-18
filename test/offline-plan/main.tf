terraform {
  required_version = ">= 1.11.0"

  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = ">= 3.0.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 3.0.0"
    }
  }
}

# Both providers are pointed at an unreachable endpoint with bogus credentials.
# If the module's resources required cluster connectivity during `terraform
# plan` (the way `kubernetes_manifest` does), planning would fail trying to
# dial 127.0.0.1:1. The test asserts that plan succeeds against empty state,
# proving the same-module-as-cluster bootstrap pattern is supported.

provider "kubernetes" {
  host                   = "https://127.0.0.1:1"
  cluster_ca_certificate = ""
  token                  = "not-a-real-token"
}

provider "helm" {
  kubernetes = {
    host                   = "https://127.0.0.1:1"
    cluster_ca_certificate = ""
    token                  = "not-a-real-token"
  }
}

module "bootstrap" {
  source = "../.."

  bootstrap_namespace = "flux-operator-bootstrap"
  revision            = 1

  gitops_resources = {
    instance_yaml = <<-YAML
      apiVersion: fluxcd.controlplane.io/v1
      kind: FluxInstance
      metadata:
        name: flux
        namespace: flux-system
      spec:
        distribution:
          version: 2.x
          registry: ghcr.io/fluxcd
    YAML
  }

  managed_resources = {
    secrets_yaml = <<-YAML
      apiVersion: v1
      kind: Secret
      metadata:
        name: bootstrap-managed
      type: Opaque
      stringData:
        value: expected
    YAML
  }
}
