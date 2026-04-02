#!/usr/bin/env bash
# Batch 2: Error recovery — failure path (fault injection) and Helm release unlock.

cluster_name="flux-operator-bootstrap-e2e-2"

# shellcheck source=e2e-helpers.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/e2e-helpers.sh"

failure_tf_dir="$(mktemp -d)"
unlock_tf_dir="$(mktemp -d)"
failure_apply_log=""

cleanup() {
  kind delete cluster --name "${cluster_name}" 2>/dev/null || true
  rm -rf "${failure_tf_dir}" "${unlock_tf_dir}"
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
render_root_module "${unlock_tf_dir}" "flux-operator-bootstrap-unlock" "" "one" "bogus-tag-does-not-exist" 2 "" "1m"
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
note "Verified failure recovery and Helm release unlock"
print_elapsed_total
