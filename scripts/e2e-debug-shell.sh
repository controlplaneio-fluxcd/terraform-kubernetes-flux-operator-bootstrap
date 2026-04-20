#!/usr/bin/env bash
# Shell smoke test for the debug_on_failure terraform_data resource. Validates that the
# bash interpreter on the host (POSIX bash on Linux/macOS, Git Bash on Windows)
# can run the local-exec template that the module ships
# (scripts/debug-relay.sh.tpl) end to end. It does not need Docker, kind, or a
# real cluster — a fake `kubectl` on PATH simulates a failed Job and serves
# canned logs that match what bootstrap.sh would have written.
#
# In CI this is run on windows-latest to cover Windows specifically. The full
# Linux end-to-end is already covered by e2e-batch-2.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
test_dir="$repo_root/test/debug-shell"

fake_bin_dir="$(mktemp -d)"
apply_log="$(mktemp)"

cleanup() {
  rm -rf "$fake_bin_dir" "$apply_log"
  rm -rf "$test_dir/.terraform" "$test_dir/.terraform.lock.hcl" "$test_dir/terraform.tfstate" "$test_dir/terraform.tfstate.backup"
}
trap cleanup EXIT

# Fake kubectl: handles the three kubectl invocations the relay script makes
#   - `get job flux-operator-bootstrap`            → exit 0 (job exists)
#   - `get job flux-operator-bootstrap -o go-template=...` → emit "Failed=True"
#   - `logs job/flux-operator-bootstrap`           → emit canned bootstrap logs
cat > "$fake_bin_dir/kubectl" <<'KUBECTL_EOF'
#!/usr/bin/env bash
case "$*" in
  *"get job flux-operator-bootstrap"*)
    if echo "$*" | grep -q go-template; then
      printf '%s' 'Failed=True '
    fi
    exit 0
    ;;
  *"logs job/flux-operator-bootstrap"*)
    cat <<'LOGS'
Target: flux-system/flux
Bootstrap namespace: test-namespace
Substitute runtime info variables
Prerequisites
No prerequisites
ERROR: Fake fault injection from smoke test

==========================================================================
DEBUG OUTPUT
==========================================================================
=== flux-operator ===
NAME            READY   UP-TO-DATE   AVAILABLE   AGE
flux-operator   1/1     1            1           42s
=== source-controller ===
=== kustomize-controller ===
==========================================================================
LOGS
    exit 0
    ;;
  *)
    echo "fake-kubectl: unhandled args: $*" >&2
    exit 0
    ;;
esac
KUBECTL_EOF
chmod +x "$fake_bin_dir/kubectl"

export PATH="$fake_bin_dir:$PATH"

echo "[smoke] PATH=${PATH}"
echo "[smoke] bash=$(command -v bash)"
echo "[smoke] terraform=$(command -v terraform)"
echo "[smoke] kubectl (must be the fake one)=$(command -v kubectl)"

cd "$test_dir"
terraform init -backend=false -no-color

if ! terraform apply -auto-approve -no-color > "$apply_log" 2>&1; then
  cat "$apply_log"
  echo "FAIL: terraform apply returned non-zero" >&2
  exit 1
fi
cat "$apply_log"

# Verify the relay header from the template made it out.
if ! grep -q "flux-operator-bootstrap job logs" "$apply_log"; then
  echo "FAIL: relay header missing from local-exec output" >&2
  exit 1
fi
# Verify the canned bootstrap.sh DEBUG OUTPUT block came through.
if ! grep -q "DEBUG OUTPUT" "$apply_log"; then
  echo "FAIL: DEBUG OUTPUT marker missing" >&2
  exit 1
fi
if ! grep -q "Fake fault injection from smoke test" "$apply_log"; then
  echo "FAIL: canned fault injection message missing" >&2
  exit 1
fi
if ! grep -q "=== flux-operator ===" "$apply_log"; then
  echo "FAIL: controller dump marker missing" >&2
  exit 1
fi

echo "[smoke] OK: debug shell smoke test passed"
