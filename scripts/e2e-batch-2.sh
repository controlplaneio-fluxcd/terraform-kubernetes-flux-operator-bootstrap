#!/usr/bin/env bash
# Batch 2: Failure path — fault injection and recovery.

cluster_name="flux-operator-bootstrap-e2e-2"

# shellcheck source=e2e-helpers.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/e2e-helpers.sh"

failure_tf_dir="$(mktemp -d)"
failure_apply_log=""

cleanup() {
  kind delete cluster --name "${cluster_name}" 2>/dev/null || true
  rm -rf "${failure_tf_dir}"
}

trap cleanup EXIT

section "Cluster Setup"
note "Resetting kind cluster ${cluster_name}"
kind delete cluster --name "${cluster_name}" 2>/dev/null || true

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

section "Re-apply Not Yet Adopted"
note "Simulating stale resources from a previous failed bootstrap by stripping Flux ownership labels"
# After a successful bootstrap, Flux adopts the FluxInstance, operator
# Deployment, and prerequisites by adding kustomize.toolkit.fluxcd.io/name or
# helm.toolkit.fluxcd.io/name labels. We strip these to simulate resources left
# behind by a failed bootstrap that Flux never adopted.
kubectl --context "kind-${cluster_name}" -n flux-system label fluxinstance flux \
  kustomize.toolkit.fluxcd.io/name- kustomize.toolkit.fluxcd.io/namespace- >/dev/null 2>&1 || true
kubectl --context "kind-${cluster_name}" -n flux-system label deployment flux-operator \
  helm.toolkit.fluxcd.io/name- helm.toolkit.fluxcd.io/namespace- >/dev/null 2>&1 || true
# Prerequisites (Namespace and ConfigMap) won't have Flux ownership labels in
# this test since no Flux Kustomization manages them, so they're already in
# the "not adopted" state.
note "Verifying ownership labels were removed"
fi_label="$(kubectl --context "kind-${cluster_name}" -n flux-system get fluxinstance flux \
  -o jsonpath='{.metadata.labels.kustomize\.toolkit\.fluxcd\.io/name}' 2>/dev/null || true)"
if [ -n "${fi_label}" ]; then
  echo "FluxInstance still has kustomize-controller ownership label after removal" >&2
  exit 1
fi
op_label="$(kubectl --context "kind-${cluster_name}" -n flux-system get deployment flux-operator \
  -o jsonpath='{.metadata.labels.helm\.toolkit\.fluxcd\.io/name}' 2>/dev/null || true)"
if [ -n "${op_label}" ]; then
  echo "flux-operator Deployment still has helm-controller ownership label after removal" >&2
  exit 1
fi
note "Re-running bootstrap to verify unadopted resources are re-applied"
render_root_module "${failure_tf_dir}" "flux-operator-bootstrap-failure" "" "one" "" 3
terraform -chdir="${failure_tf_dir}" apply -no-color -auto-approve
assert_flux_runtime_ready
note "Verifying bootstrap logs show re-apply (not skip) for unadopted resources"
bootstrap_log="$(kubectl --context "kind-${cluster_name}" -n flux-operator-bootstrap-failure \
  logs job/flux-operator-bootstrap 2>/dev/null || true)"
if ! printf '%s' "${bootstrap_log}" | grep -q "reapply.*Namespace"; then
  echo "Bootstrap did not re-apply prerequisite Namespace when not adopted by Flux" >&2
  echo "Bootstrap log:" >&2
  printf '%s\n' "${bootstrap_log}" >&2
  exit 1
fi
if ! printf '%s' "${bootstrap_log}" | grep -q "reapply.*ConfigMap"; then
  echo "Bootstrap did not re-apply prerequisite ConfigMap when not adopted by Flux" >&2
  echo "Bootstrap log:" >&2
  printf '%s\n' "${bootstrap_log}" >&2
  exit 1
fi
if ! printf '%s' "${bootstrap_log}" | grep -q "Reapply FluxInstance"; then
  echo "Bootstrap did not re-apply FluxInstance when ownership label was missing" >&2
  echo "Bootstrap log:" >&2
  printf '%s\n' "${bootstrap_log}" >&2
  exit 1
fi
if ! printf '%s' "${bootstrap_log}" | grep -q "Upgrade Flux Operator"; then
  echo "Bootstrap did not upgrade Flux Operator when ownership label was missing" >&2
  echo "Bootstrap log:" >&2
  printf '%s\n' "${bootstrap_log}" >&2
  exit 1
fi

section "Skip When Adopted"
note "Simulating Flux adoption by adding ownership labels back"
kubectl --context "kind-${cluster_name}" -n flux-system label deployment flux-operator \
  helm.toolkit.fluxcd.io/name=flux-operator helm.toolkit.fluxcd.io/namespace=flux-system >/dev/null
note "Re-running bootstrap to verify adopted operator is fully skipped"
render_root_module "${failure_tf_dir}" "flux-operator-bootstrap-failure" "" "one" "" 4
terraform -chdir="${failure_tf_dir}" apply -no-color -auto-approve
assert_flux_runtime_ready
note "Verifying bootstrap logs show adopted (no unlock, no install/upgrade)"
bootstrap_log="$(kubectl --context "kind-${cluster_name}" -n flux-operator-bootstrap-failure \
  logs job/flux-operator-bootstrap 2>/dev/null || true)"
if ! printf '%s' "${bootstrap_log}" | grep -q "Flux Operator exists (adopted by Flux)"; then
  echo "Bootstrap did not detect adopted Flux Operator" >&2
  echo "Bootstrap log:" >&2
  printf '%s\n' "${bootstrap_log}" >&2
  exit 1
fi
if printf '%s' "${bootstrap_log}" | grep -q "Unlocking Helm release flux-operator"; then
  echo "Bootstrap tried to unlock adopted Flux Operator release" >&2
  echo "Bootstrap log:" >&2
  printf '%s\n' "${bootstrap_log}" >&2
  exit 1
fi
if printf '%s' "${bootstrap_log}" | grep -q "Upgrade Flux Operator"; then
  echo "Bootstrap tried to upgrade adopted Flux Operator" >&2
  echo "Bootstrap log:" >&2
  printf '%s\n' "${bootstrap_log}" >&2
  exit 1
fi
if printf '%s' "${bootstrap_log}" | grep -q "Install Flux Operator"; then
  echo "Bootstrap tried to install adopted Flux Operator" >&2
  echo "Bootstrap log:" >&2
  printf '%s\n' "${bootstrap_log}" >&2
  exit 1
fi

section "Prerequisite Chart values_yaml with envsubst"
note "Re-rendering with a prerequisite chart whose values_yaml contains a runtime_info variable"
prereq_charts="[{
      name        = \"podinfo\"
      repository  = \"ghcr.io/stefanprodan/charts/podinfo\"
      version     = \"${e2e_podinfo_version}\"
      namespace   = \"podinfo\"
      values_yaml = yamlencode({
        ui = {
          message = \"\$\${cluster_name}\"
        }
      })
    }]"
render_root_module "${failure_tf_dir}" "flux-operator-bootstrap-failure" "" "one" "" 5 "" "5m" "" "${prereq_charts}"
terraform -chdir="${failure_tf_dir}" apply -no-color -auto-approve
assert_flux_runtime_ready
note "Verifying podinfo deployment has the substituted cluster name in ui.message"
kubectl --context "kind-${cluster_name}" -n podinfo rollout status deployment/podinfo --timeout=60s >/dev/null
ui_message="$(kubectl --context "kind-${cluster_name}" -n podinfo get deployment/podinfo \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="PODINFO_UI_MESSAGE")].value}')"
if [ "${ui_message}" != "${cluster_name}" ]; then
  echo "Expected podinfo ui.message to be '${cluster_name}' (substituted from runtime_info), got: '${ui_message}'" >&2
  exit 1
fi

note "Destroying failure scenario (includes kind cluster)"
terraform -chdir="${failure_tf_dir}" destroy -no-color -auto-approve

section "Assertions"
note "Verified failure recovery, re-apply of unadopted resources, skip when adopted, and values_yaml envsubst"
print_elapsed_total
