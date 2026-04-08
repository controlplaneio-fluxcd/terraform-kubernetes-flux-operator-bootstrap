#!/usr/bin/env bash
# Migration e2e: validates the migration procedure from terraform-provider-flux
# to the bootstrap module, asserting zero workload downtime throughout.
#
# Simulates a cluster where Flux was installed via terraform-provider-flux and
# is actively managing workloads through an OCIRepository + Kustomization. The
# test verifies that application pods are never recreated during migration.

cluster_name="flux-operator-bootstrap-e2e-migration"

# shellcheck source=e2e-helpers.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/e2e-helpers.sh"

migration_tf_dir="$(mktemp -d)"

cleanup() {
  kind delete cluster --name "${cluster_name}" 2>/dev/null || true
  rm -rf "${migration_tf_dir}"
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
    flux_instance_path = "\${path.root}/../${fixture_root_name}/clusters/test/flux-system/flux-instance.yaml"
  }
}
EOF
}

# ===========================================================================

section "Cluster Setup"
note "Resetting kind cluster ${cluster_name}"
kind delete cluster --name "${cluster_name}" 2>/dev/null || true
note "Creating kind cluster ${cluster_name}"
kind create cluster --name "${cluster_name}" 2>&1 | tail -1

section "Install Flux via CLI"
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

section "Deploy Flux-managed Workload"
note "Creating podinfo namespace and deploying via Flux OCIRepository + Kustomization"
kubectl --context "${kctx}" create namespace podinfo
flux create source oci podinfo \
  --context "${kctx}" \
  --url=oci://ghcr.io/stefanprodan/manifests/podinfo \
  --tag=6.7.0 \
  --interval=10m
flux create kustomization podinfo \
  --context "${kctx}" \
  --source=OCIRepository/podinfo \
  --target-namespace=podinfo \
  --prune=true \
  --wait
note "Verifying podinfo deployment is running"
kubectl --context "${kctx}" -n podinfo rollout status deployment/podinfo --timeout=120s >/dev/null
note "Recording pod UIDs for zero-downtime verification"
pod_uids_before="$(podinfo_pod_uids)"
running_before="$(podinfo_running_count)"
if [ "${running_before}" -lt 1 ]; then
  echo "Expected at least 1 Running podinfo pod, got ${running_before}" >&2
  exit 1
fi
note "Pods running: ${running_before}, UIDs: $(echo "${pod_uids_before}" | tr '\n' ' ')"

section "Uninstall Flux"
note "Uninstalling Flux controllers (simulating migration step: flux uninstall --keep-namespace)"
flux uninstall --context "${kctx}" --keep-namespace --silent 2>&1 | grep -E "^(✔|►)" || true
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

section "Apply Bootstrap Module"
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

section "Destroy"
note "Destroying migration scenario"
terraform -chdir="${migration_tf_dir}" destroy -no-color -auto-approve

section "Assertions"
note "Verified migration from terraform-provider-flux with zero workload downtime"
print_elapsed_total
