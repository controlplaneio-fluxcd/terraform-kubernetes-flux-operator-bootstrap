# terraform-kubernetes-flux-operator-bootstrap

Terraform module that bootstraps Flux Operator in a Kubernetes cluster using a
bootstrap `Job`.

This module solves the bootstrap ownership problem: Terraform needs to get Flux
Operator and a `FluxInstance` into the cluster, but those resources should be
continuously reconciled by Flux afterwards, not by Terraform.

The module keeps Terraform ownership limited to ephemeral bootstrap transport
resources (namespace, RBAC, mounted manifests) and a bootstrap `Job`. The `Job`
performs the idempotent bootstrap actions that let Flux and Flux Operator take
over steady-state reconciliation.

- Terraform manages the bootstrap mechanism
- Flux and Flux Operator manage the steady-state GitOps resources afterwards

Migrating from the [fluxcd/flux](https://registry.terraform.io/providers/fluxcd/flux/latest)
Terraform provider? See the
[migration guide](https://github.com/controlplaneio-fluxcd/terraform-kubernetes-flux-operator-bootstrap/blob/main/docs/migration-from-flux-provider.md).

## Overview

The module creates a dedicated bootstrap namespace with a `Job` that:

- if `runtime_info` is provided, substitutes `${variable}` references in all
  input manifests (FluxInstance, prerequisites, operator chart values,
  prerequisite chart values) using `flux envsubst`
- applies prerequisite manifests with create-if-missing semantics;
  re-applies if not yet adopted by Flux
- installs prerequisite Helm charts (in list order, after prerequisite
  manifests) if configured; without `flux_adoption_check`, uses
  create-if-missing semantics; with `flux_adoption_check`, uses the full
  unlock/recover/upgrade flow (same as the Flux Operator chart) and skips
  charts already adopted by Flux
- creates the `FluxInstance` target namespace if missing
- reconciles managed resources (secrets and runtime-info `ConfigMap`) into the
  target namespace with server-side apply, correcting drift from manual changes;
  tracks them in an inventory and garbage-collects removed entries
- installs Flux Operator if missing; recovers automatically from failed or
  stuck (pending) Helm releases; upgrades if not yet adopted by Flux
- applies the `FluxInstance` manifest with create-if-missing semantics;
  re-applies if not yet adopted by Flux
- waits for the `FluxInstance` to become ready
- cleans up bootstrap transport resources after completion

The bootstrap `Job` re-runs when any input content changes or when the
`revision` input is bumped. When all inputs are unchanged, `terraform plan`
shows zero diff.

The module does not require cluster connectivity during planning, so it can be
used in the same Terraform root module that creates the cluster.

`gitops_resources` are resources meant to be reconciled by Flux after bootstrap,
such as the `FluxInstance` manifest and scheduling prerequisites (e.g. Karpenter
`NodePool`s). These are applied with create-if-missing semantics so that Flux
can take ownership for steady-state reconciliation.

`managed_resources` are resources that remain under Terraform's ownership and
are reconciled on every bootstrap run. `managed_resources.secrets_yaml` is
reconciled into the target namespace with server-side apply.
`managed_resources.runtime_info` is applied as a `ConfigMap` named
`flux-runtime-info` in the target namespace and its data values are substituted
into all input manifests before applying them. For steady-state
variable substitution, use `.spec.kustomize.patches` in the `FluxInstance` to
patch the generated Flux `Kustomization` (from `.spec.sync`) with
`.spec.postBuild.substituteFrom` referencing the same `ConfigMap`.

Callers must configure the HashiCorp Helm and Kubernetes providers for the
module.

## Usage

```hcl
locals {
  ghcr_auth_dockerconfigjson = jsonencode({
    auths = {
      "ghcr.io" = {
        username = "flux"
        password = var.ghcr_token
        auth     = base64encode("flux:${var.ghcr_token}")
      }
    }
  })
}

provider "helm" {
  kubernetes = {
    host                   = data.aws_eks_cluster.this.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.this.token
}

module "flux_operator_bootstrap" {
  source  = "controlplaneio-fluxcd/flux-operator-bootstrap/kubernetes"
  version = "0.3.0"

  revision = var.bootstrap_revision

  gitops_resources = {
    instance_yaml = file("${path.root}/clusters/staging/flux-system/flux-instance.yaml")
    prerequisites = {
      yamls = [
        file("${path.root}/clusters/staging/flux-system/eks-nodepools.yaml"),
      ]
    }
  }

  managed_resources = {
    secrets_yaml = <<-YAML
      apiVersion: v1
      kind: Secret
      metadata:
        name: ghcr-auth
      type: kubernetes.io/dockerconfigjson
      stringData:
        .dockerconfigjson: '${replace(local.ghcr_auth_dockerconfigjson, "'", "''")}'
    YAML
    runtime_info = {
      labels = {
        "reconcile.fluxcd.io/watch" = "Enabled"
      }
      data = {
        cluster_name   = "staging"
        cluster_region = "eu-west-2"
      }
    }
  }
}
```

### Runtime info and variable substitution

When `managed_resources.runtime_info` is set, the bootstrap job:

1. Creates a `ConfigMap` named `flux-runtime-info` in the `FluxInstance` target
   namespace with the provided data, labels, and annotations
2. Substitutes `${variable}` references in all input manifests (FluxInstance,
   prerequisites, operator chart values, prerequisite chart values) using
   `flux envsubst --strict` before applying them

This allows input manifests to use variable references like
`${cluster_name}` that are resolved at bootstrap time. For steady-state
reconciliation, use `.spec.kustomize.patches` in the `FluxInstance` to
patch the generated Flux `Kustomization` (from `.spec.sync`) with
`.spec.postBuild.substituteFrom` referencing the same `ConfigMap`.

Example:

```yaml
apiVersion: fluxcd.controlplane.io/v1
kind: FluxInstance
metadata:
  name: flux
  namespace: flux-system
spec:
  # ...
  kustomize:
    patches:
      - target:
          kind: Kustomization
          name: flux-system
        patch: |
          - op: add
            path: /spec/postBuild
            value:
              substituteFrom:
                - kind: ConfigMap
                  name: flux-runtime-info
```

### Same-module cluster creation

The module can be used in the same Terraform root module that creates the
cluster, with provider configuration referencing the cluster module's outputs:

```hcl
module "eks" {
  source = "terraform-aws-modules/eks/aws"
  # ...
}

provider "helm" {
  kubernetes = {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
    }
  }
}

module "flux_operator_bootstrap" {
  depends_on = [module.eks]
  source     = "controlplaneio-fluxcd/flux-operator-bootstrap/kubernetes"
  version    = "0.3.0"
  revision   = 1
  # ...
}
```

### Root module subdirectory

If your Terraform root module lives below the Git repo root, anchor manifest
paths with `path.root`, for example:

```text
repo/
├── clusters/staging/flux-system/flux-instance.yaml
└── .aws/terraform/
    └── main.tf  # path.root
```

```hcl
gitops_resources = {
  instance_yaml = file("${path.root}/../../clusters/staging/flux-system/flux-instance.yaml")
}
```

### Node scheduling

If the cluster uses dedicated nodes with taints (e.g. provisioned by Karpenter
`NodePool`s), the node pool manifests can be deployed as prerequisites via
`gitops_resources.prerequisites.yamls` so the target nodes are available before
the bootstrap job runs.

Affinity and tolerations can then be configured at each layer:

**Bootstrap job** — uses `job.affinity` and `job.tolerations`:

```hcl
module "flux_operator_bootstrap" {
  # ...

  job = {
    affinity = {
      nodeAffinity = {
        requiredDuringSchedulingIgnoredDuringExecution = {
          nodeSelectorTerms = [{
            matchExpressions = [{
              key      = "kubernetes.io/arch"
              operator = "In"
              values   = ["arm64"]
            }]
          }]
        }
      }
    }
    tolerations = [{
      key      = "node-role.kubernetes.io/control-plane"
      operator = "Exists"
      effect   = "NoSchedule"
    }]
  }
}
```

**Flux Operator** — uses `gitops_resources.operator_chart.values_yaml` to pass
Helm chart values:

```hcl
module "flux_operator_bootstrap" {
  # ...

  gitops_resources = {
    # ...
    operator_chart = {
      values_yaml = yamlencode({
        tolerations = [{
          key      = "node-role.kubernetes.io/control-plane"
          operator = "Exists"
          effect   = "NoSchedule"
        }]
      })
    }
  }
}
```

**Flux components** (source-controller, etc.) — use `.spec.kustomize.patches`
in the `FluxInstance` manifest to patch the generated Deployments:

```yaml
apiVersion: fluxcd.controlplane.io/v1
kind: FluxInstance
metadata:
  name: flux
  namespace: flux-system
spec:
  # ...
  kustomize:
    patches:
      - target:
          kind: Deployment
        patch: |
          - op: add
            path: /spec/template/spec/tolerations
            value:
              - key: node-role.kubernetes.io/control-plane
                operator: Exists
                effect: NoSchedule
```

### Operator values from a local file

When the Flux Operator `HelmRelease` is managed by Flux after bootstrap, its
Helm values can be maintained in a single YAML file that is shared between
Terraform (for bootstrap) and Flux (for steady-state reconciliation via
`valuesFrom`).

For example, given this file at
`clusters/staging/flux-system/flux-operator-values.yaml`:

```yaml
multitenancy:
  enabled: true
tolerations:
  - effect: NoSchedule
    key: node-role.kubernetes.io/control-plane
    operator: Exists
web:
  httpRoute:
    enabled: true
    hostnames:
      - status.staging.example.com
```

A `kustomization.yaml` in the same directory creates a `ConfigMap` from the file
so that the `HelmRelease` can reference it via `valuesFrom`:

```yaml
# clusters/staging/flux-system/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - flux-instance.yaml
  - flux-operator.yaml
configMapGenerator:
  - name: flux-operator-values
    namespace: flux-system
    files:
      - values.yaml=flux-operator-values.yaml
generatorOptions:
  disableNameSuffixHash: true
  labels:
    reconcile.fluxcd.io/watch: Enabled
```

The `reconcile.fluxcd.io/watch: Enabled` label tells helm-controller to
reconcile the `HelmRelease` whenever the `ConfigMap` content changes.

The `HelmRelease` can be wrapped in a `ResourceSet` that depends on the
`HTTPRoute` CRD, ensuring the operator is only upgraded after the Gateway
API CRDs are available (the initial install is handled during bootstrap):

```yaml
# clusters/staging/flux-system/flux-operator.yaml
apiVersion: fluxcd.controlplane.io/v1
kind: ResourceSet
metadata:
  name: flux-operator
  namespace: flux-system
spec:
  dependsOn:
    - apiVersion: apiextensions.k8s.io/v1
      kind: CustomResourceDefinition
      name: helmreleases.helm.toolkit.fluxcd.io
    - apiVersion: apiextensions.k8s.io/v1
      kind: CustomResourceDefinition
      name: httproutes.gateway.networking.k8s.io
  resources:
    - apiVersion: source.toolkit.fluxcd.io/v1
      kind: OCIRepository
      metadata:
        name: flux-operator
        namespace: flux-system
      spec:
        interval: 10m
        url: oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator
        ref:
          semver: '*'
    - apiVersion: helm.toolkit.fluxcd.io/v2
      kind: HelmRelease
      metadata:
        name: flux-operator
        namespace: flux-system
      spec:
        interval: 30m
        releaseName: flux-operator
        chartRef:
          kind: OCIRepository
          name: flux-operator
        valuesFrom:
          - kind: ConfigMap
            name: flux-operator-values
            valuesKey: values.yaml
```

During bootstrap, load the same file with `file(...)` and pass it directly as
`values_yaml`. To override fields that should differ (for example, to disable
the web UI during bootstrap when the `HTTPRoute` or `Ingress` CRD may not
exist yet), use `yamlencode(merge(...))`:

```hcl
module "flux_operator_bootstrap" {
  # ...

  gitops_resources = {
    # ...
    operator_chart = {
      values_yaml = yamlencode(merge(
        yamldecode(file("${path.root}/../../clusters/staging/flux-system/flux-operator-values.yaml")),
        { web = { enabled = false } },
      ))
    }
  }
}
```

Note that Terraform's `merge()` is shallow — it replaces top-level keys, not
nested ones. This works here because the entire `web` key is being overridden
with a single `enabled = false`, so no other values under `web` are needed.

When no overrides are needed, pass the file directly:

```hcl
    operator_chart = {
      values_yaml = file("${path.root}/../../clusters/staging/flux-system/flux-operator-values.yaml")
    }
```

### Managed secrets from an external secrets store

Secret values can be pulled from any external store (AWS Secrets Manager, GCP
Secret Manager, Azure Key Vault, HashiCorp Vault, etc.) using Terraform `data`
sources and composed into the `managed_resources.secrets_yaml` YAML string, the same
way the usage example above builds a dockerconfig secret from Terraform
variables.

**No secret material is stored in the Terraform state.** The module marks
`managed_resources` as `sensitive` and only persists a SHA-256 hash of the
content to detect changes — the actual YAML never appears in the state file.
This is verified by end-to-end tests.

```hcl
data "aws_secretsmanager_secret_version" "git_credentials" {
  secret_id = "flux/staging/git-credentials"
}

module "flux_operator_bootstrap" {
  # ...

  managed_resources = {
    secrets_yaml = <<-YAML
      apiVersion: v1
      kind: Secret
      metadata:
        name: git-credentials
      type: Opaque
      stringData:
        password: '${data.aws_secretsmanager_secret_version.git_credentials.secret_string}'
    YAML
  }
}
```

## Inputs

- `revision` (`Required`): revision number for manually triggering a bootstrap re-run; the bootstrap job also runs automatically when any input content changes (secrets, runtime info, gitops resources); bump revision to force a re-run without changing content; when all inputs are unchanged, `terraform plan` shows zero diff
- `gitops_resources` (`Required`): resources applied with create-if-missing semantics, meant to be reconciled by Flux after bootstrap
  - `gitops_resources.operator_chart` (`Default: {}`): Flux Operator Helm chart settings
  - `gitops_resources.operator_chart.repository` (`Default: "ghcr.io/controlplaneio-fluxcd/charts/flux-operator"`): OCI Helm chart repository (without the `oci://` prefix)
  - `gitops_resources.operator_chart.version` (`Optional`): Helm chart version constraint
  - `gitops_resources.operator_chart.values_yaml` (`Default: ""`): Helm chart values as a YAML string (use `file(...)` to load from a file); may contain `${variable}` references substituted using `runtime_info` values
  - `gitops_resources.instance_yaml` (`Required`): `FluxInstance` manifest YAML string (use `file(...)` to load from a file); may contain `${variable}` references substituted using `runtime_info` values
  - `gitops_resources.prerequisites` (`Default: {}`): prerequisite resource settings
  - `gitops_resources.prerequisites.yamls` (`Default: []`): ordered list of prerequisite manifest YAML strings (use `file(...)` to load from files); may contain `${variable}` references substituted using `runtime_info` values
  - `gitops_resources.prerequisites.charts` (`Default: []`): list of Helm charts to install before Flux; useful for components that must exist before Flux can bootstrap (e.g. CSI drivers, CNI plugins)
  - `gitops_resources.prerequisites.charts[].name` (`Required`): Helm release name
  - `gitops_resources.prerequisites.charts[].repository` (`Required`): OCI Helm chart repository (without the `oci://` prefix)
  - `gitops_resources.prerequisites.charts[].namespace` (`Required`): namespace to install the chart into
  - `gitops_resources.prerequisites.charts[].version` (`Optional`): Helm chart version constraint
  - `gitops_resources.prerequisites.charts[].create_namespace` (`Default: true`): create the namespace if it doesn't exist
  - `gitops_resources.prerequisites.charts[].values_yaml` (`Default: ""`): Helm chart values as a YAML string; may contain `${variable}` references substituted using `runtime_info` values
  - `gitops_resources.prerequisites.charts[].flux_adoption_check` (`Optional`): when set, the bootstrap job checks the specified resource for Flux ownership labels before touching the release; if adopted, the chart is skipped entirely; if not adopted, the full unlock/recover/upgrade flow is used (like the Flux Operator chart); without this field, charts use create-if-missing semantics
  - `gitops_resources.prerequisites.charts[].flux_adoption_check.resource` (`Required`): Kubernetes resource type to check (e.g. `deployment`)
  - `gitops_resources.prerequisites.charts[].flux_adoption_check.api_group` (`Default: ""`): API group of the resource (e.g. `apps`); omit for core API resources
  - `gitops_resources.prerequisites.charts[].flux_adoption_check.name` (`Required`): resource name to check
  - `gitops_resources.prerequisites.charts[].flux_adoption_check.namespace` (`Required`): resource namespace to check
- `managed_resources` (`Default: {}`): resources reconciled by the bootstrap job on every run
  - `managed_resources.secrets_yaml` (`Default: ""`): multi-document Secret manifest YAML reconciled into the target namespace with server-side apply; all documents must be `Secret` objects and their namespace must be omitted or equal the `FluxInstance` namespace
  - `managed_resources.runtime_info` (`Optional`): when set, creates a `ConfigMap` named `flux-runtime-info` in the target namespace; its data values are substituted into all input manifests via `flux envsubst`; tracked in inventory and garbage-collected when removed
  - `managed_resources.runtime_info.data` (`Required`): key-value pairs for the ConfigMap data
  - `managed_resources.runtime_info.labels` (`Default: {}`): labels to set on the ConfigMap
  - `managed_resources.runtime_info.annotations` (`Default: {}`): annotations to set on the ConfigMap
- `bootstrap_namespace` (`Default: "flux-operator-bootstrap"`): namespace for the bootstrap transport resources
- `job` (`Default: {}`): bootstrap job settings
  - `job.image.repository` (`Default: "ghcr.io/controlplaneio-fluxcd/flux-operator-bootstrap"`): image repository; override for mirrored or air-gapped environments
  - `job.image.pull_policy` (`Default: "IfNotPresent"`): image pull policy
  - `job.affinity` (`Default: linux node affinity`): pod affinity rules for the bootstrap job; defaults to scheduling on Linux nodes only (`kubernetes.io/os=linux`)
  - `job.tolerations` (`Default: []`): pod tolerations for the bootstrap job
  - `job.host_network` (`Default: false`): run the bootstrap job with host networking; required when the job must install a CNI plugin (e.g. Cilium) since pod networking is unavailable until the CNI is running
- `timeout` (`Default: "10m"`): timeout for `FluxInstance` readiness waiting and the bootstrap job
- `debug_on_failure` (`Default: false`): when true, creates a `terraform_data` resource that polls the bootstrap `Job` and relays its logs to Terraform output when the `Job` fails or never reaches a terminal state. The `terraform_data` resource runs in parallel with `helm_release` and only triggers when `helm_release` will install or upgrade (i.e. on inputs change or `revision` bump). Requirements on the Terraform execution environment:
  - `bash` must be on `PATH` — the `local-exec` provisioner calls `["bash", "-c", …]`. On Linux and macOS this is native `bash`; on Windows, `bash.exe` from [Git for Windows](https://gitforwindows.org/) (Git Bash) satisfies this
  - `kubectl` must be on `PATH`
  - `kubectl` must be configured with credentials for the target cluster (via `KUBECONFIG`, the default `~/.kube/config`, or any mechanism resolvable by `kubectl` in the same environment Terraform runs in)

**Note**: Secrets are not stored in the Terraform state. Managed resources
are reconciled with server-side apply and drift from manual `kubectl` changes
is automatically corrected, following the same approach as Flux's
kustomize-controller.
