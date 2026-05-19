#!/usr/bin/env bash
# Offline-plan smoke test. Validates the README claim that the module does not
# require cluster connectivity during `terraform plan`, so it can live in the
# same Terraform root module that creates the cluster.
#
# The fixture at test/offline-plan points the kubernetes and helm providers
# at https://127.0.0.1:1 with bogus credentials. With empty state there is
# nothing to refresh, so plan must succeed without any API call. If the
# module ever picked up a resource that contacts the API at plan time (e.g.
# kubernetes_manifest), this test would fail.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
test_dir="$repo_root/test/offline-plan"

plan_log="$(mktemp)"

cleanup() {
  rm -f "$plan_log"
  rm -rf "$test_dir/.terraform" "$test_dir/.terraform.lock.hcl" \
    "$test_dir/terraform.tfstate" "$test_dir/terraform.tfstate.backup"
}
trap cleanup EXIT

echo "[offline-plan] terraform=$(command -v terraform)"
terraform -chdir="$test_dir" init -backend=false -no-color

if ! terraform -chdir="$test_dir" plan -no-color -out=/dev/null > "$plan_log" 2>&1; then
  cat "$plan_log"
  echo "FAIL: terraform plan failed against unreachable cluster" >&2
  exit 1
fi
cat "$plan_log"

# Sanity check: the plan should propose creating the bootstrap resources.
if ! grep -q "module.bootstrap.helm_release.this" "$plan_log"; then
  echo "FAIL: plan did not include the helm_release resource" >&2
  exit 1
fi
if ! grep -q "module.bootstrap.kubernetes_namespace_v1.this" "$plan_log"; then
  echo "FAIL: plan did not include the kubernetes_namespace_v1 resource" >&2
  exit 1
fi

echo "[offline-plan] OK: plan succeeded against unreachable cluster"
