#!/busybox/sh
set -eu
export PATH="/busybox:$PATH"

flux_instance_file="${FLUX_INSTANCE_FILE:?FLUX_INSTANCE_FILE is required}"
prerequisites_dir="${PREREQUISITES_DIR:-/bootstrap}"
secrets_file="${SECRETS_FILE:-}"
timeout="${TIMEOUT:-5m}"
bootstrap_namespace="${BOOTSTRAP_NAMESPACE:?BOOTSTRAP_NAMESPACE is required}"
service_account_name="${SERVICE_ACCOUNT_NAME:?SERVICE_ACCOUNT_NAME is required}"
cluster_role_binding_name="${CLUSTER_ROLE_BINDING_NAME:?CLUSTER_ROLE_BINDING_NAME is required}"
config_map_name="${CONFIG_MAP_NAME:?CONFIG_MAP_NAME is required}"
runtime_info_file="${RUNTIME_INFO_FILE:-}"
runtime_info_labels_file="${RUNTIME_INFO_LABELS_FILE:-}"
runtime_info_annotations_file="${RUNTIME_INFO_ANNOTATIONS_FILE:-}"
runtime_info_config_map_name="${RUNTIME_INFO_CONFIG_MAP_NAME:-flux-runtime-info}"
inventory_config_map_name="inventory"
operator_chart_repository="${OPERATOR_CHART_REPOSITORY:-ghcr.io/controlplaneio-fluxcd/charts/flux-operator}"
operator_chart_version="${OPERATOR_CHART_VERSION:-}"
operator_values_file="${OPERATOR_VALUES_FILE:-}"
debug_fault_injection_message="${DEBUG_FAULT_INJECTION_MESSAGE:-}"
debug_flux_operator_image_tag="${DEBUG_FLUX_OPERATOR_IMAGE_TAG:-}"
field_manager="flux-operator-bootstrap"

log() {
  printf '%s\n' "$*" >&2
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
}

extract_metadata_value() {
  yq ".metadata.$1 // \"\"" "${flux_instance_file}"
}

extract_top_level_value() {
  yq ".$2 // \"\"" "$1"
}

extract_manifest_metadata_value() {
  yq ".metadata.$2 // \"\"" "$1"
}

split_yaml_documents() {
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

count_yaml_documents() {
  yq ea '[.] | length' "$1"
}

validate_flux_instance_file() {
  document_count="$(count_yaml_documents "${flux_instance_file}")"
  manifest_kind="$(extract_top_level_value "${flux_instance_file}" kind)"

  if [ "${document_count}" != "1" ]; then
    fail "FluxInstance manifest ${flux_instance_file} must contain exactly one YAML document"
    return 1
  fi

  if [ "${manifest_kind}" != "FluxInstance" ]; then
    fail "FluxInstance manifest ${flux_instance_file} must have kind FluxInstance, got ${manifest_kind:-<unknown>}"
    return 1
  fi
}

manifest_details() {
  manifest_file="$1"
  kubectl create --dry-run=client -f "${manifest_file}" -o jsonpath='{.kind}|{.metadata.name}|{.metadata.namespace}'
}

format_manifest_details() {
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

apply_prerequisite_document() {
  manifest_file="$1"
  manifest_info="$(manifest_details "${manifest_file}")"
  manifest_label="$(format_manifest_details "${manifest_info}")"

  if kubectl get -f "${manifest_file}" >/dev/null 2>&1; then
    log "- skip ${manifest_label}"
    return 0
  fi

  log "+ apply ${manifest_label}"
  kubectl apply -f "${manifest_file}" >/dev/null
}

apply_prerequisites() {
  scratch_dir="$1"
  found_prerequisite="false"

  for prerequisite_file in "${prerequisites_dir}"/prerequisite-*.yaml; do
    if [ ! -f "${prerequisite_file}" ]; then
      continue
    fi

    found_prerequisite="true"
    split_dir="${scratch_dir}/$(basename "${prerequisite_file}" .yaml)"
    split_yaml_documents "${prerequisite_file}" "${split_dir}" "doc"

    for manifest_file in "${split_dir}"/doc-*.yaml; do
      if [ ! -f "${manifest_file}" ]; then
        continue
      fi

      apply_prerequisite_document "${manifest_file}"
    done
  done

  if [ "${found_prerequisite}" = "false" ]; then
    log "No prerequisites"
  fi
}

wait_for_flux_instance_crd() {
  end_time=$(( $(date +%s) + 300 ))
  while [ "$(date +%s)" -lt "${end_time}" ]; do
    if kubectl get crd fluxinstances.fluxcd.controlplane.io >/dev/null 2>&1; then
      log "CRD found; waiting for Established"
      kubectl wait --for=condition=Established crd/fluxinstances.fluxcd.controlplane.io --timeout="${timeout}" >/dev/null
      return 0
    fi
    sleep 2
  done

  fail "Timed out waiting for FluxInstance CRD to be created"
  return 1
}

# Field managers to strip before SSA, matching kustomize-controller defaults.
disallowed_field_managers="kubectl before-first-apply"

strip_disallowed_field_managers() {
  resource_kind="$1"
  resource_name="$2"
  resource_namespace="$3"

  if ! kubectl get "${resource_kind}" "${resource_name}" -n "${resource_namespace}" >/dev/null 2>&1; then
    return 0
  fi

  managed_fields="$(kubectl get "${resource_kind}" "${resource_name}" -n "${resource_namespace}" \
    -o go-template='{{range $i, $mf := .metadata.managedFields}}{{if $i}} {{end}}{{$mf.manager}}={{$mf.operation}}{{end}}' 2>/dev/null || true)"

  if [ -z "${managed_fields}" ]; then
    return 0
  fi

  # Collect indices to remove (in reverse order so indices stay valid).
  indices_to_remove=""
  idx=0
  for manager_op in ${managed_fields}; do
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

reconcile_managed_resource() {
  manifest_file="$1"
  allowed_kinds="$2"
  manifest_kind="$(extract_top_level_value "${manifest_file}" kind)"
  manifest_name="$(extract_manifest_metadata_value "${manifest_file}" name)"
  manifest_namespace="$(extract_manifest_metadata_value "${manifest_file}" namespace)"

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

  if ! dry_run_output="$(kubectl apply --server-side --dry-run=server --force-conflicts --field-manager="${field_manager}" -f "${manifest_file}" -n "${namespace}" 2>&1)"; then
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
  kubectl apply --server-side --force-conflicts --field-manager="${field_manager}" -f "${manifest_file}" -n "${namespace}" >/dev/null
}

load_inventory_entries() {
  output_file="$1"

  : > "${output_file}"

  if ! kubectl get configmap "${inventory_config_map_name}" -n "${bootstrap_namespace}" >/dev/null 2>&1; then
    return 0
  fi

  entries="$(kubectl get configmap "${inventory_config_map_name}" -n "${bootstrap_namespace}" -o go-template='{{index .data "entries"}}')"
  if [ -z "${entries}" ]; then
    return 0
  fi

  printf '%s\n' "${entries}" | grep '^- ' | sed 's/^- //' > "${output_file}"
}

update_inventory() {
  entries_file="$1"

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

garbage_collect_removed_entries() {
  previous_entries_file="$1"
  current_entries_file="$2"

  while IFS= read -r previous_entry || [ -n "${previous_entry}" ]; do
    if [ -z "${previous_entry}" ]; then
      continue
    fi

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

reconcile_managed_resources() {
  scratch_dir="$1"
  previous_entries_file="${scratch_dir}/previous-inventory-entries.txt"
  current_entries_file="${scratch_dir}/current-inventory-entries.txt"

  load_inventory_entries "${previous_entries_file}"
  : > "${current_entries_file}"

  # Managed secrets
  if [ -n "${secrets_file}" ] && [ -f "${secrets_file}" ]; then
    split_dir="${scratch_dir}/managed-secrets"
    split_yaml_documents "${secrets_file}" "${split_dir}" "secret"

    found_secret="false"
    for manifest_file in "${split_dir}"/secret-*.yaml; do
      if [ ! -f "${manifest_file}" ]; then
        continue
      fi

      found_secret="true"
      current_name="$(extract_manifest_metadata_value "${manifest_file}" name)"
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

cleanup() {
  log "Cleanup bootstrap transport resources"
  if [ -n "${scratch_dir:-}" ] && [ -d "${scratch_dir}" ]; then
    rm -rf "${scratch_dir}"
  fi
  if ! kubectl delete configmap "${config_map_name}" -n "${bootstrap_namespace}" --ignore-not-found=true >/dev/null; then
    log "Failed to delete ConfigMap ${bootstrap_namespace}/${config_map_name}"
  fi
  # The secrets Secret is owned by Terraform and not cleaned up here.
  if ! kubectl delete serviceaccount "${service_account_name}" -n "${bootstrap_namespace}" --ignore-not-found=true >/dev/null; then
    log "Failed to delete ServiceAccount ${bootstrap_namespace}/${service_account_name}"
  fi
  if ! kubectl delete clusterrolebinding "${cluster_role_binding_name}" --ignore-not-found=true >/dev/null; then
    log "Failed to delete ClusterRoleBinding ${cluster_role_binding_name}"
  fi
}

if ! validate_flux_instance_file; then
  exit 1
fi

namespace="$(extract_metadata_value namespace)"
instance_name="$(extract_metadata_value name)"

if [ -z "${namespace}" ] || [ -z "${instance_name}" ]; then
  fail "Failed to determine FluxInstance namespace or name from ${flux_instance_file}"
  exit 1
fi

log "Target: ${namespace}/${instance_name}"
log "Bootstrap namespace: ${bootstrap_namespace}"

trap cleanup EXIT
scratch_dir="$(mktemp -d)"

log "Prerequisites"
apply_prerequisites "${scratch_dir}"

if kubectl get namespace "${namespace}" >/dev/null 2>&1; then
  log "Namespace exists: ${namespace}"
else
  log "Create namespace: ${namespace}"
  kubectl create namespace "${namespace}" >/dev/null
fi

log "Managed resources"
reconcile_managed_resources "${scratch_dir}"

if [ -n "${runtime_info_file}" ] && [ -f "${runtime_info_file}" ]; then
  log "Substitute runtime info variables in FluxInstance manifest"
  export_args=""
  while IFS="=" read -r key value; do
    export_args="${export_args} ${key}=${value}"
  done < "${runtime_info_file}"
  sh -c "export${export_args}; flux envsubst --strict" \
    < "${flux_instance_file}" > "${scratch_dir}/flux-instance.yaml"
  flux_instance_file="${scratch_dir}/flux-instance.yaml"
fi

helm_release_status() {
  helm status "$1" -n "$2" 2>/dev/null | awk '/^STATUS:/{print $2; exit}'
}

install_flux_operator() {
  values_args=""
  set_args=""
  install_timeout="${timeout}"
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
  helm install flux-operator "oci://${operator_chart_repository}" \
    --namespace="${namespace}" \
    --wait=watcher \
    --timeout="${install_timeout}" \
    ${version_args} \
    ${values_args} \
    ${set_args}
}

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
      # Decode the release payload, patch the status, and re-encode.
      release_payload="$(kubectl get secret "${latest_secret}" -n "${release_namespace}" \
        -o go-template='{{index .data "release"}}' | base64 -d | gzip -d)"
      patched_payload="$(printf '%s' "${release_payload}" \
        | sed "s/\"status\":\"${release_status}\"/\"status\":\"failed\"/")"
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

unlock_helm_release "flux-operator" "${namespace}"
flux_operator_status="$(helm_release_status "flux-operator" "${namespace}")"
case "${flux_operator_status}" in
  "deployed")
    log "Flux Operator exists"
    ;;
  "failed")
    log "Delete failed Flux Operator release"
    helm delete flux-operator -n "${namespace}" --no-hooks >/dev/null
    log "Install Flux Operator"
    install_flux_operator
    ;;
  *)
    log "Install Flux Operator"
    install_flux_operator
    ;;
esac

log "FluxInstance CRD"
wait_for_flux_instance_crd

instance_created="false"
if ! kubectl get fluxinstance.fluxcd.controlplane.io "${instance_name}" -n "${namespace}" >/dev/null 2>&1; then
  log "Create FluxInstance"
  kubectl apply -f "${flux_instance_file}" >/dev/null
  instance_created="true"
else
  log "FluxInstance exists"
fi

if [ "${instance_created}" = "true" ]; then
  log "Wait for FluxInstance"
  flux-operator wait instance "${instance_name}" -n "${namespace}" --timeout="${timeout}"
else
  log "FluxInstance wait skipped"
fi

if [ -n "${debug_fault_injection_message}" ]; then
  fail "Fault injection triggered: ${debug_fault_injection_message}"
  exit 1
fi

log "Done"
