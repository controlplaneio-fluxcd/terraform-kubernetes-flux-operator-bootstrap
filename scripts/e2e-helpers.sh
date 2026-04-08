#!/usr/bin/env bash
set -euo pipefail

export NO_COLOR=1

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
image_repository="terraform-kubernetes-flux-operator-bootstrap-test"
image_tag="dev"
image="${image_repository}:${image_tag}"
inventory_config_map_name="inventory"

# Versions of third-party charts used across e2e tests.
e2e_podinfo_version="6.11.2"
e2e_cilium_version="1.19.2"
e2e_spire_crds_version="0.5.0"
e2e_spire_version="0.28.3"

_start_time="${EPOCHREALTIME/./}"
_last_section_time="${_start_time}"

section() {
  title="$1"
  now="${EPOCHREALTIME/./}"
  elapsed_us=$(( now - _last_section_time ))
  elapsed_s=$(( elapsed_us / 1000000 ))
  mins=$(( elapsed_s / 60 ))
  secs=$(( elapsed_s % 60 ))
  printf '\n========== %s ========== (previous section: %dm%02ds)\n' "${title}" "${mins}" "${secs}"
  _last_section_time="${now}"
}

note() {
  printf '[e2e] %s\n' "$1"
}

print_elapsed_total() {
  now="${EPOCHREALTIME/./}"
  elapsed_us=$(( now - _start_time ))
  elapsed_s=$(( elapsed_us / 1000000 ))
  mins=$(( elapsed_s / 60 ))
  secs=$(( elapsed_s % 60 ))
  printf '[e2e] Total elapsed: %dm%02ds\n' "${mins}" "${secs}"
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

render_root_module() {
  tf_dir="$1"
  bootstrap_namespace="$2"
  fault_injection_message="$3"
  secrets_mode="$4"
  flux_operator_image_tag="${5:-}"
  revision="${6:-1}"
  job_scheduling="${7:-}"
  timeout="${8:-5m}"
  operator_values="${9:-}"
  prerequisite_charts="${10:-}"
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
  cluster: ${cluster_name}
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

  input = "${image}"

  provisioner "local-exec" {
    command = "kind load docker-image \${self.input} --name ${cluster_name}"
  }
}

module "bootstrap" {
  depends_on = [terraform_data.kind_load_image]

  source = "${repo_root}"

  bootstrap_namespace = "${bootstrap_namespace}"
  revision            = ${revision}

  job = {
    image = {
      repository = "${image_repository}"
    }
$(if [ "${job_scheduling}" = "custom" ]; then
cat <<'JOBEOF'
    affinity = {
      nodeAffinity = {
        preferredDuringSchedulingIgnoredDuringExecution = [{
          weight = 1
          preference = {
            matchExpressions = [{
              key      = "node-role.kubernetes.io/control-plane"
              operator = "Exists"
            }]
          }
        }]
      }
    }
    tolerations = [{
      key      = "node-role.kubernetes.io/control-plane"
      operator = "Exists"
      effect   = "NoSchedule"
    }]
JOBEOF
fi)
  }

  timeout = "${timeout}"

  debug_fault_injection_message  = "${fault_injection_message}"
  debug_flux_operator_image_tag = "${flux_operator_image_tag}"

  gitops_resources = {
    instance_path = "\${path.root}/../${fixture_root_name}/clusters/test/flux-system/flux-instance.yaml"
    prerequisites = {
      paths = [
        "\${path.root}/../${fixture_root_name}/tenants/00-namespace.yaml",
        "\${path.root}/../${fixture_root_name}/tenants/01-configmap.yaml",
      ]
$(if [ -n "${prerequisite_charts}" ]; then
cat <<PCHEOF
      charts = ${prerequisite_charts}
PCHEOF
fi)
    }
$(if [ -n "${operator_values}" ]; then
cat <<OPEOF
    operator_chart = {
      values = ${operator_values}
    }
OPEOF
fi)
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
