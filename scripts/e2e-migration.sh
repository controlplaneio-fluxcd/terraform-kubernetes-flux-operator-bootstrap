#!/usr/bin/env bash
# Migration e2e: validates the migration procedures to the bootstrap module
# from two legacy setups, asserting zero workload downtime throughout each:
#
#   Scenario A — terraform-provider-flux
#     Simulates a cluster where Flux was installed via terraform-provider-flux
#     (`flux install`) and is actively managing workloads through an
#     OCIRepository + Kustomization. The migration uninstalls Flux with
#     `flux uninstall --keep-namespace` and then applies the bootstrap module.
#
#   Scenario B — previous approach (flux-operator + flux-instance helm_release)
#     Simulates a cluster where Flux Operator and a FluxInstance were installed
#     via two helm_release resources (flux-operator chart + flux-instance
#     chart), matching the previous example in controlplaneio-fluxcd/flux-operator.
#     The migration detaches both releases from Terraform state, annotates the
#     FluxInstance with helm.sh/resource-policy=keep, uninstalls the
#     flux-instance release, and applies the bootstrap module (which adopts the
#     flux-operator release in place via `helm upgrade --install`).
#
# Both scenarios verify that application pods are never recreated during
# migration.

cluster_name="flux-operator-bootstrap-e2e-migration"

# shellcheck source=e2e-helpers.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/e2e-helpers.sh"

migration_tf_dir="$(mktemp -d)"
previous_tf_dir="$(mktemp -d)"
new_tf_dir="$(mktemp -d)"

cleanup() {
  kind delete cluster --name "${cluster_name}" 2>/dev/null || true
  rm -rf "${migration_tf_dir}" "${previous_tf_dir}" "${new_tf_dir}"
}

trap cleanup EXIT

kctx="kind-${cluster_name}"

# podinfo_pod_uids prints sorted UIDs of all pods in the podinfo namespace.
podinfo_pod_uids() {
  kubectl --context "${kctx}" -n podinfo get pods \
    -o jsonpath='{range .items[*]}{.metadata.uid}{"\n"}{end}' | sort
}

# podinfo_running_count prints the number of Running pods in the podinfo namespace.
podinfo_running_count() {
  kubectl --context "${kctx}" -n podinfo get pods \
    --field-selector=status.phase=Running --no-headers | wc -l | tr -d ' '
}

# assert_workloads_unchanged verifies that podinfo pods have the same UIDs
# as before and are all Running. $1: expected pod UIDs (newline-separated),
# $2: expected number of Running pods.
assert_workloads_unchanged() {
  expected_uids="$1"
  expected_count="$2"
  actual_uids="$(podinfo_pod_uids)"
  if [ "${actual_uids}" != "${expected_uids}" ]; then
    echo "Podinfo pod UIDs changed (workloads were recreated)" >&2
    echo "Expected:" >&2
    echo "${expected_uids}" >&2
    echo "Got:" >&2
    echo "${actual_uids}" >&2
    exit 1
  fi
  running="$(podinfo_running_count)"
  if [ "${running}" != "${expected_count}" ]; then
    echo "Expected ${expected_count} Running podinfo pods, got ${running}" >&2
    exit 1
  fi
}

# deploy_podinfo creates the podinfo namespace and deploys podinfo via a Flux
# OCIRepository + Kustomization. Used by both scenarios to simulate
# Flux-managed workloads that must survive migration.
deploy_podinfo() {
  kubectl --context "${kctx}" create namespace podinfo
  flux create source oci podinfo \
    --context "${kctx}" \
    --url=oci://ghcr.io/stefanprodan/manifests/podinfo \
    --tag="${e2e_podinfo_version}" \
    --interval=10m
  flux create kustomization podinfo \
    --context "${kctx}" \
    --source=OCIRepository/podinfo \
    --target-namespace=podinfo \
    --prune=true \
    --wait
  kubectl --context "${kctx}" -n podinfo rollout status deployment/podinfo --timeout=120s >/dev/null
}

# render_migration_root_module renders a Terraform root module that uses direct
# kubeconfig for provider configuration (no kind_cluster module, since the
# cluster already exists). $1: output directory.
render_migration_root_module() {
  tf_dir="$1"
  fixtures_dir="${tf_dir}-fixtures"
  flux_instance_dir="${fixtures_dir}/clusters/test/flux-system"
  fixture_root_name="$(basename "${fixtures_dir}")"

  mkdir -p "${flux_instance_dir}"

  cat > "${flux_instance_dir}/flux-instance.yaml" <<'EOF'
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
EOF

  cat > "${tf_dir}/main.tf" <<EOF
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

provider "helm" {
  kubernetes = {
    config_path    = pathexpand("~/.kube/config")
    config_context = "${kctx}"
  }
}

provider "kubernetes" {
  config_path    = pathexpand("~/.kube/config")
  config_context = "${kctx}"
}

resource "terraform_data" "kind_load_image" {
  input = "${image}"

  provisioner "local-exec" {
    command = "kind load docker-image \${self.input} --name ${cluster_name}"
  }
}

module "bootstrap" {
  depends_on = [terraform_data.kind_load_image]

  source = "${repo_root}"

  revision = 1

  job = {
    image = {
      repository = "${image_repository}"
    }
  }

  gitops_resources = {
    instance_yaml = file("\${path.root}/../${fixture_root_name}/clusters/test/flux-system/flux-instance.yaml")
  }
}
EOF
}

# render_previous_root_module renders a Terraform root module mirroring the
# previous approach: two helm_release resources (flux-operator chart and
# flux-instance chart), both installed into flux-system. The flux-instance
# chart is rendered without a sync block, since this test drives workload
# reconciliation through a separately created OCIRepository/Kustomization,
# matching Scenario A.
render_previous_root_module() {
  tf_dir="$1"

  cat > "${tf_dir}/main.tf" <<EOF
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

provider "helm" {
  kubernetes = {
    config_path    = pathexpand("~/.kube/config")
    config_context = "${kctx}"
  }
}

provider "kubernetes" {
  config_path    = pathexpand("~/.kube/config")
  config_context = "${kctx}"
}

resource "kubernetes_namespace" "flux_system" {
  metadata {
    name = "flux-system"
  }
}

resource "helm_release" "flux_operator" {
  depends_on = [kubernetes_namespace.flux_system]

  name       = "flux-operator"
  namespace  = "flux-system"
  repository = "oci://ghcr.io/controlplaneio-fluxcd/charts"
  chart      = "flux-operator"
  wait       = true
}

resource "helm_release" "flux_instance" {
  depends_on = [helm_release.flux_operator]

  name       = "flux"
  namespace  = "flux-system"
  repository = "oci://ghcr.io/controlplaneio-fluxcd/charts"
  chart      = "flux-instance"
  wait       = true

  set = [
    { name = "instance.distribution.version",  value = "2.x" },
    { name = "instance.distribution.registry", value = "ghcr.io/fluxcd" },
    { name = "instance.cluster.type",          value = "kubernetes" },
    { name = "instance.cluster.size",          value = "small" },
  ]
}
EOF
}

# render_new_root_module renders a Terraform root module that replaces the
# two helm_release resources with the bootstrap module. The FluxInstance
# manifest matches the one rendered by the flux-instance chart so the
# create-if-missing apply is a no-op.
render_new_root_module() {
  tf_dir="$1"
  fixtures_dir="${tf_dir}-fixtures"
  flux_instance_dir="${fixtures_dir}/clusters/test/flux-system"
  fixture_root_name="$(basename "${fixtures_dir}")"

  mkdir -p "${flux_instance_dir}"

  cat > "${flux_instance_dir}/flux-instance.yaml" <<'EOF'
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
EOF

  cat > "${tf_dir}/main.tf" <<EOF
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

provider "helm" {
  kubernetes = {
    config_path    = pathexpand("~/.kube/config")
    config_context = "${kctx}"
  }
}

provider "kubernetes" {
  config_path    = pathexpand("~/.kube/config")
  config_context = "${kctx}"
}

resource "terraform_data" "kind_load_image" {
  input = "${image}"

  provisioner "local-exec" {
    command = "kind load docker-image \${self.input} --name ${cluster_name}"
  }
}

module "bootstrap" {
  depends_on = [terraform_data.kind_load_image]

  source = "${repo_root}"

  revision = 1

  job = {
    image = {
      repository = "${image_repository}"
    }
  }

  gitops_resources = {
    instance_yaml = file("\${path.root}/../${fixture_root_name}/clusters/test/flux-system/flux-instance.yaml")
  }
}
EOF
}

# ===========================================================================
# Scenario A: migration from terraform-provider-flux
# ===========================================================================

section "Scenario A: Cluster Setup"
note "Resetting kind cluster ${cluster_name}"
kind delete cluster --name "${cluster_name}" 2>/dev/null || true
note "Creating kind cluster ${cluster_name}"
kind create cluster --name "${cluster_name}" 2>&1 | tail -1

section "Scenario A: Install Flux via CLI"
note "Installing Flux controllers (simulating terraform-provider-flux)"
flux install --context "${kctx}" 2>&1 | grep -E "^(✔|◎)" || true
note "Verifying Flux controllers are running"
for deploy in source-controller kustomize-controller helm-controller notification-controller; do
  kubectl --context "${kctx}" -n flux-system rollout status "deployment/${deploy}" --timeout=60s >/dev/null
done
note "Verifying Flux CRDs exist"
crd_count="$(kubectl --context "${kctx}" get crds -o name | grep -c 'toolkit.fluxcd.io' || true)"
if [ "${crd_count}" -lt 5 ]; then
  echo "Expected at least 5 Flux CRDs, got ${crd_count}" >&2
  exit 1
fi

section "Scenario A: Deploy Flux-managed Workload"
note "Creating podinfo namespace and deploying via Flux OCIRepository + Kustomization"
deploy_podinfo
note "Recording pod UIDs for zero-downtime verification"
pod_uids_before="$(podinfo_pod_uids)"
running_before="$(podinfo_running_count)"
if [ "${running_before}" -lt 1 ]; then
  echo "Expected at least 1 Running podinfo pod, got ${running_before}" >&2
  exit 1
fi
note "Pods running: ${running_before}, UIDs: $(echo "${pod_uids_before}" | tr '\n' ' ')"

section "Scenario A: Uninstall Flux"
note "Uninstalling Flux controllers via flux-operator CLI (matching docs/migration-from-flux-provider.md)"
flux-operator --kube-context "${kctx}" -n flux-system uninstall --keep-namespace 2>&1 | grep -E "^(✔|►)" || true
note "Verifying Flux controllers are gone"
for deploy in source-controller kustomize-controller helm-controller notification-controller; do
  if kubectl --context "${kctx}" -n flux-system get "deployment/${deploy}" >/dev/null 2>&1; then
    echo "Flux controller ${deploy} still exists after uninstall" >&2
    exit 1
  fi
done
note "Verifying Flux CRDs are gone"
crd_count="$(kubectl --context "${kctx}" get crds -o name | grep -c 'toolkit.fluxcd.io' || true)"
if [ "${crd_count}" != "0" ]; then
  echo "Expected 0 Flux CRDs after uninstall, got ${crd_count}" >&2
  exit 1
fi
note "Verifying flux-system namespace still exists"
kubectl --context "${kctx}" get namespace flux-system >/dev/null
note "Verifying Flux-managed workloads survived uninstall (zero downtime)"
assert_workloads_unchanged "${pod_uids_before}" "${running_before}"

section "Scenario A: Apply Bootstrap Module"
note "Rendering migration Terraform root"
render_migration_root_module "${migration_tf_dir}"
note "Initializing Terraform"
terraform -chdir="${migration_tf_dir}" init -no-color -backend=false
note "Applying bootstrap module"
terraform -chdir="${migration_tf_dir}" apply -no-color -auto-approve
note "Verifying Flux Operator and FluxInstance are ready"
assert_flux_runtime_ready
note "Verifying Flux-managed workloads survived bootstrap (zero downtime)"
assert_workloads_unchanged "${pod_uids_before}" "${running_before}"

section "Scenario A: Destroy"
note "Destroying migration scenario"
terraform -chdir="${migration_tf_dir}" destroy -no-color -auto-approve

# ===========================================================================
# Scenario B: migration from the previous approach
# ===========================================================================

section "Scenario B: Cluster Setup"
note "Resetting kind cluster ${cluster_name}"
kind delete cluster --name "${cluster_name}" 2>/dev/null || true
note "Creating kind cluster ${cluster_name}"
kind create cluster --name "${cluster_name}" 2>&1 | tail -1

section "Scenario B: Install via Previous Approach"
note "Rendering previous-approach root module (flux-operator + flux-instance helm_release)"
render_previous_root_module "${previous_tf_dir}"
note "Initializing Terraform"
terraform -chdir="${previous_tf_dir}" init -no-color -backend=false
note "Applying previous-approach root module"
terraform -chdir="${previous_tf_dir}" apply -no-color -auto-approve
note "Verifying flux-operator and FluxInstance are ready"
assert_flux_runtime_ready
note "Verifying Flux CRDs exist"
crd_count="$(kubectl --context "${kctx}" get crds -o name | grep -c 'toolkit.fluxcd.io' || true)"
if [ "${crd_count}" -lt 5 ]; then
  echo "Expected at least 5 Flux CRDs, got ${crd_count}" >&2
  exit 1
fi

section "Scenario B: Deploy Flux-managed Workload"
note "Creating podinfo namespace and deploying via Flux OCIRepository + Kustomization"
deploy_podinfo
note "Recording pod UIDs for zero-downtime verification"
pod_uids_before="$(podinfo_pod_uids)"
running_before="$(podinfo_running_count)"
if [ "${running_before}" -lt 1 ]; then
  echo "Expected at least 1 Running podinfo pod, got ${running_before}" >&2
  exit 1
fi
note "Pods running: ${running_before}, UIDs: $(echo "${pod_uids_before}" | tr '\n' ' ')"

section "Scenario B: Detach Helm Releases from Terraform State"
note "Removing helm_release.flux_instance from state"
terraform -chdir="${previous_tf_dir}" state rm helm_release.flux_instance
note "Removing helm_release.flux_operator from state"
terraform -chdir="${previous_tf_dir}" state rm helm_release.flux_operator
note "Verifying FluxInstance and flux-operator Deployment still exist"
kubectl --context "${kctx}" -n flux-system get fluxinstance/flux >/dev/null
kubectl --context "${kctx}" -n flux-system get deployment/flux-operator >/dev/null

section "Scenario B: Keep FluxInstance on Helm Uninstall"
note "Applying helm.sh/resource-policy=keep via SSA with a dedicated field manager"
# Server-side apply with a custom field manager so the annotation is owned
# by the migration tooling. If Flux later manages the FluxInstance (via a
# Git-synced manifest), its field manager will not touch this annotation
# because it is not declared in Flux's apply set.
kubectl --context "${kctx}" apply --server-side \
  --field-manager=flux-operator-migration -f - <<'EOF'
apiVersion: fluxcd.controlplane.io/v1
kind: FluxInstance
metadata:
  name: flux
  namespace: flux-system
  annotations:
    helm.sh/resource-policy: keep
EOF
note "Uninstalling flux-instance helm release (FluxInstance must survive)"
helm --kube-context "${kctx}" uninstall flux -n flux-system --no-hooks
note "Verifying FluxInstance still exists after helm uninstall"
kubectl --context "${kctx}" -n flux-system get fluxinstance/flux >/dev/null
note "Verifying Flux-managed workloads survived helm uninstall (zero downtime)"
assert_workloads_unchanged "${pod_uids_before}" "${running_before}"

section "Scenario B: Apply Bootstrap Module"
note "Rendering new root module using the bootstrap module"
render_new_root_module "${new_tf_dir}"
note "Initializing Terraform"
terraform -chdir="${new_tf_dir}" init -no-color -backend=false
note "Applying bootstrap module (takes over flux-operator release, adopts FluxInstance)"
terraform -chdir="${new_tf_dir}" apply -no-color -auto-approve
note "Verifying Flux Operator and FluxInstance are ready"
assert_flux_runtime_ready
note "Verifying Flux-managed workloads survived bootstrap (zero downtime)"
assert_workloads_unchanged "${pod_uids_before}" "${running_before}"

section "Scenario B: Remove helm.sh/resource-policy annotation"
# Re-apply via SSA with the same field manager and no annotations — SSA
# sees the field was dropped from our config and, since we were the sole
# owner, removes it from the object. Leaving the annotation behind would
# keep the FluxInstance immune to future `helm uninstall` calls, which
# is no longer desired after the migration is complete.
note "Re-applying empty metadata to relinquish ownership of the annotation"
kubectl --context "${kctx}" apply --server-side \
  --field-manager=flux-operator-migration -f - <<'EOF'
apiVersion: fluxcd.controlplane.io/v1
kind: FluxInstance
metadata:
  name: flux
  namespace: flux-system
EOF
note "Verifying annotation is gone"
if kubectl --context "${kctx}" -n flux-system get fluxinstance/flux \
    -o jsonpath='{.metadata.annotations.helm\.sh/resource-policy}' | grep -q 'keep'; then
  echo "helm.sh/resource-policy annotation was not removed" >&2
  exit 1
fi

section "Scenario B: Destroy"
note "Destroying migration scenario"
terraform -chdir="${new_tf_dir}" destroy -no-color -auto-approve

section "Assertions"
note "Verified migration from terraform-provider-flux with zero workload downtime"
note "Verified migration from the previous approach with zero workload downtime"
print_elapsed_total
