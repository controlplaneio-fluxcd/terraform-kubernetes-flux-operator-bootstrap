#!/usr/bin/env bash
set -euo pipefail

export NO_COLOR=1

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cluster_name="flux-operator-bootstrap-e2e"
image_repository="terraform-kubernetes-flux-operator-bootstrap"
image_tag="dev"
image="${image_repository}:${image_tag}"
module_image="ghcr.io/controlplaneio-fluxcd/flux-operator-bootstrap:${image_tag}"
inventory_config_map_name="inventory"
success_tf_dir="$(mktemp -d)"
failure_tf_dir="$(mktemp -d)"
unlock_tf_dir="$(mktemp -d)"
failure_apply_log=""

section() {
  title="$1"
  printf '\n========== %s ==========\n' "${title}"
}

note() {
  printf '[e2e] %s\n' "$1"
}

kubectl_get_flux_operator_resources() {
  kubectl --context "kind-${cluster_name}" get \
    fluxinstances.fluxcd.controlplane.io,fluxreports.fluxcd.controlplane.io \
    -A || true
}

secret_value() {
  secret_name="$1"

  kubectl --context "kind-${cluster_name}" -n flux-system get "secret/${secret_name}" \
    -o jsonpath='{.data.value}' | base64 --decode
}

secret_uid() {
  secret_name="$1"

  kubectl --context "kind-${cluster_name}" -n flux-system get "secret/${secret_name}" \
    -o jsonpath='{.metadata.uid}'
}

prerequisite_configmap_value() {
  kubectl --context "kind-${cluster_name}" -n bootstrap-prereq get configmap/bootstrap-prereq \
    -o jsonpath='{.data.value}'
}

inventory_entries() {
  bootstrap_namespace="$1"

  kubectl --context "kind-${cluster_name}" -n "${bootstrap_namespace}" get "configmap/${inventory_config_map_name}" \
    -o go-template='{{index .data "entries"}}'
}

target_secret_exists() {
  secret_name="$1"

  kubectl --context "kind-${cluster_name}" -n flux-system get "secret/${secret_name}" >/dev/null 2>&1
}

secret_has_field_manager() {
  manager="$1"

  kubectl --context "kind-${cluster_name}" -n flux-system get secret/bootstrap-managed \
    -o jsonpath='{range .metadata.managedFields[*]}{.manager}{"\n"}{end}' | grep -Fx "${manager}" >/dev/null
}

assert_no_secret_material_in_state() {
  tf_dir="$1"

  while IFS= read -r state_file; do
    if grep -F "bootstrap-managed" "${state_file}" >/dev/null; then
      echo "Managed Secret manifest name leaked into Terraform state: ${state_file}" >&2
      exit 1
    fi

    if grep -F "bootstrap-managed-removed" "${state_file}" >/dev/null; then
      echo "Removed managed Secret manifest name leaked into Terraform state: ${state_file}" >&2
      exit 1
    fi

    if grep -F "value\":\"expected" "${state_file}" >/dev/null || grep -F "expected" "${state_file}" >/dev/null; then
      echo "Managed Secret payload leaked into Terraform state: ${state_file}" >&2
      exit 1
    fi

    if grep -F "temporary" "${state_file}" >/dev/null; then
      echo "Removed managed Secret payload leaked into Terraform state: ${state_file}" >&2
      exit 1
    fi

    if grep -F "rotated" "${state_file}" >/dev/null; then
      echo "Rotated managed Secret payload leaked into Terraform state: ${state_file}" >&2
      exit 1
    fi
  done < <(find "${tf_dir}" -maxdepth 1 -type f \( -name 'terraform.tfstate' -o -name 'terraform.tfstate.*' \) | sort)
}

assert_flux_runtime_ready() {
  kubectl --context "kind-${cluster_name}" -n flux-system wait \
    --for=condition=Ready \
    fluxinstance.fluxcd.controlplane.io/flux \
    --timeout=120s >/dev/null

  kubectl --context "kind-${cluster_name}" -n flux-system rollout status \
    deployment/flux-operator \
    --timeout=120s >/dev/null

  kubectl --context "kind-${cluster_name}" -n flux-system rollout status \
    deployment/source-controller \
    --timeout=120s >/dev/null
}

assert_bootstrap_inputs_applied() {
  kubectl --context "kind-${cluster_name}" get namespace bootstrap-prereq >/dev/null

  if [ "$(prerequisite_configmap_value)" != "initial" ]; then
    echo "Prerequisite ConfigMap did not contain the expected initial value" >&2
    exit 1
  fi

  if [ "$(secret_value bootstrap-managed)" != "expected" ]; then
    echo "Managed Secret did not contain the expected initial value" >&2
    exit 1
  fi

  if [ "$(secret_value bootstrap-managed-removed)" != "temporary" ]; then
    echo "Managed Secret slated for removal did not contain the expected initial value" >&2
    exit 1
  fi
}

dump_bootstrap_logs() {
  namespace="$1"

  kubectl --context "kind-${cluster_name}" -n "${namespace}" get jobs,pods || true

  if kubectl --context "kind-${cluster_name}" -n "${namespace}" get job flux-operator-bootstrap >/dev/null 2>&1; then
    kubectl --context "kind-${cluster_name}" -n "${namespace}" logs job/flux-operator-bootstrap || true
    kubectl --context "kind-${cluster_name}" -n "${namespace}" describe job flux-operator-bootstrap || true
  fi
}

cleanup() {
  kind delete cluster --name "${cluster_name}" 2>/dev/null || true
  rm -rf "${success_tf_dir}" "${failure_tf_dir}" "${unlock_tf_dir}"
}

trap cleanup EXIT

render_root_module() {
  tf_dir="$1"
  bootstrap_namespace="$2"
  fault_injection_message="$3"
  secrets_mode="$4"
  flux_operator_image_tag="${5:-}"
  revision="${6:-1}"
  fixtures_dir="${tf_dir}-fixtures"
  fixture_root_name="$(basename "${fixtures_dir}")"
  prerequisites_dir="${fixtures_dir}/tenants"
  flux_instance_dir="${fixtures_dir}/clusters/test/flux-system"

  mkdir -p "${prerequisites_dir}" "${flux_instance_dir}"

  managed_secrets_yaml="$(
    if [ "${secrets_mode}" = "two" ]; then
      cat <<'YAML'
apiVersion: v1
kind: Secret
metadata:
  name: bootstrap-managed
type: Opaque
stringData:
  value: expected
---
apiVersion: v1
kind: Secret
metadata:
  name: bootstrap-managed-removed
type: Opaque
stringData:
  value: temporary
YAML
    elif [ "${secrets_mode}" = "rotated" ]; then
      cat <<'YAML'
apiVersion: v1
kind: Secret
metadata:
  name: bootstrap-managed
type: Opaque
stringData:
  value: rotated
YAML
    else
      cat <<'YAML'
apiVersion: v1
kind: Secret
metadata:
  name: bootstrap-managed
type: Opaque
stringData:
  value: expected
YAML
    fi
  )"

  cat > "${prerequisites_dir}/00-namespace.yaml" <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: bootstrap-prereq
EOF

  cat > "${prerequisites_dir}/01-configmap.yaml" <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: bootstrap-prereq
  namespace: bootstrap-prereq
data:
  value: initial
EOF

  cat > "${flux_instance_dir}/flux-instance.yaml" <<'EOF'
apiVersion: fluxcd.controlplane.io/v1
kind: FluxInstance
metadata:
  name: flux
  namespace: flux-system
  annotations:
    e2e-cluster-name: ${cluster_name}
spec:
  components:
  - source-controller
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

module "kind_cluster" {
  source = "${repo_root}/test/kind-cluster"
  name   = "${cluster_name}"
}

provider "helm" {
  kubernetes = {
    host                   = module.kind_cluster.host
    client_certificate     = module.kind_cluster.client_certificate
    client_key             = module.kind_cluster.client_key
    cluster_ca_certificate = module.kind_cluster.cluster_ca_certificate
  }
}

provider "kubernetes" {
  host                   = module.kind_cluster.host
  client_certificate     = module.kind_cluster.client_certificate
  client_key             = module.kind_cluster.client_key
  cluster_ca_certificate = module.kind_cluster.cluster_ca_certificate
}

resource "terraform_data" "kind_load_image" {
  depends_on = [module.kind_cluster]

  input = "${module_image}"

  provisioner "local-exec" {
    command = "kind load docker-image \${self.input} --name ${cluster_name}"
  }
}

module "bootstrap" {
  depends_on = [terraform_data.kind_load_image]

  source = "${repo_root}"

  bootstrap_namespace = "${bootstrap_namespace}"
  revision            = ${revision}

  job_image = {
    tag = "${image_tag}"
  }

  debug_fault_injection_message  = "${fault_injection_message}"
  debug_flux_operator_image_tag = "${flux_operator_image_tag}"

  gitops_resources = {
    flux_instance_path = "\${path.root}/../${fixture_root_name}/clusters/test/flux-system/flux-instance.yaml"
    prerequisites_paths = [
      "\${path.root}/../${fixture_root_name}/tenants/00-namespace.yaml",
      "\${path.root}/../${fixture_root_name}/tenants/01-configmap.yaml",
    ]
  }

  managed_resources = {
    secrets_yaml = <<YAML
${managed_secrets_yaml}
YAML
    runtime_info = {
      data = {
        cluster_name = "${cluster_name}"
      }
      labels = {
        "toolkit.fluxcd.io/runtime" = "true"
      }
      annotations = {
        "kustomize.toolkit.fluxcd.io/ssa" = "Merge"
      }
    }
  }
}
EOF
}

section "Cluster Setup"
note "Resetting kind cluster ${cluster_name}"
kind delete cluster --name "${cluster_name}" 2>/dev/null || true
note "Tagging local image ${image} as ${module_image} for module consumption"
docker tag "${image}" "${module_image}"

section "Happy Path"
note "Rendering success scenario Terraform root"
render_root_module "${success_tf_dir}" "flux-operator-bootstrap" "" "two"
note "Initializing success scenario"
terraform -chdir="${success_tf_dir}" init -no-color -backend=false

note "Running initial bootstrap apply"
terraform -chdir="${success_tf_dir}" apply -no-color -auto-approve
note "Verifying FluxInstance and Flux workloads are ready"
assert_flux_runtime_ready
note "Verifying ordered prerequisites and managed secrets were applied"
assert_bootstrap_inputs_applied
note "Verifying runtime-info ConfigMap was created in target namespace with data, labels, and annotations"
ri_value="$(kubectl --context "kind-${cluster_name}" -n flux-system get configmap/flux-runtime-info \
  -o jsonpath='{.data.cluster_name}')"
if [ "${ri_value}" != "${cluster_name}" ]; then
  echo "runtime-info ConfigMap did not contain expected cluster_name value" >&2
  echo "Expected: ${cluster_name}, Got: ${ri_value}" >&2
  exit 1
fi
ri_label="$(kubectl --context "kind-${cluster_name}" -n flux-system get configmap/flux-runtime-info \
  -o jsonpath='{.metadata.labels.toolkit\.fluxcd\.io/runtime}')"
if [ "${ri_label}" != "true" ]; then
  echo "runtime-info ConfigMap did not contain expected label" >&2
  echo "Expected: true, Got: ${ri_label}" >&2
  exit 1
fi
ri_annotation="$(kubectl --context "kind-${cluster_name}" -n flux-system get configmap/flux-runtime-info \
  -o jsonpath='{.metadata.annotations.kustomize\.toolkit\.fluxcd\.io/ssa}')"
if [ "${ri_annotation}" != "Merge" ]; then
  echo "runtime-info ConfigMap did not contain expected annotation" >&2
  echo "Expected: Merge, Got: ${ri_annotation}" >&2
  exit 1
fi
note "Verifying FluxInstance annotation was substituted with runtime info"
fi_annotation="$(kubectl --context "kind-${cluster_name}" -n flux-system get \
  fluxinstance.fluxcd.controlplane.io/flux \
  -o jsonpath='{.metadata.annotations.e2e-cluster-name}')"
if [ "${fi_annotation}" != "${cluster_name}" ]; then
  echo "FluxInstance annotation was not substituted with runtime info" >&2
  echo "Expected: ${cluster_name}, Got: ${fi_annotation}" >&2
  exit 1
fi
initial_managed_secret_uid="$(secret_uid bootstrap-managed)"
expected_inventory="$(printf '%s\n' '- ConfigMap/flux-system/flux-runtime-info' '- Secret/flux-system/bootstrap-managed' '- Secret/flux-system/bootstrap-managed-removed')"
if [ "$(inventory_entries flux-operator-bootstrap)" != "${expected_inventory}" ]; then
  echo "Managed secret inventory was not created with the expected entries" >&2
  echo "Expected: ${expected_inventory}" >&2
  echo "Got: $(inventory_entries flux-operator-bootstrap)" >&2
  exit 1
fi
note "Verifying only the completed Job, inventory, and managed secret remain in the bootstrap namespace"
remaining="$(kubectl --context "kind-${cluster_name}" -n flux-operator-bootstrap get all,secrets,configmaps \
  --no-headers -o custom-columns=KIND:.kind,NAME:.metadata.name 2>/dev/null \
  | grep -v "^Secret.*sh\.helm\.release" \
  | grep -v "^ConfigMap.*kube-root-ca\.crt" \
  | awk '{print $1, $2}' \
  | sort)"
expected="$(printf '%s\n' \
  "Job flux-operator-bootstrap" \
  "Pod flux-operator-bootstrap-" \
  "ConfigMap inventory" \
  "Secret flux-operator-bootstrap" \
  | sort)"
# Pod name has a random suffix, match by prefix
remaining_normalized="$(printf '%s\n' "${remaining}" | sed 's/^\(Pod flux-operator-bootstrap-\).*/\1/')"
if [ "${remaining_normalized}" != "${expected}" ]; then
  echo "Unexpected resources in bootstrap namespace after job completion:" >&2
  echo "Expected:" >&2
  echo "${expected}" >&2
  echo "Got:" >&2
  echo "${remaining}" >&2
  exit 1
fi
note "Verifying bootstrap ClusterRoleBinding was removed"
if kubectl --context "kind-${cluster_name}" get clusterrolebinding flux-operator-bootstrap >/dev/null 2>&1; then
  echo "Bootstrap ClusterRoleBinding still exists after job completion" >&2
  exit 1
fi
note "Verifying managed secret material did not land in Terraform state"
assert_no_secret_material_in_state "${success_tf_dir}"

section "No-op Plan"
note "Running plan with identical inputs to verify zero diff"
terraform -chdir="${success_tf_dir}" plan -no-color -detailed-exitcode
note "Confirmed: no changes when inputs are unchanged"

section "Idempotency"
note "Introducing drift, then removing one managed Secret from desired state"
kubectl --context "kind-${cluster_name}" apply --server-side --force-conflicts --field-manager=kubectl -f - >/dev/null <<'YAML'
apiVersion: v1
kind: Secret
metadata:
  name: bootstrap-managed
  namespace: flux-system
type: Opaque
stringData:
  value: drifted
YAML
kubectl --context "kind-${cluster_name}" -n bootstrap-prereq patch configmap bootstrap-prereq \
  --type merge \
  -p '{"data":{"value":"drifted"}}' >/dev/null
if ! secret_has_field_manager "kubectl"; then
  echo "Managed Secret was not updated with the kubectl field manager" >&2
  exit 1
fi
render_root_module "${success_tf_dir}" "flux-operator-bootstrap" "" "one" "" 2

note "Running second bootstrap apply to verify idempotent rerun"
terraform -chdir="${success_tf_dir}" apply -no-color -auto-approve
note "Re-verifying Flux runtime after idempotent rerun"
assert_flux_runtime_ready
note "Re-verifying managed secret material did not land in Terraform state"
assert_no_secret_material_in_state "${success_tf_dir}"
if [ "$(secret_value bootstrap-managed)" != "expected" ]; then
  echo "Managed Secret drift was not corrected by the second apply" >&2
  exit 1
fi
if [ "$(secret_uid bootstrap-managed)" != "${initial_managed_secret_uid}" ]; then
  echo "Managed Secret UID changed unexpectedly (should be updated in-place, not recreated)" >&2
  exit 1
fi
if secret_has_field_manager "kubectl"; then
  echo "Disallowed field manager 'kubectl' was not stripped from managed Secret after reconciliation" >&2
  exit 1
fi
if target_secret_exists "bootstrap-managed-removed"; then
  echo "Removed managed Secret was not garbage-collected by the second apply" >&2
  exit 1
fi
expected_inventory="$(printf '%s\n' '- ConfigMap/flux-system/flux-runtime-info' '- Secret/flux-system/bootstrap-managed')"
if [ "$(inventory_entries flux-operator-bootstrap)" != "${expected_inventory}" ]; then
  echo "Managed secret inventory was not updated after removing a Secret from desired state" >&2
  echo "Expected: ${expected_inventory}" >&2
  echo "Got: $(inventory_entries flux-operator-bootstrap)" >&2
  exit 1
fi
if [ "$(prerequisite_configmap_value)" != "drifted" ]; then
  echo "Prerequisite drift was unexpectedly reconciled" >&2
  exit 1
fi

section "Secret Rotation"
note "Rotating managed secret value (same revision, only content changes)"
render_root_module "${success_tf_dir}" "flux-operator-bootstrap" "" "rotated" "" 2
terraform -chdir="${success_tf_dir}" apply -no-color -auto-approve
if [ "$(secret_value bootstrap-managed)" != "rotated" ]; then
  echo "Managed Secret was not updated after rotation" >&2
  exit 1
fi
note "Verifying rotated secret material did not land in Terraform state"
assert_no_secret_material_in_state "${success_tf_dir}"

section "Revision Bump"
note "Bumping revision without changing content to verify forced re-run"
render_root_module "${success_tf_dir}" "flux-operator-bootstrap" "" "rotated" "" 3
terraform -chdir="${success_tf_dir}" apply -no-color -auto-approve
assert_flux_runtime_ready
if [ "$(secret_value bootstrap-managed)" != "rotated" ]; then
  echo "Managed Secret value changed unexpectedly after revision-only bump" >&2
  exit 1
fi

section "Destroy Behavior"
note "Verifying Flux resources exist before destroy"
kubectl_get_flux_operator_resources
kubectl --context "kind-${cluster_name}" -n flux-system get fluxinstance.fluxcd.controlplane.io/flux >/dev/null

note "Destroying happy-path bootstrap root (includes kind cluster)"
terraform -chdir="${success_tf_dir}" destroy -no-color -auto-approve

section "Failure Path"
note "Rendering failure scenario Terraform root"
render_root_module "${failure_tf_dir}" "flux-operator-bootstrap-failure" "intentional e2e fault injection" "one"
note "Initializing failure scenario"
terraform -chdir="${failure_tf_dir}" init -no-color -backend=false

note "Running fault-injected bootstrap apply to verify failure"
failure_apply_log="${failure_tf_dir}/apply.log"
set +e
terraform -chdir="${failure_tf_dir}" apply -no-color -auto-approve >"${failure_apply_log}" 2>&1
failure_status=$?
set -e
cat "${failure_apply_log}"

if [ "${failure_status}" -eq 0 ]; then
  echo "Fault-injected apply unexpectedly succeeded" >&2
  exit 1
fi

note "Re-rendering failure scenario without fault injection to verify recovery"
render_root_module "${failure_tf_dir}" "flux-operator-bootstrap-failure" "" "one" "" 2
terraform -chdir="${failure_tf_dir}" apply -no-color -auto-approve
assert_flux_runtime_ready
assert_no_secret_material_in_state "${failure_tf_dir}"

note "Destroying failure scenario (includes kind cluster)"
terraform -chdir="${failure_tf_dir}" destroy -no-color -auto-approve

section "Helm Release Unlock"
note "Rendering unlock scenario with working config for initial setup"
render_root_module "${unlock_tf_dir}" "flux-operator-bootstrap-unlock" "" "one"
note "Initializing unlock scenario"
terraform -chdir="${unlock_tf_dir}" init -no-color -backend=false
note "Running initial apply to install flux-operator"
terraform -chdir="${unlock_tf_dir}" apply -no-color -auto-approve
assert_flux_runtime_ready

note "Uninstalling flux-operator to set up unlock test"
helm --kube-context "kind-${cluster_name}" delete flux-operator -n flux-system --no-hooks || true
note "Re-rendering unlock scenario with bogus flux-operator image tag"
render_root_module "${unlock_tf_dir}" "flux-operator-bootstrap-unlock" "" "one" "bogus-tag-does-not-exist" 2
note "Running apply with bogus flux-operator image (should fail with timeout)"
unlock_apply_log="${unlock_tf_dir}/apply.log"
set +e
terraform -chdir="${unlock_tf_dir}" apply -no-color -auto-approve >"${unlock_apply_log}" 2>&1
unlock_status=$?
set -e
cat "${unlock_apply_log}"

if [ "${unlock_status}" -eq 0 ]; then
  echo "Bogus flux-operator image apply unexpectedly succeeded" >&2
  exit 1
fi

note "Verifying flux-operator Helm release is stuck in pending-install or was marked failed"
fo_status="$(helm --kube-context "kind-${cluster_name}" status flux-operator -n flux-system -o json 2>/dev/null \
  | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4 || true)"
if [ "${fo_status}" != "pending-install" ] && [ "${fo_status}" != "failed" ]; then
  echo "Expected flux-operator release in pending-install or failed state, got: ${fo_status}" >&2
  exit 1
fi

note "Re-rendering unlock scenario without bogus image to verify unlock and recovery"
render_root_module "${unlock_tf_dir}" "flux-operator-bootstrap-unlock" "" "one" "" 3
terraform -chdir="${unlock_tf_dir}" apply -no-color -auto-approve
assert_flux_runtime_ready
note "Verifying flux-operator release is now deployed"
fo_status="$(helm --kube-context "kind-${cluster_name}" status flux-operator -n flux-system -o json 2>/dev/null \
  | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4 || true)"
if [ "${fo_status}" != "deployed" ]; then
  echo "Expected flux-operator release in deployed state after unlock recovery, got: ${fo_status}" >&2
  exit 1
fi

note "Destroying unlock scenario (includes kind cluster)"
terraform -chdir="${unlock_tf_dir}" destroy -no-color -auto-approve

section "Assertions"
note "Verified prerequisites, managed secret reconciliation, secret rotation, RBAC cleanup, Flux readiness, idempotent rerun, clean destroy, failure recovery, and Helm release unlock"
