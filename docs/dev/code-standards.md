# Code standards

Guidelines for writing readable, maintainable code in this project. These apply
primarily to `scripts/bootstrap.sh` (which runs inside a minimal distroless
container with busybox sh).

## Script structure

Organize scripts into clearly labeled sections using divider comments:

```sh
# ---------------------------------------------------------------------------
# Section name
# ---------------------------------------------------------------------------
```

Group related functions together under a section. Keep all function definitions
above the main flow so the reader can scan the top-level logic without jumping
past implementation details.

The main flow at the bottom of the script should read like a numbered recipe:

```sh
# 1. Do the first thing
...

# 2. Do the second thing
...
```

## Configuration variables

Break configuration variables into logically connected sub-blocks with a
comment explaining what each block is for and where the values come from:

```sh
# Shared timeout for Flux Operator install, CRD readiness, and FluxInstance wait.
bootstrap_timeout="${TIMEOUT:-5m}"

# FluxInstance manifest and prerequisite manifests directory (mounted from ConfigMap).
flux_instance_file="${FLUX_INSTANCE_FILE:?FLUX_INSTANCE_FILE is required}"
prerequisites_dir="${PREREQUISITES_DIR:-/bootstrap}"
```

Avoid generic variable names like `timeout`, `file`, or `name` that don't tell
the reader what they relate to. Prefer names that include their scope or
purpose, e.g. `bootstrap_timeout`, `managed_secrets_file`,
`bootstrap_config_map`.

## Function naming

Function names should be specific enough that a reader can understand the scope
without reading the body. If a function operates on a specific resource, include
that in the name:

- `flux_instance_metadata` instead of `extract_metadata_value`
- `prerequisite_details` instead of `manifest_details`
- `yq_field` / `yq_metadata_field` for generic YAML helpers (the `yq_` prefix
  signals these are thin wrappers)

## Function documentation

Use the Go convention: `# function_name does ...`. Document inputs and outputs:

- Positional arguments (`$1`, `$2`, etc.)
- Global variables the function reads from
- What the function prints to stdout (if anything)
- What files the function writes (if any)
- Non-zero return codes and their meaning

```sh
# reconcile_managed_resource applies a single resource using server-side apply.
# It dry-runs first to detect the state (missing, drifted, or in-sync) and only
# performs the actual apply when the resource needs to be created or corrected.
# $1: manifest file path, $2: space-separated list of allowed resource kinds.
reconcile_managed_resource() {
```

Skip comments on trivial functions where the name and signature say it all
(e.g. `log`, `fail`). Only comment functions where the *why*, *how*, or
*input/output contract* adds value beyond the function name.

## Inline comments

Long functions should have a short comment per logical block explaining what
the block does. Focus on blocks where:

- The syntax is cryptic for people used to high-level languages
- The logic requires domain knowledge to understand
- The block's purpose isn't obvious from the surrounding code

### Shell syntax to always explain

These shell constructs are not intuitive and should have a comment when used:

```sh
# Truncate the output file (": >" is the shell idiom for this).
: > "${output_file}"

# ${var%%=*} strips everything from the first "=" onwards, leaving just
# the manager name (e.g. "kubectl=Update" becomes "kubectl").
manager="${manager_op%%=*}"

# "IFS=" prevents whitespace trimming, "-r" prevents backslash interpretation,
# and the "|| [ -n ]" handles files that don't end with a newline.
while IFS= read -r entry || [ -n "${entry}" ]; do

# grep -Fx matches the full line literally (F=fixed string, x=whole line).
if grep -Fx "${previous_entry}" "${current_entries_file}" >/dev/null 2>&1; then

# "base64 -w 0" outputs on a single line (no wrapping).
encoded_payload="$(printf '%s' "${patched_payload}" | gzip | base64 -w 0)"
```

### Kubernetes resource types in function arguments

When passing Flux resource types to functions that call `kubectl get`, use
fully-qualified names (`deployment.apps`, `fluxinstances.fluxcd.controlplane.io`)
to avoid ambiguity when multiple API groups define resources with the same short
name:

```sh
# Bad — ambiguous, could conflict with another API group
has_flux_ownership_label "fluxinstance" "${name}" "${ns}"

# Good — unambiguous fully-qualified resource type
has_flux_ownership_label "fluxinstances.fluxcd.controlplane.io" "${name}" "${ns}"
```

### Multi-step pipelines

When a pipeline decodes, transforms, and re-encodes data, explain the format at
each stage:

```sh
# The release payload is stored as: JSON -> gzip -> base64. We reverse
# that to get the JSON, sed-replace the status field, then re-encode.
```
