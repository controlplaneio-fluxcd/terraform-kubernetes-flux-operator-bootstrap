#!/usr/bin/env bash
# Wrapper that runs all e2e batches sequentially.
# In CI, batches run in parallel as separate jobs.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

bash "${script_dir}/e2e-batch-1.sh"
bash "${script_dir}/e2e-batch-2.sh"
bash "${script_dir}/e2e-batch-3.sh"
bash "${script_dir}/e2e-migration.sh"
