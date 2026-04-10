locals {
  flux_instance_yaml = file(abspath(var.gitops_resources.instance_path))
  flux_instance      = yamldecode(local.flux_instance_yaml)
  has_secrets_yaml   = trimspace(var.managed_resources.secrets_yaml) != ""
  prerequisite_files = { for idx, path in var.gitops_resources.prerequisites.paths : format("prerequisite-%03d.yaml", idx) => file(abspath(path)) }
  timeout_value      = tonumber(trimsuffix(trimsuffix(trimsuffix(var.timeout, "s"), "m"), "h"))
  timeout_unit       = substr(var.timeout, length(var.timeout) - 1, 1)
  timeout_seconds = local.timeout_unit == "s" ? local.timeout_value : (
    local.timeout_unit == "m" ? local.timeout_value * 60 : local.timeout_value * 3600
  )
  secrets_yaml_revision = local.has_secrets_yaml ? parseint(substr(sha256(var.managed_resources.secrets_yaml), 0, 12), 16) : 0
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

  values = [yamlencode({
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
            resource = chart.flux_adoption_check.api_group != "" ? "${chart.flux_adoption_check.resource}.${chart.flux_adoption_check.api_group}" : chart.flux_adoption_check.resource
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
  })]
}
