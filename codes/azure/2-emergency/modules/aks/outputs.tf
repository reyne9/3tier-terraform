# AKS Module Outputs

output "aks_cluster_id" {
  description = "AKS Cluster ID"
  value       = azurerm_kubernetes_cluster.main.id
}

output "aks_cluster_name" {
  description = "AKS Cluster Name"
  value       = azurerm_kubernetes_cluster.main.name
}

output "aks_cluster_fqdn" {
  description = "AKS Cluster FQDN"
  value       = azurerm_kubernetes_cluster.main.fqdn
}

output "aks_identity_principal_id" {
  description = "AKS Managed Identity Principal ID"
  value       = azurerm_kubernetes_cluster.main.identity[0].principal_id
}

output "kube_config" {
  description = "Kubernetes Config"
  value       = azurerm_kubernetes_cluster.main.kube_config_raw
  sensitive   = true
}

output "outbound_ip_address" {
  value = data.azurerm_public_ip.outbound.ip_address
}
