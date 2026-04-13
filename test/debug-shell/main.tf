terraform {
  required_version = ">= 1.11.0"

  required_providers {
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}

# This root exercises the exact same local-exec script that the module ships
# (scripts/debug-relay.sh), without standing up a real cluster. It is meant to
# be driven by scripts/e2e-debug-shell.sh, which puts a fake `kubectl` on PATH
# that simulates a failed bootstrap Job and returns canned logs. The point is
# to validate the bash interpreter and shell semantics on whichever host runs
# Terraform — in CI this runs on Windows via Git Bash.

variable "bootstrap_namespace" {
  type    = string
  default = "test-namespace"
}

variable "timeout_seconds" {
  type    = number
  default = 30
}

resource "null_resource" "debug_on_failure" {
  triggers = {
    # Re-run on every apply so successive smoke-test runs always exercise the
    # provisioner. The real module uses a content hash here.
    timestamp = timestamp()
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = file("${path.module}/../../scripts/debug-relay.sh")
    environment = {
      BOOTSTRAP_NAMESPACE = var.bootstrap_namespace
      TIMEOUT_SECONDS     = tostring(var.timeout_seconds)
    }
  }
}
