#!/usr/bin/env bash
# Batch 1: Happy path lifecycle — bootstrap, idempotency, secret rotation,
# revision bump, custom job scheduling, and clean destroy.

cluster_name="flux-operator-bootstrap-e2e-1"

# shellcheck source=e2e-helpers.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/e2e-helpers.sh"

success_tf_dir="$(mktemp -d)"

cleanup() {
  kind delete cluster --name "${cluster_name}" 2>/dev/null || true
  rm -rf "${success_tf_dir}"
}

trap cleanup EXIT

section "Cluster Setup"
note "Resetting kind cluster ${cluster_name}"
kind delete cluster --name "${cluster_name}" 2>/dev/null || true

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
note "Verifying job pod has default node affinity for linux"
job_affinity="$(kubectl --context "kind-${cluster_name}" -n flux-operator-bootstrap get job flux-operator-bootstrap \
  -o jsonpath='{.spec.template.spec.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].key}')"
if [ "${job_affinity}" != "kubernetes.io/os" ]; then
  echo "Job pod did not have the expected default node affinity" >&2
  echo "Expected key: kubernetes.io/os, Got: ${job_affinity}" >&2
  exit 1
fi
job_affinity_values="$(kubectl --context "kind-${cluster_name}" -n flux-operator-bootstrap get job flux-operator-bootstrap \
  -o jsonpath='{.spec.template.spec.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].values[0]}')"
if [ "${job_affinity_values}" != "linux" ]; then
  echo "Job pod node affinity did not have the expected values" >&2
  echo "Expected: linux, Got: ${job_affinity_values}" >&2
  exit 1
fi
note "Verifying job pod has no tolerations by default"
job_tolerations="$(kubectl --context "kind-${cluster_name}" -n flux-operator-bootstrap get job flux-operator-bootstrap \
  -o jsonpath='{.spec.template.spec.tolerations}')"
if [ -n "${job_tolerations}" ]; then
  echo "Job pod unexpectedly has tolerations set by default" >&2
  echo "Got: ${job_tolerations}" >&2
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

section "Custom Job Scheduling"
note "Re-rendering with custom affinity and tolerations"
render_root_module "${success_tf_dir}" "flux-operator-bootstrap" "" "rotated" "" 4 "custom"
terraform -chdir="${success_tf_dir}" apply -no-color -auto-approve
assert_flux_runtime_ready
note "Verifying job pod has custom affinity"
custom_affinity_key="$(kubectl --context "kind-${cluster_name}" -n flux-operator-bootstrap get job flux-operator-bootstrap \
  -o jsonpath='{.spec.template.spec.affinity.nodeAffinity.preferredDuringSchedulingIgnoredDuringExecution[0].preference.matchExpressions[0].key}')"
if [ "${custom_affinity_key}" != "node-role.kubernetes.io/control-plane" ]; then
  echo "Job pod did not have the expected custom affinity" >&2
  echo "Expected key: node-role.kubernetes.io/control-plane, Got: ${custom_affinity_key}" >&2
  exit 1
fi
note "Verifying job pod has custom tolerations"
custom_toleration_key="$(kubectl --context "kind-${cluster_name}" -n flux-operator-bootstrap get job flux-operator-bootstrap \
  -o jsonpath='{.spec.template.spec.tolerations[0].key}')"
if [ "${custom_toleration_key}" != "node-role.kubernetes.io/control-plane" ]; then
  echo "Job pod did not have the expected custom toleration" >&2
  echo "Expected key: node-role.kubernetes.io/control-plane, Got: ${custom_toleration_key}" >&2
  exit 1
fi
custom_toleration_effect="$(kubectl --context "kind-${cluster_name}" -n flux-operator-bootstrap get job flux-operator-bootstrap \
  -o jsonpath='{.spec.template.spec.tolerations[0].effect}')"
if [ "${custom_toleration_effect}" != "NoSchedule" ]; then
  echo "Job pod did not have the expected custom toleration effect" >&2
  echo "Expected: NoSchedule, Got: ${custom_toleration_effect}" >&2
  exit 1
fi

section "Operator Chart Values"
note "Uninstalling flux-operator to test fresh install with custom values"
helm --kube-context "kind-${cluster_name}" delete flux-operator -n flux-system --no-hooks || true
note "Re-rendering with custom operator chart values"
operator_values='{
    tolerations = [{
      key      = "node-role.kubernetes.io/control-plane"
      operator = "Exists"
      effect   = "NoSchedule"
    }]
  }'
render_root_module "${success_tf_dir}" "flux-operator-bootstrap" "" "rotated" "" 5 "" "5m" "${operator_values}"
terraform -chdir="${success_tf_dir}" apply -no-color -auto-approve
assert_flux_runtime_ready
note "Verifying flux-operator deployment has custom tolerations from operator.values"
op_toleration_key="$(kubectl --context "kind-${cluster_name}" -n flux-system get deployment flux-operator \
  -o jsonpath='{.spec.template.spec.tolerations[0].key}')"
if [ "${op_toleration_key}" != "node-role.kubernetes.io/control-plane" ]; then
  echo "flux-operator deployment did not have the expected toleration from operator.values" >&2
  echo "Expected key: node-role.kubernetes.io/control-plane, Got: ${op_toleration_key}" >&2
  exit 1
fi
op_toleration_effect="$(kubectl --context "kind-${cluster_name}" -n flux-system get deployment flux-operator \
  -o jsonpath='{.spec.template.spec.tolerations[0].effect}')"
if [ "${op_toleration_effect}" != "NoSchedule" ]; then
  echo "flux-operator deployment did not have the expected toleration effect from operator.values" >&2
  echo "Expected: NoSchedule, Got: ${op_toleration_effect}" >&2
  exit 1
fi

section "Destroy Behavior"
note "Verifying Flux resources exist before destroy"
kubectl_get_flux_operator_resources
kubectl --context "kind-${cluster_name}" -n flux-system get fluxinstance.fluxcd.controlplane.io/flux >/dev/null

note "Destroying happy-path bootstrap root (includes kind cluster)"
terraform -chdir="${success_tf_dir}" destroy -no-color -auto-approve

section "Assertions"
note "Verified prerequisites, managed secret reconciliation, secret rotation, RBAC cleanup, Flux readiness, idempotent rerun, job scheduling (affinity/tolerations), operator chart values, and clean destroy"
print_elapsed_total
