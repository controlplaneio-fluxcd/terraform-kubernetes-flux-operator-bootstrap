variable "gitops_resources" {
  description = "Resources that will be reconciled by Flux after bootstrap. These are applied with create-if-missing semantics so that Flux can take ownership of them for steady-state reconciliation."
  type = object({
    instance_yaml = string
    prerequisites = optional(object({
      yamls = optional(list(string), [])
      charts = optional(list(object({
        name             = string
        repository       = string
        namespace        = string
        version          = optional(string)
        create_namespace = optional(bool, true)
        values_yaml      = optional(string, "")
        flux_adoption_check = optional(object({
          resource  = string
          api_group = optional(string, "")
          name      = string
          namespace = string
        }))
      })), [])
    }), {})
    operator_chart = optional(object({
      repository  = optional(string, "ghcr.io/controlplaneio-fluxcd/charts/flux-operator")
      version     = optional(string)
      values_yaml = optional(string, "")
    }), {})
  })
  nullable = false

  validation {
    condition = (
      can(yamldecode(var.gitops_resources.instance_yaml)) &&
      try(yamldecode(var.gitops_resources.instance_yaml).apiVersion, "") == "fluxcd.controlplane.io/v1" &&
      try(yamldecode(var.gitops_resources.instance_yaml).kind, "") == "FluxInstance" &&
      try(length(yamldecode(var.gitops_resources.instance_yaml).metadata.name) > 0, false) &&
      try(length(yamldecode(var.gitops_resources.instance_yaml).metadata.namespace) > 0, false)
    )
    error_message = "gitops_resources.instance_yaml must be a valid FluxInstance manifest with metadata.name and metadata.namespace."
  }
}

variable "managed_resources" {
  description = "Resources that are applied and reconciled by Terraform on every apply. Unlike gitops_resources, these remain under Terraform's ownership and will be updated to match the desired state on each run."
  type = object({
    secrets_yaml = optional(string, "")
    runtime_info = optional(object({
      data        = map(string)
      labels      = optional(map(string), {})
      annotations = optional(map(string), {})
    }))
  })
  sensitive = true
  default   = {}
  nullable  = false
}

variable "bootstrap_namespace" {
  description = "Namespace where the Terraform-managed bootstrap transport resources are created."
  type        = string
  default     = "flux-operator-bootstrap"
  nullable    = false
}

variable "job" {
  description = "Bootstrap job settings."
  type = object({
    image = optional(object({
      repository  = optional(string, "ghcr.io/controlplaneio-fluxcd/flux-operator-bootstrap")
      pull_policy = optional(string, "IfNotPresent")
    }), {})
    affinity = optional(any, {
      nodeAffinity = {
        requiredDuringSchedulingIgnoredDuringExecution = {
          nodeSelectorTerms = [{
            matchExpressions = [{
              key      = "kubernetes.io/os"
              operator = "In"
              values   = ["linux"]
            }]
          }]
        }
      }
    })
    tolerations  = optional(list(any), [])
    host_network = optional(bool, false)
  })
  default  = {}
  nullable = false
}

variable "revision" {
  description = "Revision number that controls when the bootstrap job runs and managed secrets are reconciled. Bump this value to trigger a new bootstrap run."
  type        = number
  nullable    = false
}

variable "timeout" {
  description = "Shared timeout for FluxInstance readiness waiting and the Helm release timeout."
  type        = string
  default     = "10m"
}

variable "debug_fault_injection_message" {
  description = "Testing-only fault injection message. When non-empty, the bootstrap Job prints it and exits non-zero."
  type        = string
  default     = ""
  nullable    = false
}

variable "debug_flux_operator_image_tag" {
  description = "Testing-only override for the flux-operator chart image tag. When non-empty, forces a short timeout on the flux-operator install."
  type        = string
  default     = ""
  nullable    = false
}
