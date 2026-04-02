variable "gitops_resources" {
  description = "Resources that will be reconciled by Flux after bootstrap. These are applied with create-if-missing semantics so that Flux can take ownership of them for steady-state reconciliation."
  type = object({
    flux_instance_path  = string
    prerequisites_paths = optional(list(string), [])
  })
  nullable = false

  validation {
    condition = (
      can(file(abspath(var.gitops_resources.flux_instance_path))) &&
      can(yamldecode(file(abspath(var.gitops_resources.flux_instance_path)))) &&
      try(yamldecode(file(abspath(var.gitops_resources.flux_instance_path))).apiVersion, "") == "fluxcd.controlplane.io/v1" &&
      try(yamldecode(file(abspath(var.gitops_resources.flux_instance_path))).kind, "") == "FluxInstance" &&
      try(length(yamldecode(file(abspath(var.gitops_resources.flux_instance_path))).metadata.name) > 0, false) &&
      try(length(yamldecode(file(abspath(var.gitops_resources.flux_instance_path))).metadata.namespace) > 0, false)
    )
    error_message = "gitops_resources.flux_instance_path must point to a readable FluxInstance manifest file with metadata.name and metadata.namespace."
  }

  validation {
    condition = alltrue([
      for path in var.gitops_resources.prerequisites_paths :
      can(file(abspath(path)))
    ])
    error_message = "gitops_resources.prerequisites_paths must contain only readable manifest files."
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
    tolerations = optional(list(any), [])
  })
  default  = {}
  nullable = false
}

variable "operator" {
  description = "Flux Operator settings. 'image' overrides the container image defaults from the flux-operator Helm chart. 'chart' overrides the OCI Helm chart repository and version used to install the operator."
  type = object({
    image = optional(object({
      repository  = optional(string)
      tag         = optional(string)
      pull_policy = optional(string)
    }), {})
    chart = optional(object({
      repository = optional(string, "ghcr.io/controlplaneio-fluxcd/charts/flux-operator")
      version    = optional(string)
    }), {})
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
  default     = "5m"
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
