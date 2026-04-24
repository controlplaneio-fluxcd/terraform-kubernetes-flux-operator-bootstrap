# Migration from the previous approach

This guide describes how to migrate a cluster from the previous
[flux-operator Terraform example](https://github.com/controlplaneio-fluxcd/flux-operator/blob/v0.46.0/config/terraform/main.tf)
— two `helm_release` resources installing the `flux-operator` and
`flux-instance` charts directly — to the bootstrap module.

## Overview

The migration detaches both Helm releases from Terraform state, drops the
`flux-instance` release while keeping its `FluxInstance` resource alive, and
then hands the `flux-operator` Helm release over to the bootstrap module,
which upgrades it in place on the next apply.

Workloads reconciled by Flux (Deployments, Services, HelmReleases, etc.) are
**not affected** and keep running throughout the procedure. The existing
`FluxInstance` is preserved, so source-controller, kustomize-controller and
helm-controller keep their reconciliation state and do not recreate managed
resources.

The end-to-end migration is covered as Scenario B in
[`scripts/e2e-migration.sh`](../scripts/e2e-migration.sh), which asserts
zero pod recreation in a Flux-managed application namespace.

## Prerequisites

- `terraform` >= 1.11.0
- `helm` CLI with access to the target cluster
- `kubectl` with access to the target cluster

## Step 1: Suspend any Flux appliers owning the migration targets

If any Flux object is currently reconciling the `flux-operator`/`flux-instance`
Helm releases or the `FluxInstance` CR (for example a `Kustomization` that
applies a Git-managed `HelmRelease`, or a `ResourceSet` that renders either),
suspend it **before** making any other change. Otherwise Flux will fight the
manual state/Helm operations below — re-applying the `HelmRelease`,
re-annotating the `FluxInstance`, or even stripping the
`helm.sh/resource-policy` annotation on the next reconcile.

Identify the applier and suspend it with the appropriate CLI, e.g.:

```bash
flux suspend kustomization <name> -n <namespace>
flux suspend helmrelease <name> -n <namespace>
kubectl annotate resourceset/<name> -n <namespace> \
  fluxcd.controlplane.io/reconcile=disabled --overwrite
```

Leave the appliers suspended until the migration is complete. In Step 6,
either resume them (after updating their source to the new,
module-friendly layout) or delete them if they are no longer needed.

## Step 2: Detach the Helm releases from Terraform state

Remove both `helm_release` resources from Terraform's state without
destroying the cluster resources they created:

```bash
terraform state rm helm_release.flux_instance
terraform state rm helm_release.flux_operator
```

The Deployments, ConfigMaps, CRDs and the `FluxInstance` remain on the
cluster.

## Step 3: Keep the `FluxInstance` across Helm uninstall

The bootstrap module applies the `FluxInstance` with create-if-missing
semantics, so the existing one must stay on the cluster. Apply the Helm
resource-retention annotation **before** uninstalling the `flux-instance`
release, using server-side apply with a dedicated field manager:

```bash
kubectl apply --server-side \
  --field-manager=flux-operator-migration -f - <<'EOF'
apiVersion: fluxcd.controlplane.io/v1
kind: FluxInstance
metadata:
  name: flux
  namespace: flux-system
  annotations:
    helm.sh/resource-policy: keep
EOF
```

The custom field manager is important: if Flux later manages this
`FluxInstance` (for example via a Git-synced manifest reconciled by
kustomize-controller), its own field manager will not touch this
annotation because the annotation is not part of Flux's apply set. A
plain `kubectl annotate` would use the default field manager and could
be overwritten by a subsequent Flux reconciliation, silently removing
the protection.

Then uninstall the `flux-instance` Helm release. The annotation tells Helm
not to delete the annotated object:

```bash
helm uninstall flux -n flux-system --no-hooks
```

Verify the `FluxInstance` is still there:

```bash
kubectl -n flux-system get fluxinstance/flux
```

Do **not** uninstall the `flux-operator` Helm release. The bootstrap module
takes ownership of it on the next apply by issuing `helm upgrade --install`
against the same release name and namespace.

## Step 4: Replace the two `helm_release` resources with the bootstrap module

Remove `helm_release.flux_operator`, `helm_release.flux_instance` and any
related variables or `set` blocks from your Terraform configuration. Move
the `FluxInstance` spec that was previously configured through chart values
into a YAML file:

```yaml
# clusters/<cluster>/flux-system/flux-instance.yaml
apiVersion: fluxcd.controlplane.io/v1
kind: FluxInstance
metadata:
  name: flux
  namespace: flux-system
spec:
  cluster:
    type: kubernetes
    size: small
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

Copy the `instance.distribution.*`, `instance.cluster.*` and `instance.sync.*`
values from the previous approach into the matching `.spec.*` fields so that the
resulting manifest equals the one that was previously rendered by the chart.

Add the bootstrap module:

```hcl
module "flux_operator_bootstrap" {
  source  = "controlplaneio-fluxcd/flux-operator-bootstrap/kubernetes"
  version = "0.4.0"

  revision = 1

  gitops_resources = {
    instance_yaml = file("${path.root}/../clusters/<cluster>/flux-system/flux-instance.yaml")
  }
}
```

Run `terraform apply`. The bootstrap `Job`:

- runs `helm upgrade --install flux-operator` against the existing release,
  which Helm upgrades in place (the Flux Operator pod may restart briefly;
  Flux controllers and workloads are unaffected)
- applies the `FluxInstance` manifest with create-if-missing semantics —
  a no-op because the resource already exists
- waits for the `FluxInstance` to report `Ready`

## Step 5: Remove the `helm.sh/resource-policy` annotation

Once the bootstrap module has successfully applied and the `FluxInstance`
is `Ready`, drop the retention annotation — leaving it behind would keep
the `FluxInstance` immune to any future `helm uninstall`, which is no
longer the desired behavior.

Re-apply an empty `metadata` using the same field manager that set the
annotation; SSA sees the field was removed from our configuration and,
since we were the sole owner, deletes it from the object:

```bash
kubectl apply --server-side \
  --field-manager=flux-operator-migration -f - <<'EOF'
apiVersion: fluxcd.controlplane.io/v1
kind: FluxInstance
metadata:
  name: flux
  namespace: flux-system
EOF
```

Verify the annotation is gone:

```bash
kubectl -n flux-system get fluxinstance/flux \
  -o jsonpath='{.metadata.annotations.helm\.sh/resource-policy}'
# (empty output)
```

## Step 6: Verify and resume Flux appliers

```bash
flux-operator -n flux-system get all
flux-operator -n flux-system export report
```

If appliers were suspended in Step 1, either update their source to match
the new module-friendly layout (the `FluxInstance` manifest under
`clusters/<cluster>/flux-system/`) and then resume them, or delete them if
they are no longer needed:

```bash
flux resume kustomization <name> -n <namespace>
flux resume helmrelease <name> -n <namespace>
kubectl annotate resourceset/<name> -n <namespace> \
  fluxcd.controlplane.io/reconcile- --overwrite
```

## Git pull secret

If the previous approach was configured with `instance.sync.pullSecret = "flux-system"`
and the Secret was created out-of-band, it is preserved by the migration
(Helm uninstall does not touch Secrets not owned by the release). The new
`FluxInstance.spec.sync.pullSecret` continues to reference it.

To manage the Secret declaratively with Terraform going forward, use the
module's
[`managed_resources.secrets_yaml`](../README.md#inputs) input.
