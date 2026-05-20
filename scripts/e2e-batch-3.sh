#!/usr/bin/env bash
# Batch 3: Prerequisite Helm charts.

cluster_name="flux-operator-bootstrap-e2e-3"

# shellcheck source=e2e-helpers.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/e2e-helpers.sh"

prereq_charts_tf_dir="$(mktemp -d)"

cleanup() {
  kind delete cluster --name "${cluster_name}" 2>/dev/null || true
  rm -rf "${prereq_charts_tf_dir}"
}

trap cleanup EXIT

section "Cluster Setup"
note "Resetting kind cluster ${cluster_name}"
kind delete cluster --name "${cluster_name}" 2>/dev/null || true

section "Prerequisite Charts"
note "Rendering scenario with a prerequisite Helm chart (podinfo)"
prereq_charts="[{
      name       = \"podinfo\"
      repository = \"ghcr.io/stefanprodan/charts/podinfo\"
      version    = \"${e2e_podinfo_version}\"
      namespace  = \"podinfo\"
      values_yaml = \"\"
    }]"
# common_metadata is applied at creation time to the namespaces the module
# creates (the FluxInstance target namespace and prerequisite chart namespaces
# with create_namespace=true) and to the bootstrap Job; the bootstrap namespace
# is stamped by Terraform. The module reconciles the metadata until Flux adopts a
# namespace, then hands off. This batch exercises three label values: the initial
# one, a "reconciled" one applied while the chart namespace is not yet adopted
# (must be reconciled), and a "changed" one applied after the chart namespace is
# adopted (must be ignored for that namespace).
common_metadata_label_key="e2e.example.com/managed-by"
common_metadata_label_value="terraform-bootstrap"
common_metadata_label_value_reconciled="terraform-bootstrap-reconciled"
common_metadata_label_value_changed="terraform-bootstrap-changed"
common_metadata_annotation_key="e2e.example.com/purpose"
common_metadata_annotation_value="common-metadata"
make_common_metadata() {
  printf '{
      labels = {
        "%s" = "%s"
      }
      annotations = {
        "%s" = "%s"
      }
    }' "${common_metadata_label_key}" "$1" "${common_metadata_annotation_key}" "${common_metadata_annotation_value}"
}
common_metadata="$(make_common_metadata "${common_metadata_label_value}")"
common_metadata_reconciled="$(make_common_metadata "${common_metadata_label_value_reconciled}")"
common_metadata_changed="$(make_common_metadata "${common_metadata_label_value_changed}")"
render_root_module "${prereq_charts_tf_dir}" "flux-operator-bootstrap-prereq-charts" "" "one" "" 1 "" "5m" "" "${prereq_charts}" "false" "" "${common_metadata}"
note "Initializing prerequisite charts scenario"
terraform -chdir="${prereq_charts_tf_dir}" init -no-color -backend=false
note "Running apply with prerequisite chart"
terraform -chdir="${prereq_charts_tf_dir}" apply -no-color -auto-approve
assert_flux_runtime_ready
note "Verifying podinfo Helm release is deployed"
podinfo_status="$(helm --kube-context "kind-${cluster_name}" status podinfo -n podinfo -o json 2>/dev/null \
  | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4 || true)"
if [ "${podinfo_status}" != "deployed" ]; then
  echo "Expected podinfo Helm release in deployed state, got: ${podinfo_status}" >&2
  exit 1
fi
note "Verifying podinfo deployment is running"
kubectl --context "kind-${cluster_name}" -n podinfo rollout status deployment/podinfo --timeout=60s >/dev/null

section "Common Metadata"
note "Verifying common_metadata is applied to the bootstrap namespace (Terraform-owned)"
assert_namespace_common_metadata "flux-operator-bootstrap-prereq-charts" \
  "${common_metadata_label_key}" "${common_metadata_label_value}" \
  "${common_metadata_annotation_key}" "${common_metadata_annotation_value}"
note "Verifying common_metadata is applied to the prerequisite chart namespace at creation time"
assert_namespace_common_metadata "podinfo" \
  "${common_metadata_label_key}" "${common_metadata_label_value}" \
  "${common_metadata_annotation_key}" "${common_metadata_annotation_value}"
note "Verifying common_metadata is applied to the bootstrap Job"
assert_job_common_metadata "flux-operator-bootstrap-prereq-charts" \
  "${common_metadata_label_key}" "${common_metadata_label_value}" \
  "${common_metadata_annotation_key}" "${common_metadata_annotation_value}"

section "Create-If-Missing and Metadata Reconcile"
note "Re-running bootstrap with a changed common_metadata while podinfo is not yet adopted"
render_root_module "${prereq_charts_tf_dir}" "flux-operator-bootstrap-prereq-charts" "" "one" "" 2 "" "5m" "" "${prereq_charts}" "false" "" "${common_metadata_reconciled}"
terraform -chdir="${prereq_charts_tf_dir}" apply -no-color -auto-approve
assert_flux_runtime_ready
note "Verifying bootstrap logs show skip (not install/upgrade) for existing chart"
bootstrap_log="$(kubectl --context "kind-${cluster_name}" -n flux-operator-bootstrap-prereq-charts \
  logs job/flux-operator-bootstrap 2>/dev/null || true)"
if ! printf '%s' "${bootstrap_log}" | grep -q "skip chart podinfo (already exists)"; then
  echo "Bootstrap did not skip prerequisite chart that already exists" >&2
  echo "Bootstrap log:" >&2
  printf '%s\n' "${bootstrap_log}" >&2
  exit 1
fi
if printf '%s' "${bootstrap_log}" | grep -q "Install chart podinfo"; then
  echo "Bootstrap tried to install prerequisite chart that already exists" >&2
  echo "Bootstrap log:" >&2
  printf '%s\n' "${bootstrap_log}" >&2
  exit 1
fi
note "Verifying the changed common_metadata is reconciled on the not-yet-adopted podinfo namespace"
assert_namespace_common_metadata "podinfo" \
  "${common_metadata_label_key}" "${common_metadata_label_value_reconciled}" \
  "${common_metadata_annotation_key}" "${common_metadata_annotation_value}"
note "Verifying the FluxInstance target namespace is handed off once the operator adopts it"
if ! printf '%s' "${bootstrap_log}" | grep -q "skip common metadata on namespace flux-system (managed by Flux)"; then
  echo "Bootstrap did not hand off the Flux-adopted target namespace" >&2
  echo "Bootstrap log:" >&2
  printf '%s\n' "${bootstrap_log}" >&2
  exit 1
fi

section "Prerequisite Charts and Namespace Metadata Adoption"
note "Re-rendering with flux_adoption_check pointing to podinfo deployment"
prereq_charts_with_adoption="[{
      name       = \"podinfo\"
      repository = \"ghcr.io/stefanprodan/charts/podinfo\"
      version    = \"${e2e_podinfo_version}\"
      namespace  = \"podinfo\"
      values_yaml = \"\"
      flux_adoption_check = {
        resource  = \"deployment\"
        api_group = \"apps\"
        name      = \"podinfo\"
        namespace = \"podinfo\"
      }
    }]"
note "Simulating Flux adoption of the podinfo release (helm-controller label on the deployment)"
kubectl --context "kind-${cluster_name}" -n podinfo label deployment podinfo \
  helm.toolkit.fluxcd.io/name=podinfo helm.toolkit.fluxcd.io/namespace=podinfo >/dev/null
note "Simulating Flux Operator ResourceSet adoption of the podinfo namespace (ownership label on the namespace)"
kubectl --context "kind-${cluster_name}" label namespace podinfo \
  resourceset.fluxcd.controlplane.io/name=podinfo resourceset.fluxcd.controlplane.io/namespace=flux-system >/dev/null
note "Re-running bootstrap with changed common_metadata to verify adopted resources are skipped"
render_root_module "${prereq_charts_tf_dir}" "flux-operator-bootstrap-prereq-charts" "" "one" "" 3 "" "5m" "" "${prereq_charts_with_adoption}" "false" "" "${common_metadata_changed}"
terraform -chdir="${prereq_charts_tf_dir}" apply -no-color -auto-approve
assert_flux_runtime_ready
note "Verifying bootstrap logs show chart and namespace metadata adoption skips"
bootstrap_log="$(kubectl --context "kind-${cluster_name}" -n flux-operator-bootstrap-prereq-charts \
  logs job/flux-operator-bootstrap 2>/dev/null || true)"
if ! printf '%s' "${bootstrap_log}" | grep -q "skip chart podinfo (adopted by Flux)"; then
  echo "Bootstrap did not skip adopted prerequisite chart" >&2
  echo "Bootstrap log:" >&2
  printf '%s\n' "${bootstrap_log}" >&2
  exit 1
fi
if ! printf '%s' "${bootstrap_log}" | grep -q "skip common metadata on namespace podinfo (managed by Flux)"; then
  echo "Bootstrap did not skip common metadata on the Flux-adopted podinfo namespace" >&2
  echo "Bootstrap log:" >&2
  printf '%s\n' "${bootstrap_log}" >&2
  exit 1
fi
note "Verifying the adopted podinfo namespace kept its previous common_metadata (not overwritten)"
assert_namespace_common_metadata "podinfo" \
  "${common_metadata_label_key}" "${common_metadata_label_value_reconciled}" \
  "${common_metadata_annotation_key}" "${common_metadata_annotation_value}"
note "Verifying the bootstrap namespace (Terraform-owned, not adoption-gated) picked up the changed value"
assert_namespace_common_metadata "flux-operator-bootstrap-prereq-charts" \
  "${common_metadata_label_key}" "${common_metadata_label_value_changed}" \
  "${common_metadata_annotation_key}" "${common_metadata_annotation_value}"

note "Destroying prerequisite charts scenario"
terraform -chdir="${prereq_charts_tf_dir}" destroy -no-color -auto-approve

section "Assertions"
note "Verified prerequisite charts (create-if-missing + flux adoption); common metadata applied at creation time to the bootstrap namespace/chart namespace/Job; reconciled on a not-yet-adopted namespace when changed; and handed off (skipped) once the namespace is adopted by Flux"
print_elapsed_total
