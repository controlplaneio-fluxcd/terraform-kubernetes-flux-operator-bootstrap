terraform {
  required_version = ">= 1.11.0"
}

resource "terraform_data" "kind_cluster" {
  input = var.name

  provisioner "local-exec" {
    command = "kind create cluster --name ${self.input}"
  }

  provisioner "local-exec" {
    when    = destroy
    command = "kind delete cluster --name ${self.output}"
  }
}

data "external" "kubeconfig" {
  depends_on = [terraform_data.kind_cluster]

  program = ["bash", "${path.module}/kubeconfig.sh"]

  query = {
    name = var.name
  }
}
