# Migration from terraform-provider-flux

This guide describes how to migrate a cluster from
[terraform-provider-flux](https://github.com/fluxcd/terraform-provider-flux)
(`flux_bootstrap_git`) to the bootstrap module.

## Overview

The migration has three steps:

1. Remove the `flux_bootstrap_git` resource from Terraform state (without
   destroying cluster resources)
2. Uninstall the Flux controllers installed by the provider
3. Apply the bootstrap module, which installs Flux Operator and a `FluxInstance`

Workloads deployed by Flux (Deployments, Services, etc. in application
namespaces) are **not affected** by this migration. They continue running
throughout the process. Flux custom resources (GitRepositories, Kustomizations,
HelmReleases) are deleted when Flux is uninstalled because their CRDs are
removed, but Flux recreates them once the new `FluxInstance` reconciles and
reconnects to the same Git repository.

## Prerequisites

- `terraform` >= 1.11.0
- `flux` CLI
- `kubectl` with access to the target cluster

## Step 1: Remove `flux_bootstrap_git` from Terraform state

Remove the resource from Terraform's state without triggering a destroy that
would delete Git manifests or the namespace:

```bash
terraform state rm flux_bootstrap_git.this
```

Then remove the `flux_bootstrap_git` resource and the `fluxcd/flux` provider
from your Terraform configuration files.

## Step 2: Uninstall Flux controllers

Uninstall the Flux controllers while keeping the `flux-system` namespace:

```bash
flux uninstall --keep-namespace --silent
```

This deletes:

- Flux controller Deployments, Services, ServiceAccounts
- ClusterRoles and ClusterRoleBindings
- NetworkPolicies
- Flux CRDs (which cascade-deletes all GitRepositories, Kustomizations,
  HelmReleases, etc.)

It does **not** delete:

- Application workloads in other namespaces (Deployments, Pods, Services, etc.)
- The `flux-system` namespace itself
- Secrets in `flux-system` (e.g. Git credentials)

## Step 3: Apply the bootstrap module

Add the bootstrap module to your Terraform configuration. The `FluxInstance`
manifest should list the same components that were previously installed by the
provider:

```yaml
# clusters/<cluster>/flux-system/flux-instance.yaml
apiVersion: fluxcd.controlplane.io/v1
kind: FluxInstance
metadata:
  name: flux
  namespace: flux-system
spec:
  components:
    - source-controller
    - kustomize-controller
    - helm-controller
    - notification-controller
  distribution:
    version: 2.x
    registry: ghcr.io/fluxcd
  sync:
    kind: GitRepository
    url: https://github.com/<org>/<repo>.git
    ref: refs/heads/main
    path: clusters/<cluster>
    pullSecret: flux-system
```

The `.spec.sync` field replaces the Git source and Kustomization that were
previously managed by the provider. Adjust `url`, `ref`, `path`, and
`pullSecret` to match your existing setup.

```hcl
module "flux_operator_bootstrap" {
  source  = "controlplaneio-fluxcd/flux-operator-bootstrap/kubernetes"
  version = "0.0.3"

  revision = 1

  gitops_resources = {
    flux_instance_path = "${path.root}/clusters/<cluster>/flux-system/flux-instance.yaml"
  }
}
```

Run `terraform apply`. The module installs Flux Operator, creates the
`FluxInstance`, and waits for it to become ready. Once reconciled, Flux
reconnects to the Git repository and recreates the source and Kustomization
objects, which in turn reconcile all application workloads (finding them
already running).

## Step 4: Verify

```bash
# Flux Operator and controllers are running
kubectl -n flux-system get fluxinstance,deployments

# FluxInstance is ready
kubectl -n flux-system get fluxinstance flux

# Application workloads are unaffected
kubectl -n <app-namespace> get pods
```

## Secrets

If the provider created a Git credentials Secret in `flux-system` (the default
`flux-system` Secret), it is preserved during migration because `flux uninstall
--keep-namespace` does not delete Secrets. The `FluxInstance` can reference it
via `.spec.sync.pullSecret`.

If you manage secrets via `managed_resources.secrets_yaml` in the bootstrap
module, you can migrate them there and remove the old Secret after verifying
the new one works.
