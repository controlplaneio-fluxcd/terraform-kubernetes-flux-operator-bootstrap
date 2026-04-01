output "host" {
  description = "Kubernetes API server URL."
  value       = data.external.kubeconfig.result.host
}

output "client_certificate" {
  description = "PEM-encoded client certificate."
  value       = base64decode(data.external.kubeconfig.result.client_certificate)
  sensitive   = true
}

output "client_key" {
  description = "PEM-encoded client key."
  value       = base64decode(data.external.kubeconfig.result.client_key)
  sensitive   = true
}

output "cluster_ca_certificate" {
  description = "PEM-encoded cluster CA certificate."
  value       = base64decode(data.external.kubeconfig.result.cluster_ca_certificate)
  sensitive   = true
}

output "context" {
  description = "Kubeconfig context name for use with kubectl."
  value       = "kind-${var.name}"
}
