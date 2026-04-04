#!/usr/bin/env bash
# Critical components e2e: validates bootstrapping a cluster with prerequisite
# Helm charts that must be running before Flux can start. Tests the full
# prerequisites.charts flow with real-world charts and FluxInstance kustomize
# patches that depend on those prerequisites.

cluster_name="flux-operator-bootstrap-e2e-critical"

# shellcheck source=e2e-helpers.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/e2e-helpers.sh"

# Read GHCR token from env var (CI) or local file (dev).
# Trim whitespace/newlines that may be present in secrets or files.
ghcr_token="${GHCR_TOKEN:-}"
if [ -z "${ghcr_token}" ] && [ -f "${repo_root}/ghcr.token" ]; then
  ghcr_token="$(cat "${repo_root}/ghcr.token")"
fi
ghcr_token="$(printf '%s' "${ghcr_token}" | tr -d '[:space:]')"
if [ -z "${ghcr_token}" ]; then
  echo "GHCR_TOKEN env var or ghcr.token file required for critical components e2e" >&2
  exit 1
fi

critical_tf_dir="$(mktemp -d)"

cleanup() {
  kind delete cluster --name "${cluster_name}" 2>/dev/null || true
  rm -rf "${critical_tf_dir}"
}

trap cleanup EXIT

# render_critical_components_root_module renders a Terraform root module that
# bootstraps Flux with prerequisite Helm charts. Uses direct kubeconfig since
# the cluster is created outside Terraform. $1: output directory.
render_critical_components_root_module() {
  tf_dir="$1"
  fixtures_dir="${tf_dir}-fixtures"
  flux_instance_dir="${fixtures_dir}/clusters/test/flux-system"
  fixture_root_name="$(basename "${fixtures_dir}")"

  mkdir -p "${flux_instance_dir}"

  # The FluxInstance patches Flux Deployments to mount the SPIFFE CSI driver
  # volume at /spiffe-workload-api, proving the CSI driver is available.
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
  distribution:
    version: 2.x
    registry: ghcr.io/fluxcd
  kustomize:
    patches:
      - target:
          kind: Deployment
        patch: |
          - op: add
            path: /spec/template/spec/volumes/-
            value:
              name: spiffe-workload-api
              csi:
                driver: csi.spiffe.io
                readOnly: true
          - op: add
            path: /spec/template/spec/containers/0/volumeMounts/-
            value:
              name: spiffe-workload-api
              mountPath: /spiffe-workload-api
              readOnly: true
EOF

  # Build the dockerconfigjson from the GHCR token and write it to a file
  # that Terraform reads via file(). This avoids quoting issues in HCL.
  ghcr_auth="$(printf 'flux:%s' "${ghcr_token}" | base64 -w 0)"
  printf '{"auths":{"ghcr.io":{"auth":"%s"}}}' "${ghcr_auth}" > "${tf_dir}/registry-credentials.json"

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
    config_context = "kind-${cluster_name}"
  }
}

provider "kubernetes" {
  config_path    = pathexpand("~/.kube/config")
  config_context = "kind-${cluster_name}"
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
  timeout  = "10m"

  job = {
    image = {
      repository = "${image_repository}"
    }
    registry_credentials = file("\${path.root}/registry-credentials.json")
  }

  gitops_resources = {
    instance_path = "\${path.root}/../${fixture_root_name}/clusters/test/flux-system/flux-instance.yaml"
    prerequisites = {
      charts = [
        {
          name       = "spire-crds"
          repository = "ghcr.io/spiffe/helm-charts/spire-crds"
          namespace  = "spire-server"
          version    = "0.5.0"
        },
        {
          name       = "spire"
          repository = "ghcr.io/spiffe/helm-charts/spire"
          namespace  = "spire-server"
          version    = "0.28.3"
          values = {
            global = {
              spire = {
                clusterName = "${cluster_name}"
                trustDomain = "e2e.test"
              }
            }
          }
        },
      ]
    }
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

section "SPIRE"
note "Rendering Terraform root with SPIRE prerequisite charts"
render_critical_components_root_module "${critical_tf_dir}"
note "Initializing Terraform"
terraform -chdir="${critical_tf_dir}" init -no-color -backend=false
note "Applying bootstrap with SPIRE prerequisite charts"
if ! terraform -chdir="${critical_tf_dir}" apply -no-color -auto-approve; then
  note "Bootstrap failed, dumping job logs"
  dump_bootstrap_logs "flux-operator-bootstrap"
  exit 1
fi

note "Verifying SPIRE CRDs are installed"
crd_count="$(kubectl --context "kind-${cluster_name}" get crds -o name | grep -c 'spiffe.io' || true)"
if [ "${crd_count}" -lt 2 ]; then
  echo "Expected at least 2 SPIRE CRDs, got ${crd_count}" >&2
  exit 1
fi

note "Verifying spire-crds Helm release is deployed"
spire_crds_status="$(helm --kube-context "kind-${cluster_name}" status spire-crds -n spire-server -o json 2>/dev/null \
  | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4 || true)"
if [ "${spire_crds_status}" != "deployed" ]; then
  echo "Expected spire-crds Helm release in deployed state, got: ${spire_crds_status}" >&2
  exit 1
fi

note "Verifying spire Helm release is deployed"
spire_status="$(helm --kube-context "kind-${cluster_name}" status spire -n spire-server -o json 2>/dev/null \
  | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4 || true)"
if [ "${spire_status}" != "deployed" ]; then
  echo "Expected spire Helm release in deployed state, got: ${spire_status}" >&2
  exit 1
fi

note "Verifying SPIFFE CSI driver DaemonSet is running"
# The CSI driver DaemonSet name and namespace depend on the chart's defaults.
# Find it by label rather than hardcoding.
csi_ns="$(kubectl --context "kind-${cluster_name}" get daemonsets -A \
  -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' \
  | grep spiffe-csi-driver | head -1)"
if [ -z "${csi_ns}" ]; then
  echo "SPIFFE CSI driver DaemonSet not found in any namespace" >&2
  kubectl --context "kind-${cluster_name}" get daemonsets -A >&2
  exit 1
fi
csi_namespace="$(echo "${csi_ns}" | cut -d/ -f1)"
csi_name="$(echo "${csi_ns}" | cut -d/ -f2)"
kubectl --context "kind-${cluster_name}" -n "${csi_namespace}" rollout status "daemonset/${csi_name}" --timeout=120s >/dev/null

note "Verifying Flux Operator and FluxInstance are ready"
assert_flux_runtime_ready

note "Verifying Flux Deployments have the SPIFFE CSI volume mount"
for deploy in source-controller kustomize-controller; do
  volume_name="$(kubectl --context "kind-${cluster_name}" -n flux-system get "deployment/${deploy}" \
    -o jsonpath='{.spec.template.spec.volumes[?(@.csi.driver=="csi.spiffe.io")].name}')"
  if [ "${volume_name}" != "spiffe-workload-api" ]; then
    echo "Deployment ${deploy} does not have the SPIFFE CSI volume" >&2
    echo "Expected volume name: spiffe-workload-api, Got: ${volume_name}" >&2
    exit 1
  fi
  mount_path="$(kubectl --context "kind-${cluster_name}" -n flux-system get "deployment/${deploy}" \
    -o jsonpath='{.spec.template.spec.containers[0].volumeMounts[?(@.name=="spiffe-workload-api")].mountPath}')"
  if [ "${mount_path}" != "/spiffe-workload-api" ]; then
    echo "Deployment ${deploy} does not have the SPIFFE CSI volume mount" >&2
    echo "Expected mount path: /spiffe-workload-api, Got: ${mount_path}" >&2
    exit 1
  fi
done

section "Destroy"
note "Destroying critical components scenario"
terraform -chdir="${critical_tf_dir}" destroy -no-color -auto-approve

section "Assertions"
note "Verified critical component prerequisite charts (SPIRE), CSI driver, and Flux CSI volume mount"
print_elapsed_total
