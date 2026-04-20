locals {
  flux_instance_yaml = var.gitops_resources.instance_yaml
  flux_instance      = yamldecode(local.flux_instance_yaml)
  has_secrets_yaml   = trimspace(var.managed_resources.secrets_yaml) != ""
  prerequisite_files = { for idx, yaml in var.gitops_resources.prerequisites.yamls : format("prerequisite-%03d.yaml", idx) => yaml }
  timeout_value      = tonumber(trimsuffix(trimsuffix(trimsuffix(var.timeout, "s"), "m"), "h"))
  timeout_unit       = substr(var.timeout, length(var.timeout) - 1, 1)
  timeout_seconds = local.timeout_unit == "s" ? local.timeout_value : (
    local.timeout_unit == "m" ? local.timeout_value * 60 : local.timeout_value * 3600
  )
  secrets_yaml_revision = local.has_secrets_yaml ? parseint(substr(sha256(var.managed_resources.secrets_yaml), 0, 12), 16) : 0

  # The bootstrap chart's Job image tag is rendered from .Chart.Version (see
  # charts/flux-operator-bootstrap/templates/_helpers.tpl). Include it in the
  # values hash so debug_on_failure re-fires whenever a module-version-only
  # bump triggers a helm_release upgrade (otherwise the new Job would run
  # without log relay). Read from Chart.yaml so module bumps stay single-source.
  bootstrap_chart_version = yamldecode(file("${path.module}/charts/flux-operator-bootstrap/Chart.yaml")).version

  helm_values_yaml = yamlencode({
    job = {
      image = {
        repository = var.job.image.repository
        pullPolicy = var.job.image.pull_policy
      }
      affinity    = var.job.affinity
      tolerations = var.job.tolerations
      hostNetwork = var.job.host_network
    }
    gitopsResources = {
      instance = local.flux_instance_yaml
      prerequisites = {
        manifests = local.prerequisite_files
        charts = [for chart in var.gitops_resources.prerequisites.charts : {
          name            = chart.name
          repository      = chart.repository
          version         = chart.version != null ? chart.version : ""
          namespace       = chart.namespace
          createNamespace = chart.create_namespace
          values          = chart.values_yaml
          fluxAdoptionCheck = chart.flux_adoption_check != null ? {
            resource  = chart.flux_adoption_check.api_group != "" ? "${chart.flux_adoption_check.resource}.${chart.flux_adoption_check.api_group}" : chart.flux_adoption_check.resource
            name      = chart.flux_adoption_check.name
            namespace = chart.flux_adoption_check.namespace
          } : null
        }]
      }
      operatorChart = {
        repository = var.gitops_resources.operator_chart.repository
        version    = var.gitops_resources.operator_chart.version != null ? var.gitops_resources.operator_chart.version : ""
        values     = var.gitops_resources.operator_chart.values_yaml
      }
    }
    managedResources = {
      hasSecrets  = local.has_secrets_yaml
      secretsHash = local.has_secrets_yaml ? sha256(var.managed_resources.secrets_yaml) : ""
      runtimeInfo = var.managed_resources.runtime_info != null ? var.managed_resources.runtime_info : { data = {}, labels = {}, annotations = {} }
    }
    timeout                    = var.timeout
    debugFaultInjectionMessage = var.debug_fault_injection_message
    debugFluxOperatorImageTag  = var.debug_flux_operator_image_tag
    revision                   = var.revision
  })
  # Mix the bootstrap chart version into the trigger hash so debug_on_failure
  # re-fires on module-version-only upgrades. Kept out of helm_values_yaml so
  # it isn't passed to Helm as an unrecognized value.
  helm_values_hash = sha256("${local.bootstrap_chart_version}\n${local.helm_values_yaml}")
}

resource "kubernetes_namespace_v1" "this" {
  metadata {
    name = var.bootstrap_namespace
  }
}

resource "kubernetes_secret_v1" "this" {
  count = local.has_secrets_yaml ? 1 : 0

  depends_on = [kubernetes_namespace_v1.this]

  metadata {
    name      = "flux-operator-bootstrap"
    namespace = var.bootstrap_namespace
  }

  type = "Opaque"

  data_wo = {
    "secrets.yaml" = var.managed_resources.secrets_yaml
  }

  data_wo_revision = local.secrets_yaml_revision
}

resource "helm_release" "this" {
  depends_on = [kubernetes_namespace_v1.this, kubernetes_secret_v1.this]

  name             = "flux-operator-bootstrap"
  namespace        = var.bootstrap_namespace
  chart            = "${path.module}/charts/flux-operator-bootstrap"
  create_namespace = false
  upgrade_install  = false
  replace          = true
  wait             = true
  timeout          = local.timeout_seconds
  max_history      = 5

  values = [local.helm_values_yaml]
}

# null_resource.debug_on_failure polls the bootstrap Job and relays its
# stdout/stderr to Terraform output when the Job fails. It depends on the
# namespace and (optionally) the secret but NOT on helm_release, so that it
# still runs when helm_release fails. Re-runs exactly when the Helm values
# hash changes (which matches when helm_release itself will install/upgrade).
# Both poll loops use the shared `timeout` input so there are no custom
# timeouts to tune.
resource "null_resource" "debug_on_failure" {
  count = var.debug_on_failure ? 1 : 0

  depends_on = [kubernetes_namespace_v1.this, kubernetes_secret_v1.this]

  triggers = {
    values_hash = local.helm_values_hash
  }

  provisioner "local-exec" {
    # `bash` rather than `/bin/sh` so the same script also works under Git Bash
    # on Windows, where `/bin/sh` is not a stable absolute path but `bash` is on
    # PATH (via Git for Windows). The script is read verbatim via file() and
    # its dynamic inputs are passed through the environment so there is no
    # Terraform templating and shell parameter expansion (${var}, ${var%%/*},
    # etc.) works as expected.
    interpreter = ["bash", "-c"]
    command     = file("${path.module}/scripts/debug-relay.sh")
    environment = {
      BOOTSTRAP_NAMESPACE = var.bootstrap_namespace
      TIMEOUT_SECONDS     = tostring(local.timeout_seconds)
    }
  }
}
