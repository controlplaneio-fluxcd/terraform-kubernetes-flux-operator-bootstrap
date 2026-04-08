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
# After a successful bootstrap, Flux adopts the FluxInstance and operator
# Deployment by adding kustomize.toolkit.fluxcd.io/name and
# helm.toolkit.fluxcd.io/name labels respectively. We strip these to simulate
# resources left behind by a failed bootstrap that Flux never adopted.
kubectl --context "kind-${cluster_name}" -n flux-system label fluxinstance flux \
  kustomize.toolkit.fluxcd.io/name- kustomize.toolkit.fluxcd.io/namespace- >/dev/null 2>&1 || true
kubectl --context "kind-${cluster_name}" -n flux-system label deployment flux-operator \
  helm.toolkit.fluxcd.io/name- helm.toolkit.fluxcd.io/namespace- >/dev/null 2>&1 || true
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

note "Destroying failure scenario (includes kind cluster)"
terraform -chdir="${failure_tf_dir}" destroy -no-color -auto-approve

section "Assertions"
note "Verified failure recovery and re-apply of unadopted resources"
print_elapsed_total
