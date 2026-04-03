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

note "Destroying failure scenario (includes kind cluster)"
terraform -chdir="${failure_tf_dir}" destroy -no-color -auto-approve

section "Assertions"
note "Verified failure recovery"
print_elapsed_total
