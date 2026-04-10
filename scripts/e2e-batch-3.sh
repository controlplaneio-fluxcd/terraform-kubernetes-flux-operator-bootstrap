#!/usr/bin/env bash
# Batch 3: Prerequisite Helm charts.

cluster_name="flux-operator-bootstrap-e2e-3"

# shellcheck source=e2e-helpers.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/e2e-helpers.sh"

prereq_charts_tf_dir="$(mktemp -d)"

cleanup() {
  kind delete cluster --name "${cluster_name}" 2>/dev/null || true
  rm -rf "${prereq_charts_tf_dir}"
}

trap cleanup EXIT

section "Cluster Setup"
note "Resetting kind cluster ${cluster_name}"
kind delete cluster --name "${cluster_name}" 2>/dev/null || true

section "Prerequisite Charts"
note "Rendering scenario with a prerequisite Helm chart (podinfo)"
prereq_charts="[{
      name       = \"podinfo\"
      repository = \"ghcr.io/stefanprodan/charts/podinfo\"
      version    = \"${e2e_podinfo_version}\"
      namespace  = \"podinfo\"
      values_yaml = \"\"
    }]"
render_root_module "${prereq_charts_tf_dir}" "flux-operator-bootstrap-prereq-charts" "" "one" "" 1 "" "5m" "" "${prereq_charts}"
note "Initializing prerequisite charts scenario"
terraform -chdir="${prereq_charts_tf_dir}" init -no-color -backend=false
note "Running apply with prerequisite chart"
terraform -chdir="${prereq_charts_tf_dir}" apply -no-color -auto-approve
assert_flux_runtime_ready
note "Verifying podinfo Helm release is deployed"
podinfo_status="$(helm --kube-context "kind-${cluster_name}" status podinfo -n podinfo -o json 2>/dev/null \
  | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4 || true)"
if [ "${podinfo_status}" != "deployed" ]; then
  echo "Expected podinfo Helm release in deployed state, got: ${podinfo_status}" >&2
  exit 1
fi
note "Verifying podinfo deployment is running"
kubectl --context "kind-${cluster_name}" -n podinfo rollout status deployment/podinfo --timeout=60s >/dev/null

section "Prerequisite Charts Create-If-Missing"
note "Re-running bootstrap to verify prerequisite chart is skipped when already deployed"
render_root_module "${prereq_charts_tf_dir}" "flux-operator-bootstrap-prereq-charts" "" "one" "" 2 "" "5m" "" "${prereq_charts}"
terraform -chdir="${prereq_charts_tf_dir}" apply -no-color -auto-approve
assert_flux_runtime_ready
note "Verifying bootstrap logs show skip (not install/upgrade) for existing chart"
bootstrap_log="$(kubectl --context "kind-${cluster_name}" -n flux-operator-bootstrap-prereq-charts \
  logs job/flux-operator-bootstrap 2>/dev/null || true)"
if ! printf '%s' "${bootstrap_log}" | grep -q "skip chart podinfo (already exists)"; then
  echo "Bootstrap did not skip prerequisite chart that already exists" >&2
  echo "Bootstrap log:" >&2
  printf '%s\n' "${bootstrap_log}" >&2
  exit 1
fi
if printf '%s' "${bootstrap_log}" | grep -q "Install chart podinfo"; then
  echo "Bootstrap tried to install prerequisite chart that already exists" >&2
  echo "Bootstrap log:" >&2
  printf '%s\n' "${bootstrap_log}" >&2
  exit 1
fi

section "Prerequisite Charts Flux Adoption Check"
note "Re-rendering with flux_adoption_check pointing to podinfo deployment"
prereq_charts_with_adoption="[{
      name       = \"podinfo\"
      repository = \"ghcr.io/stefanprodan/charts/podinfo\"
      version    = \"${e2e_podinfo_version}\"
      namespace  = \"podinfo\"
      values_yaml = \"\"
      flux_adoption_check = {
        resource  = \"deployment\"
        api_group = \"apps\"
        name      = \"podinfo\"
        namespace = \"podinfo\"
      }
    }]"
note "Simulating Flux adoption by adding ownership label to podinfo deployment"
kubectl --context "kind-${cluster_name}" -n podinfo label deployment podinfo \
  helm.toolkit.fluxcd.io/name=podinfo helm.toolkit.fluxcd.io/namespace=podinfo >/dev/null
note "Re-running bootstrap to verify adopted chart is skipped"
render_root_module "${prereq_charts_tf_dir}" "flux-operator-bootstrap-prereq-charts" "" "one" "" 3 "" "5m" "" "${prereq_charts_with_adoption}"
terraform -chdir="${prereq_charts_tf_dir}" apply -no-color -auto-approve
assert_flux_runtime_ready
note "Verifying bootstrap logs show adoption skip"
bootstrap_log="$(kubectl --context "kind-${cluster_name}" -n flux-operator-bootstrap-prereq-charts \
  logs job/flux-operator-bootstrap 2>/dev/null || true)"
if ! printf '%s' "${bootstrap_log}" | grep -q "skip chart podinfo (adopted by Flux)"; then
  echo "Bootstrap did not skip adopted prerequisite chart" >&2
  echo "Bootstrap log:" >&2
  printf '%s\n' "${bootstrap_log}" >&2
  exit 1
fi

note "Destroying prerequisite charts scenario"
terraform -chdir="${prereq_charts_tf_dir}" destroy -no-color -auto-approve

section "Assertions"
note "Verified prerequisite charts: create-if-missing and flux adoption check"
print_elapsed_total
