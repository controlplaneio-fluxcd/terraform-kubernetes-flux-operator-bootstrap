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
prereq_charts='[{
      name       = "podinfo"
      repository = "ghcr.io/stefanprodan/charts/podinfo"
      version    = "6.7.0"
      namespace  = "podinfo"
      values     = {}
    }]'
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
note "Destroying prerequisite charts scenario"
terraform -chdir="${prereq_charts_tf_dir}" destroy -no-color -auto-approve

section "Assertions"
note "Verified prerequisite charts"
print_elapsed_total
