#!/busybox/sh
set -eu
export PATH="/busybox:$PATH"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# Shared timeout for Flux Operator install, CRD readiness, and FluxInstance wait.
bootstrap_timeout="${TIMEOUT:-5m}"

# FluxInstance manifest and prerequisite manifests directory (mounted from ConfigMap).
# bootstrap_mount_dir preserves the original mount path before prerequisites_dir
# may be redirected to a scratch subdirectory during envsubst (step 1).
flux_instance_file="${FLUX_INSTANCE_FILE:?FLUX_INSTANCE_FILE is required}"
bootstrap_mount_dir="${PREREQUISITES_DIR:-/bootstrap}"
prerequisites_dir="${bootstrap_mount_dir}"

# Managed secrets YAML file (mounted from Secret, may be empty).
managed_secrets_file="${SECRETS_FILE:-}"

# Runtime info files used to build the flux-runtime-info ConfigMap and
# substitute variables into the FluxInstance manifest via flux envsubst.
runtime_info_file="${RUNTIME_INFO_FILE:-}"
runtime_info_labels_file="${RUNTIME_INFO_LABELS_FILE:-}"
runtime_info_annotations_file="${RUNTIME_INFO_ANNOTATIONS_FILE:-}"
runtime_info_config_map_name="${RUNTIME_INFO_CONFIG_MAP_NAME:-flux-runtime-info}"

# Prerequisite Helm charts JSON manifest (list of {name, repository, version, namespace}).
prerequisite_charts_file="${PREREQUISITE_CHARTS_FILE:-}"

# Flux Operator Helm chart settings.
operator_chart_repository="${OPERATOR_CHART_REPOSITORY:-ghcr.io/controlplaneio-fluxcd/charts/flux-operator}"
operator_chart_version="${OPERATOR_CHART_VERSION:-}"
operator_values_file="${OPERATOR_VALUES_FILE:-}"

# Bootstrap transport resources, cleaned up after the job completes.
bootstrap_namespace="${BOOTSTRAP_NAMESPACE:?BOOTSTRAP_NAMESPACE is required}"
bootstrap_service_account="${SERVICE_ACCOUNT_NAME:?SERVICE_ACCOUNT_NAME is required}"
bootstrap_cluster_role_binding="${CLUSTER_ROLE_BINDING_NAME:?CLUSTER_ROLE_BINDING_NAME is required}"
bootstrap_config_map="${CONFIG_MAP_NAME:?CONFIG_MAP_NAME is required}"

# Inventory ConfigMap tracks managed resources for garbage collection.
inventory_config_map_name="inventory"

# SSA field manager identity, matching kustomize-controller conventions.
ssa_field_manager="flux-operator-bootstrap"

# Testing-only debug flags.
debug_fault_injection_message="${DEBUG_FAULT_INJECTION_MESSAGE:-}"
debug_flux_operator_image_tag="${DEBUG_FLUX_OPERATOR_IMAGE_TAG:-}"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

log() {
  printf '%s\n' "$*" >&2
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
}

# ---------------------------------------------------------------------------
# YAML helpers
# ---------------------------------------------------------------------------

# flux_instance_metadata prints a metadata field from the FluxInstance manifest
# (global flux_instance_file). $1: field name (e.g. "name", "namespace").
# Prints to stdout.
flux_instance_metadata() {
  yq ".metadata.$1 // \"\"" "${flux_instance_file}"
}

# yq_field prints a top-level field from a YAML file.
# $1: file path, $2: field name. Prints to stdout.
yq_field() {
  yq ".$2 // \"\"" "$1"
}

# yq_metadata_field prints a metadata field from a YAML file.
# $1: file path, $2: field name. Prints to stdout.
yq_metadata_field() {
  yq ".metadata.$2 // \"\"" "$1"
}

# split_yaml_manifests splits a YAML file that contains multiple manifests
# separated by "---" into one file per manifest. Prerequisites and managed
# secrets need per-manifest processing (create-if-missing, SSA per resource)
# which requires individual files.
# $1: input file, $2: output directory, $3: filename prefix.
# Writes files as <output_dir>/<prefix>-000.yaml, <prefix>-001.yaml, etc.
split_yaml_manifests() {
  input_file="$1"
  output_dir="$2"
  prefix="$3"

  mkdir -p "${output_dir}"

  total=$(yq ea '[.] | length' "${input_file}")
  i=0
  while [ "$i" -lt "$total" ]; do
    out=$(printf '%s/%s-%03d.yaml' "${output_dir}" "${prefix}" "$i")
    yq ea "select(documentIndex == $i)" "${input_file}" > "${out}"
    i=$((i + 1))
  done
}

# count_yaml_manifests prints the number of manifests in a YAML file.
# $1: file path. Prints count to stdout.
count_yaml_manifests() {
  yq ea '[.] | length' "$1"
}

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

# validate_flux_instance_file checks that the FluxInstance manifest (read from
# the global flux_instance_file) contains a single manifest with kind FluxInstance.
# Returns non-zero on failure.
validate_flux_instance_file() {
  manifest_count="$(count_yaml_manifests "${flux_instance_file}")"
  manifest_kind="$(yq_field "${flux_instance_file}" kind)"

  if [ "${manifest_count}" != "1" ]; then
    fail "FluxInstance file ${flux_instance_file} must contain exactly one manifest"
    return 1
  fi

  if [ "${manifest_kind}" != "FluxInstance" ]; then
    fail "FluxInstance manifest ${flux_instance_file} must have kind FluxInstance, got ${manifest_kind:-<unknown>}"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Flux ownership detection
# ---------------------------------------------------------------------------

# has_flux_ownership_label checks whether a resource has been adopted by
# kustomize-controller or helm-controller by looking for their ownership labels.
# Resources not yet adopted can be safely re-applied by the bootstrap script.
# $1: resource kind, $2: resource name, $3: namespace. Returns 0 if adopted.
has_flux_ownership_label() {
  resource_kind="$1"
  resource_name="$2"
  resource_namespace="$3"
  # Extract label keys as a space-separated string.
  label_keys="$(kubectl get "${resource_kind}" "${resource_name}" -n "${resource_namespace}" \
    -o go-template='{{range $k, $v := .metadata.labels}}{{$k}} {{end}}' 2>/dev/null || true)"
  case "${label_keys}" in
    *kustomize.toolkit.fluxcd.io/name*) return 0 ;;
    *helm.toolkit.fluxcd.io/name*) return 0 ;;
  esac
  return 1
}

# ---------------------------------------------------------------------------
# Prerequisites (create-if-missing)
# ---------------------------------------------------------------------------

# prerequisite_details uses kubectl dry-run to resolve the final kind/name/namespace
# of a manifest, handling defaulting and multi-resource types that yq alone
# can't resolve. $1: manifest file path. Prints "kind|name|namespace" to stdout.
prerequisite_details() {
  manifest_file="$1"
  kubectl create --dry-run=client -f "${manifest_file}" -o jsonpath='{.kind}|{.metadata.name}|{.metadata.namespace}'
}

# format_prerequisite_details formats the pipe-delimited output of prerequisite_details
# into a human-readable label. $1: "kind|name|namespace" string. Prints to stdout.
format_prerequisite_details() {
  manifest_info="$1"
  manifest_kind="$(printf '%s' "${manifest_info}" | cut -d'|' -f1)"
  manifest_name="$(printf '%s' "${manifest_info}" | cut -d'|' -f2)"
  manifest_namespace="$(printf '%s' "${manifest_info}" | cut -d'|' -f3)"

  if [ -n "${manifest_namespace}" ]; then
    printf '%s %s/%s' "${manifest_kind}" "${manifest_namespace}" "${manifest_name}"
  else
    printf '%s %s' "${manifest_kind}" "${manifest_name}"
  fi
}

# apply_prerequisite_manifest applies a single manifest if it doesn't exist in
# the cluster, or re-applies it if it exists but hasn't been adopted by Flux yet
# (no kustomize-controller ownership label). Once Flux adopts the resource, the
# bootstrap script stops touching it. $1: manifest file path.
apply_prerequisite_manifest() {
  manifest_file="$1"
  manifest_info="$(prerequisite_details "${manifest_file}")"
  manifest_label="$(format_prerequisite_details "${manifest_info}")"

  if kubectl get -f "${manifest_file}" >/dev/null 2>&1; then
    # Parse kind|name|namespace from prerequisite_details output.
    p_kind="$(printf '%s' "${manifest_info}" | cut -d'|' -f1)"
    p_name="$(printf '%s' "${manifest_info}" | cut -d'|' -f2)"
    p_ns="$(printf '%s' "${manifest_info}" | cut -d'|' -f3)"
    if has_flux_ownership_label "${p_kind}" "${p_name}" "${p_ns}"; then
      log "- skip ${manifest_label} (adopted by Flux)"
      return 0
    fi
    log "~ reapply ${manifest_label} (not yet adopted by Flux)"
    kubectl apply -f "${manifest_file}" >/dev/null
    return 0
  fi

  log "+ apply ${manifest_label}"
  kubectl apply -f "${manifest_file}" >/dev/null
}

# apply_prerequisites iterates over prerequisite-*.yaml files, splits each into
# individual manifests, and applies them with create-if-missing semantics.
# $1: scratch directory for temporary split files.
apply_prerequisites() {
  scratch_dir="$1"
  found_prerequisite="false"

  for prerequisite_file in "${prerequisites_dir}"/prerequisite-*.yaml; do
    if [ ! -f "${prerequisite_file}" ]; then
      continue
    fi

    found_prerequisite="true"
    split_dir="${scratch_dir}/$(basename "${prerequisite_file}" .yaml)"
    split_yaml_manifests "${prerequisite_file}" "${split_dir}" "doc"

    for manifest_file in "${split_dir}"/doc-*.yaml; do
      if [ ! -f "${manifest_file}" ]; then
        continue
      fi

      apply_prerequisite_manifest "${manifest_file}"
    done
  done

  if [ "${found_prerequisite}" = "false" ]; then
    log "No prerequisites"
  fi
}

# ---------------------------------------------------------------------------
# Managed resources (server-side apply with inventory and garbage collection)
# ---------------------------------------------------------------------------

# Field managers to strip before SSA, matching kustomize-controller defaults.
disallowed_field_managers="kubectl before-first-apply"

# strip_disallowed_field_managers removes field managers (e.g. "kubectl" from
# manual edits) that would conflict with SSA ownership. Without this, SSA would
# fail or silently skip fields owned by disallowed managers. Indices are
# collected in reverse order so removals don't shift later indices.
# $1: resource kind, $2: resource name, $3: resource namespace.
strip_disallowed_field_managers() {
  resource_kind="$1"
  resource_name="$2"
  resource_namespace="$3"

  if ! kubectl get "${resource_kind}" "${resource_name}" -n "${resource_namespace}" >/dev/null 2>&1; then
    return 0
  fi

  # Fetch all field managers as a space-separated list of "manager=operation" pairs
  # using a Go template. Example output: "flux-operator-bootstrap=Apply kubectl=Update"
  managed_fields="$(kubectl get "${resource_kind}" "${resource_name}" -n "${resource_namespace}" \
    -o go-template='{{range $i, $mf := .metadata.managedFields}}{{if $i}} {{end}}{{$mf.manager}}={{$mf.operation}}{{end}}' 2>/dev/null || true)"

  if [ -z "${managed_fields}" ]; then
    return 0
  fi

  # Walk the list and collect indices of disallowed managers. Indices are
  # prepended (not appended) so they end up in reverse order — this is
  # important because removing index N shifts all later indices down by one.
  indices_to_remove=""
  idx=0
  for manager_op in ${managed_fields}; do
    # ${var%%=*} strips everything from the first "=" onwards, leaving just
    # the manager name (e.g. "kubectl=Update" becomes "kubectl").
    manager="${manager_op%%=*}"
    for disallowed in ${disallowed_field_managers}; do
      if [ "${manager}" = "${disallowed}" ]; then
        indices_to_remove="${idx} ${indices_to_remove}"
        break
      fi
    done
    idx=$((idx + 1))
  done

  if [ -z "${indices_to_remove}" ]; then
    return 0
  fi

  # Build a JSON Patch array of "remove" operations for each disallowed index.
  patch="["
  first="true"
  for i in ${indices_to_remove}; do
    if [ "${first}" = "true" ]; then
      first="false"
    else
      patch="${patch},"
    fi
    patch="${patch}{\"op\":\"remove\",\"path\":\"/metadata/managedFields/${i}\"}"
  done
  patch="${patch}]"

  log "  strip disallowed field managers from ${resource_kind} ${resource_namespace}/${resource_name}"
  kubectl patch "${resource_kind}" "${resource_name}" -n "${resource_namespace}" \
    --type=json -p "${patch}" >/dev/null
}

# reconcile_managed_resource applies a single resource using server-side apply.
# It dry-runs first to detect the state (missing, drifted, or in-sync) and only
# performs the actual apply when the resource needs to be created or corrected.
# $1: manifest file path, $2: space-separated list of allowed resource kinds.
reconcile_managed_resource() {
  manifest_file="$1"
  allowed_kinds="$2"
  manifest_kind="$(yq_field "${manifest_file}" kind)"
  manifest_name="$(yq_metadata_field "${manifest_file}" name)"
  manifest_namespace="$(yq_metadata_field "${manifest_file}" namespace)"

  # Validate the resource kind is in the allow list.
  found_allowed="false"
  for kind in ${allowed_kinds}; do
    if [ "${manifest_kind}" = "${kind}" ]; then
      found_allowed="true"
      break
    fi
  done
  if [ "${found_allowed}" = "false" ]; then
    fail "managed resource must be one of: ${allowed_kinds}, got ${manifest_kind:-<unknown>}"
    return 1
  fi

  if [ -z "${manifest_name}" ]; then
    fail "managed resource has no metadata.name"
    return 1
  fi

  if [ -n "${manifest_namespace}" ] && [ "${manifest_namespace}" != "${namespace}" ]; then
    fail "${manifest_kind} ${manifest_name} must omit metadata.namespace or set it to ${namespace}"
    return 1
  fi

  strip_disallowed_field_managers "${manifest_kind}" "${manifest_name}" "${namespace}"

  # Server-side dry-run to detect the current state without mutating the cluster.
  # The output contains "unchanged", "created", "configured", or "serverside-applied".
  if ! dry_run_output="$(kubectl apply --server-side --dry-run=server --force-conflicts --field-manager="${ssa_field_manager}" -f "${manifest_file}" -n "${namespace}" 2>&1)"; then
    printf '%s\n' "${dry_run_output}" >&2
    fail "Failed to dry-run apply ${manifest_kind} ${namespace}/${manifest_name}"
    return 1
  fi

  case "${dry_run_output}" in
    *"unchanged (server dry run)"*)
      resource_state="in-sync"
      ;;
    *"created (server dry run)"*)
      resource_state="missing"
      ;;
    *"configured (server dry run)"*|*"serverside-applied (server dry run)"*)
      resource_state="drifted"
      ;;
    *)
      fail "Unexpected dry-run result for ${manifest_kind} ${namespace}/${manifest_name}: ${dry_run_output}"
      return 1
      ;;
  esac

  if [ "${resource_state}" = "in-sync" ]; then
    log "= ${manifest_kind} ${namespace}/${manifest_name}"
    return 0
  fi

  log "~ ${manifest_kind} ${namespace}/${manifest_name} (${resource_state})"
  kubectl apply --server-side --force-conflicts --field-manager="${ssa_field_manager}" -f "${manifest_file}" -n "${namespace}" >/dev/null
}

# ---------------------------------------------------------------------------
# Inventory tracking
# ---------------------------------------------------------------------------

# load_inventory_entries reads the inventory ConfigMap and writes one
# "Kind/namespace/name" entry per line to the output file. If the ConfigMap
# doesn't exist yet, the output file is left empty.
# $1: output file path.
load_inventory_entries() {
  output_file="$1"

  # Truncate the output file (": >" is the shell idiom for this).
  : > "${output_file}"

  if ! kubectl get configmap "${inventory_config_map_name}" -n "${bootstrap_namespace}" >/dev/null 2>&1; then
    return 0
  fi

  entries="$(kubectl get configmap "${inventory_config_map_name}" -n "${bootstrap_namespace}" -o go-template='{{index .data "entries"}}')"
  if [ -z "${entries}" ]; then
    return 0
  fi

  # The ConfigMap stores entries as a YAML list ("- Kind/ns/name" per line).
  # Strip the "- " prefix to get plain "Kind/ns/name" lines.
  printf '%s\n' "${entries}" | grep '^- ' | sed 's/^- //' > "${output_file}"
}

# update_inventory writes the current entries back to the inventory ConfigMap.
# $1: file with one "Kind/namespace/name" entry per line.
update_inventory() {
  entries_file="$1"

  # Read entries line by line and format them as a YAML list.
  # "IFS=" prevents whitespace trimming, "-r" prevents backslash interpretation,
  # and the "|| [ -n ]" handles files that don't end with a newline.
  yaml_list=""
  while IFS= read -r entry || [ -n "${entry}" ]; do
    if [ -z "${entry}" ]; then
      continue
    fi
    yaml_list="${yaml_list}
    - ${entry}"
  done < "${entries_file}"

  if [ -z "${yaml_list}" ]; then
    yaml_list="
    []"
  fi

  # Apply the ConfigMap from stdin using a heredoc.
  kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${inventory_config_map_name}
  namespace: ${bootstrap_namespace}
data:
  entries: |${yaml_list}
EOF
}

# garbage_collect_removed_entries deletes resources that were in the previous
# inventory but are absent from the current one, i.e. removed from the
# Terraform inputs between runs.
# $1: previous entries file, $2: current entries file (same line format).
garbage_collect_removed_entries() {
  previous_entries_file="$1"
  current_entries_file="$2"

  while IFS= read -r previous_entry || [ -n "${previous_entry}" ]; do
    if [ -z "${previous_entry}" ]; then
      continue
    fi

    # grep -Fx matches the full line literally (F=fixed string, x=whole line).
    # If the entry still exists in the current file, skip it.
    if grep -Fx "${previous_entry}" "${current_entries_file}" >/dev/null 2>&1; then
      continue
    fi

    entry_kind="$(printf '%s' "${previous_entry}" | cut -d'/' -f1)"
    entry_namespace="$(printf '%s' "${previous_entry}" | cut -d'/' -f2)"
    entry_name="$(printf '%s' "${previous_entry}" | cut -d'/' -f3)"

    log "- delete ${entry_kind} ${entry_namespace}/${entry_name}"
    kubectl delete "${entry_kind}" "${entry_name}" -n "${entry_namespace}" --ignore-not-found=true >/dev/null
  done < "${previous_entries_file}"
}

# ---------------------------------------------------------------------------
# Managed resource reconciliation (secrets + runtime info)
# ---------------------------------------------------------------------------

# reconcile_managed_resources orchestrates SSA for all managed resources:
# splits and applies secrets, builds and applies the runtime-info ConfigMap,
# then garbage-collects any resources removed since the previous run.
# $1: scratch directory for temporary files.
reconcile_managed_resources() {
  scratch_dir="$1"
  previous_entries_file="${scratch_dir}/previous-inventory-entries.txt"
  current_entries_file="${scratch_dir}/current-inventory-entries.txt"

  load_inventory_entries "${previous_entries_file}"
  : > "${current_entries_file}"

  # Managed secrets
  if [ -n "${managed_secrets_file}" ] && [ -f "${managed_secrets_file}" ]; then
    split_dir="${scratch_dir}/managed-secrets"
    split_yaml_manifests "${managed_secrets_file}" "${split_dir}" "secret"

    found_secret="false"
    for manifest_file in "${split_dir}"/secret-*.yaml; do
      if [ ! -f "${manifest_file}" ]; then
        continue
      fi

      found_secret="true"
      current_name="$(yq_metadata_field "${manifest_file}" name)"
      if [ -z "${current_name}" ]; then
        fail "secrets_yaml contains a Secret without metadata.name"
        return 1
      fi
      reconcile_managed_resource "${manifest_file}" "Secret"
      printf 'Secret/%s/%s\n' "${namespace}" "${current_name}" >> "${current_entries_file}"
    done

    if [ "${found_secret}" = "false" ]; then
      log "No managed secrets"
    fi
  else
    log "No managed secrets"
  fi

  # Runtime info ConfigMap
  if [ -n "${runtime_info_file}" ] && [ -f "${runtime_info_file}" ]; then
    runtime_info_manifest="${scratch_dir}/runtime-info-configmap.yaml"

    # Build the ConfigMap YAML with data, labels, and annotations.
    printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: %s\n  namespace: %s\n' \
      "${runtime_info_config_map_name}" "${namespace}" > "${runtime_info_manifest}"

    # Append labels if any.
    if [ -n "${runtime_info_labels_file}" ] && [ -f "${runtime_info_labels_file}" ] && [ -s "${runtime_info_labels_file}" ]; then
      printf '  labels:\n' >> "${runtime_info_manifest}"
      while IFS="=" read -r key value; do
        [ -z "${key}" ] && continue
        printf '    %s: "%s"\n' "${key}" "${value}" >> "${runtime_info_manifest}"
      done < "${runtime_info_labels_file}"
    fi

    # Append annotations if any.
    if [ -n "${runtime_info_annotations_file}" ] && [ -f "${runtime_info_annotations_file}" ] && [ -s "${runtime_info_annotations_file}" ]; then
      printf '  annotations:\n' >> "${runtime_info_manifest}"
      while IFS="=" read -r key value; do
        [ -z "${key}" ] && continue
        printf '    %s: "%s"\n' "${key}" "${value}" >> "${runtime_info_manifest}"
      done < "${runtime_info_annotations_file}"
    fi

    # Append data.
    printf 'data:\n' >> "${runtime_info_manifest}"
    while IFS="=" read -r key value; do
      [ -z "${key}" ] && continue
      printf '  %s: "%s"\n' "${key}" "${value}" >> "${runtime_info_manifest}"
    done < "${runtime_info_file}"

    reconcile_managed_resource "${runtime_info_manifest}" "ConfigMap"
    printf 'ConfigMap/%s/%s\n' "${namespace}" "${runtime_info_config_map_name}" >> "${current_entries_file}"
  else
    log "No runtime info"
  fi

  sort -u -o "${current_entries_file}" "${current_entries_file}"
  garbage_collect_removed_entries "${previous_entries_file}" "${current_entries_file}"
  update_inventory "${current_entries_file}"
}

# ---------------------------------------------------------------------------
# Helm chart install (shared by prerequisite charts and Flux Operator)
# ---------------------------------------------------------------------------

# helm_release_status prints the status of a Helm release (e.g. "deployed",
# "failed", "pending-install") or empty string if the release doesn't exist.
# $1: release name, $2: namespace. Prints to stdout.
helm_release_status() {
  helm status "$1" -n "$2" 2>/dev/null | awk '/^STATUS:/{print $2; exit}'
}

# install_or_upgrade_chart installs or upgrades a Helm chart from an OCI
# repository. Uses --install so it works for both fresh installs and upgrades.
# $1: release name, $2: OCI repository, $3: namespace, $4: version (optional),
# $5: values file path (optional), $6: create namespace ("true"/"false", default "true").
install_or_upgrade_chart() {
  chart_release_name="$1"
  chart_repository="$2"
  chart_namespace="$3"
  chart_version="${4:-}"
  chart_values_file="${5:-}"
  chart_create_ns="${6:-true}"
  # Pin to a specific chart version if provided.
  version_args=""
  if [ -n "${chart_version}" ]; then
    version_args="--version=${chart_version}"
  fi
  # Pass a custom values file if provided.
  values_args=""
  if [ -n "${chart_values_file}" ]; then
    values_args="-f ${chart_values_file}"
  fi
  # Create the target namespace if it doesn't exist.
  create_ns_args=""
  if [ "${chart_create_ns}" = "true" ]; then
    create_ns_args="--create-namespace"
  fi
  helm upgrade --install "${chart_release_name}" "oci://${chart_repository}" \
    --namespace="${chart_namespace}" \
    ${create_ns_args} \
    --wait=watcher \
    --timeout="${bootstrap_timeout}" \
    ${version_args} \
    ${values_args}
}

# install_or_upgrade_flux_operator installs or upgrades the flux-operator Helm
# chart from the OCI repository. Uses --install so it works for both fresh
# installs and upgrades of existing releases. Uses operator_values_file (via -f)
# for custom chart values and debug_flux_operator_image_tag (via --set) for
# testing overrides.
install_or_upgrade_flux_operator() {
  values_args=""
  set_args=""
  install_timeout="${bootstrap_timeout}"
  if [ -n "${operator_values_file}" ]; then
    values_args="-f ${operator_values_file}"
  fi
  if [ -n "${debug_flux_operator_image_tag}" ]; then
    set_args="--set image.tag=${debug_flux_operator_image_tag} --set replicas=2"
    install_timeout="15s"
  fi
  version_args=""
  if [ -n "${operator_chart_version}" ]; then
    version_args="--version=${operator_chart_version}"
  fi
  helm upgrade --install flux-operator "oci://${operator_chart_repository}" \
    --namespace="${namespace}" \
    --wait=watcher \
    --timeout="${install_timeout}" \
    ${version_args} \
    ${values_args} \
    ${set_args}
}

# unlock_helm_release recovers a Helm release stuck in a pending state (e.g.
# after a timeout or crash). Helm stores release metadata in Secrets; this
# function decodes the latest one, patches its status from "pending-*" to
# "failed", and re-encodes it so a subsequent helm install/delete can proceed.
# $1: release name, $2: release namespace.
unlock_helm_release() {
  release_name="$1"
  release_namespace="$2"

  release_status="$(helm_release_status "${release_name}" "${release_namespace}")"

  case "${release_status}" in
    pending-install|pending-upgrade|pending-rollback)
      log "Unlocking Helm release ${release_name} from stale '${release_status}' state"
      # Find the latest release secret and patch its status to 'failed'.
      # Helm stores releases as secrets with type helm.sh/release.v1, with the
      # release data base64-encoded then gzip-compressed in the 'release' key.
      latest_secret="$(kubectl get secrets -n "${release_namespace}" \
        -l "name=${release_name},owner=helm" \
        --sort-by=.metadata.creationTimestamp \
        -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null || true)"
      if [ -z "${latest_secret}" ]; then
        log "No Helm release secret found, deleting release history"
        helm delete "${release_name}" -n "${release_namespace}" --no-hooks 2>/dev/null || true
        return 0
      fi
      # The release payload is stored as: JSON -> gzip -> base64. We reverse
      # that to get the JSON, sed-replace the status field, then re-encode.
      release_payload="$(kubectl get secret "${latest_secret}" -n "${release_namespace}" \
        -o go-template='{{index .data "release"}}' | base64 -d | gzip -d)"
      patched_payload="$(printf '%s' "${release_payload}" \
        | sed "s/\"status\":\"${release_status}\"/\"status\":\"failed\"/")"
      # "base64 -w 0" outputs on a single line (no wrapping).
      encoded_payload="$(printf '%s' "${patched_payload}" | gzip | base64 -w 0)"
      kubectl patch secret "${latest_secret}" -n "${release_namespace}" \
        --type='merge' -p "{\"data\":{\"release\":\"${encoded_payload}\"}}" >/dev/null
      log "Helm release ${release_name} unlocked"
      ;;
    "")
      # No release found, nothing to unlock.
      ;;
    *)
      # Release exists in a non-pending state (e.g. deployed, failed), nothing to do.
      ;;
  esac
}

# ---------------------------------------------------------------------------
# FluxInstance CRD
# ---------------------------------------------------------------------------

# wait_for_flux_instance_crd polls for the CRD to appear (the operator creates
# it asynchronously after install) then waits for it to become Established.
wait_for_flux_instance_crd() {
  end_time=$(( $(date +%s) + 300 ))
  while [ "$(date +%s)" -lt "${end_time}" ]; do
    if kubectl get crd fluxinstances.fluxcd.controlplane.io >/dev/null 2>&1; then
      log "CRD found; waiting for Established"
      kubectl wait --for=condition=Established crd/fluxinstances.fluxcd.controlplane.io --timeout="${bootstrap_timeout}" >/dev/null
      return 0
    fi
    sleep 2
  done

  fail "Timed out waiting for FluxInstance CRD to be created"
  return 1
}

# ---------------------------------------------------------------------------
# Cleanup (runs on exit via trap)
# ---------------------------------------------------------------------------

cleanup() {
  log "Cleanup bootstrap transport resources"
  if [ -n "${scratch_dir:-}" ] && [ -d "${scratch_dir}" ]; then
    rm -rf "${scratch_dir}"
  fi
  if ! kubectl delete configmap "${bootstrap_config_map}" -n "${bootstrap_namespace}" --ignore-not-found=true >/dev/null; then
    log "Failed to delete ConfigMap ${bootstrap_namespace}/${bootstrap_config_map}"
  fi
  # The secrets Secret is owned by Terraform and not cleaned up here.
  if ! kubectl delete serviceaccount "${bootstrap_service_account}" -n "${bootstrap_namespace}" --ignore-not-found=true >/dev/null; then
    log "Failed to delete ServiceAccount ${bootstrap_namespace}/${bootstrap_service_account}"
  fi
  if ! kubectl delete clusterrolebinding "${bootstrap_cluster_role_binding}" --ignore-not-found=true >/dev/null; then
    log "Failed to delete ClusterRoleBinding ${bootstrap_cluster_role_binding}"
  fi
}

# ===========================================================================
# Main
# ===========================================================================

if ! validate_flux_instance_file; then
  exit 1
fi

namespace="$(flux_instance_metadata namespace)"
instance_name="$(flux_instance_metadata name)"

if [ -z "${namespace}" ] || [ -z "${instance_name}" ]; then
  fail "Failed to determine FluxInstance namespace or name from ${flux_instance_file}"
  exit 1
fi

log "Target: ${namespace}/${instance_name}"
log "Bootstrap namespace: ${bootstrap_namespace}"

trap cleanup EXIT
scratch_dir="$(mktemp -d)"

# 1. Substitute runtime info variables into input manifests
if [ -n "${runtime_info_file}" ] && [ -f "${runtime_info_file}" ]; then
  log "Substitute runtime info variables"
  # Build "key=value" pairs from the runtime info file into a single string,
  # then export them in a subshell so flux envsubst can replace ${var} references.
  # The subshell (sh -c) is needed because this script runs under "set -eu" and
  # we don't want to pollute its environment.
  export_args=""
  while IFS="=" read -r key value; do
    export_args="${export_args} ${key}=${value}"
  done < "${runtime_info_file}"

  # Substitute in FluxInstance manifest.
  sh -c "export${export_args}; flux envsubst --strict" \
    < "${flux_instance_file}" > "${scratch_dir}/flux-instance.yaml"
  flux_instance_file="${scratch_dir}/flux-instance.yaml"

  # Substitute in prerequisite manifests. The originals are mounted read-only
  # from a ConfigMap, so we write substituted copies to a scratch subdirectory
  # and redirect prerequisites_dir to it.
  substituted_prereqs_dir="${scratch_dir}/substituted-prerequisites"
  mkdir -p "${substituted_prereqs_dir}"
  found_prereqs="false"
  for prerequisite_file in "${prerequisites_dir}"/prerequisite-*.yaml; do
    if [ ! -f "${prerequisite_file}" ]; then
      continue
    fi
    found_prereqs="true"
    sh -c "export${export_args}; flux envsubst --strict" \
      < "${prerequisite_file}" > "${substituted_prereqs_dir}/$(basename "${prerequisite_file}")"
  done
  if [ "${found_prereqs}" = "true" ]; then
    prerequisites_dir="${substituted_prereqs_dir}"
  fi

  # Substitute in operator chart values file.
  if [ -n "${operator_values_file}" ] && [ -f "${operator_values_file}" ]; then
    sh -c "export${export_args}; flux envsubst --strict" \
      < "${operator_values_file}" > "${scratch_dir}/operator-values.yaml"
    operator_values_file="${scratch_dir}/operator-values.yaml"
  fi

  # Substitute in prerequisite chart values files. Values files use an
  # index-based naming convention (chart-values-0.yaml, chart-values-1.yaml, ...)
  # matching the chart's position in the JSON array.
  if [ -n "${prerequisite_charts_file}" ] && [ -f "${prerequisite_charts_file}" ]; then
    total="$(yq 'length' "${prerequisite_charts_file}")"
    i=0
    while [ "$i" -lt "$total" ]; do
      vf="${bootstrap_mount_dir}/chart-values-${i}.yaml"
      if [ -f "${vf}" ]; then
        sh -c "export${export_args}; flux envsubst --strict" \
          < "${vf}" > "${scratch_dir}/chart-values-${i}.yaml"
      fi
      i=$((i + 1))
    done
  fi
fi

# 2. Apply prerequisites (create-if-missing)
log "Prerequisites"
apply_prerequisites "${scratch_dir}"

# 3. Install prerequisite Helm charts
if [ -n "${prerequisite_charts_file}" ] && [ -f "${prerequisite_charts_file}" ]; then
  log "Prerequisite charts"
  # The JSON file contains an array of {name, repository, version, namespace}.
  # Values files are stored as prerequisite-chart-<index>-values.yaml in the
  # ConfigMap mount. "yq 'length'" returns the array length.
  total="$(yq 'length' "${prerequisite_charts_file}")"
  i=0
  while [ "$i" -lt "$total" ]; do
    # Extract chart metadata from the JSON array entry.
    chart_name="$(yq -r ".[$i].name" "${prerequisite_charts_file}")"
    chart_repo="$(yq -r ".[$i].repository" "${prerequisite_charts_file}")"
    chart_version="$(yq -r ".[$i].version // \"\"" "${prerequisite_charts_file}")"
    chart_namespace="$(yq -r ".[$i].namespace" "${prerequisite_charts_file}")"
    chart_create_namespace="$(yq -r ".[$i].createNamespace // true" "${prerequisite_charts_file}")"

    # Use the substituted values file from scratch if it exists, otherwise
    # fall back to the original from the ConfigMap mount.
    values_file=""
    if [ -f "${scratch_dir}/chart-values-${i}.yaml" ]; then
      values_file="${scratch_dir}/chart-values-${i}.yaml"
    elif [ -f "${bootstrap_mount_dir}/chart-values-${i}.yaml" ]; then
      values_file="${bootstrap_mount_dir}/chart-values-${i}.yaml"
    fi

    # Check if the user provided a resource to inspect for Flux adoption.
    # When set, we can detect whether Flux has taken over the release (like
    # we do for the Flux Operator chart). Without it, we fall back to
    # create-if-missing semantics since prerequisite charts are user-defined
    # and there is no reliable way to tell whether Flux has adopted them.
    adopt_kind="$(yq -r ".[$i].fluxAdoptionCheck.kind // \"\"" "${prerequisite_charts_file}")"
    adopt_name="$(yq -r ".[$i].fluxAdoptionCheck.name // \"\"" "${prerequisite_charts_file}")"
    adopt_ns="$(yq -r ".[$i].fluxAdoptionCheck.namespace // \"\"" "${prerequisite_charts_file}")"

    if [ -n "${adopt_kind}" ] && [ -n "${adopt_name}" ] && [ -n "${adopt_ns}" ]; then
      # Adoption check available: use the same unlock/recover/upgrade flow as
      # the Flux Operator chart, gated behind the adoption check.
      if has_flux_ownership_label "${adopt_kind}" "${adopt_name}" "${adopt_ns}"; then
        log "- skip chart ${chart_name} (adopted by Flux)"
      else
        unlock_helm_release "${chart_name}" "${chart_namespace}"
        chart_status="$(helm_release_status "${chart_name}" "${chart_namespace}")"
        case "${chart_status}" in
          "deployed")
            log "Upgrade chart ${chart_name} (not yet adopted by Flux)"
            install_or_upgrade_chart "${chart_name}" "${chart_repo}" "${chart_namespace}" "${chart_version}" "${values_file}" "${chart_create_namespace}"
            ;;
          "failed")
            log "Delete failed chart ${chart_name}"
            helm delete "${chart_name}" -n "${chart_namespace}" --no-hooks >/dev/null
            log "Install chart ${chart_name}"
            install_or_upgrade_chart "${chart_name}" "${chart_repo}" "${chart_namespace}" "${chart_version}" "${values_file}" "${chart_create_namespace}"
            ;;
          *)
            log "Install chart ${chart_name}"
            install_or_upgrade_chart "${chart_name}" "${chart_repo}" "${chart_namespace}" "${chart_version}" "${values_file}" "${chart_create_namespace}"
            ;;
        esac
      fi
    else
      # No adoption check: fall back to create-if-missing since there is no
      # reliable way to tell whether Flux has taken over the release.
      chart_status="$(helm_release_status "${chart_name}" "${chart_namespace}")"
      if [ -z "${chart_status}" ]; then
        log "Install chart ${chart_name}"
        install_or_upgrade_chart "${chart_name}" "${chart_repo}" "${chart_namespace}" "${chart_version}" "${values_file}" "${chart_create_namespace}"
      else
        log "- skip chart ${chart_name} (already exists)"
      fi
    fi
    i=$((i + 1))
  done
else
  log "No prerequisite charts"
fi

# 4. Ensure target namespace exists
if kubectl get namespace "${namespace}" >/dev/null 2>&1; then
  log "Namespace exists: ${namespace}"
else
  log "Create namespace: ${namespace}"
  kubectl create namespace "${namespace}" >/dev/null
fi

# 5. Reconcile managed resources (secrets, runtime info) with SSA
log "Managed resources"
reconcile_managed_resources "${scratch_dir}"

# 6. Install Flux Operator (or recover from failed/stuck state, or upgrade if
#    not yet adopted by helm-controller)
if has_flux_ownership_label "deployment" "flux-operator" "${namespace}"; then
  log "Flux Operator exists (adopted by Flux)"
else
  unlock_helm_release "flux-operator" "${namespace}"
  flux_operator_status="$(helm_release_status "flux-operator" "${namespace}")"
  case "${flux_operator_status}" in
    "deployed")
      log "Upgrade Flux Operator (not yet adopted by Flux)"
      install_or_upgrade_flux_operator
      ;;
    "failed")
      log "Delete failed Flux Operator release"
      helm delete flux-operator -n "${namespace}" --no-hooks >/dev/null
      log "Install Flux Operator"
      install_or_upgrade_flux_operator
      ;;
    *)
      log "Install Flux Operator"
      install_or_upgrade_flux_operator
      ;;
  esac
fi

# 7. Wait for FluxInstance CRD to be available
log "FluxInstance CRD"
wait_for_flux_instance_crd

# 8. Create FluxInstance (create-if-missing, or re-apply if not yet adopted)
instance_created="false"
if ! kubectl get fluxinstance.fluxcd.controlplane.io "${instance_name}" -n "${namespace}" >/dev/null 2>&1; then
  log "Create FluxInstance"
  kubectl apply -f "${flux_instance_file}" >/dev/null
  instance_created="true"
elif has_flux_ownership_label "fluxinstance" "${instance_name}" "${namespace}"; then
  log "FluxInstance exists (adopted by Flux)"
else
  log "Reapply FluxInstance (not yet adopted by Flux)"
  kubectl apply -f "${flux_instance_file}" >/dev/null
  instance_created="true"
fi

# 9. Wait for FluxInstance to become ready
if [ "${instance_created}" = "true" ]; then
  log "Wait for FluxInstance"
  flux-operator wait instance "${instance_name}" -n "${namespace}" --timeout="${bootstrap_timeout}"
else
  log "FluxInstance wait skipped"
fi

# 10. Debug fault injection (testing only)
if [ -n "${debug_fault_injection_message}" ]; then
  fail "Fault injection triggered: ${debug_fault_injection_message}"
  exit 1
fi

log "Done"
