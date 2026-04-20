terraform {
  required_version = ">= 1.11.0"

  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.0"
    }
    # Retained for state-cleanup of the legacy null_resource.debug_on_failure
    # (now terraform_data.debug_on_failure). Will be removed in a follow-up
    # release once consumers have applied the migration.
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}
