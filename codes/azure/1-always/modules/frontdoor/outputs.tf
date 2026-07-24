output "frontdoor_id" {
  description = "Azure Front Door ID"
  value       = azurerm_cdn_frontdoor_profile.main.id
}

output "frontdoor_endpoint_hostname" {
  description = "Azure Front Door endpoint hostname"
  value       = azurerm_cdn_frontdoor_endpoint.main.host_name
}

output "custom_domain_validation_token" {
  description = "Custom domain validation token (if custom domain is configured)"
  value       = var.custom_domain != "" ? azurerm_cdn_frontdoor_custom_domain.main[0].validation_token : null
}

output "origin_group_id" {
  description = "Origin group ID"
  value       = azurerm_cdn_frontdoor_origin_group.main.id
}

output "azure_blob_origin_id" {
  description = "Azure Blob origin ID"
  value       = azurerm_cdn_frontdoor_origin.azure_blob.id
}

output "azure_appgw_origin_id" {
  description = "Azure Application Gateway origin ID"
  value       = var.azure_appgw_ip != "" ? azurerm_cdn_frontdoor_origin.azure_appgw[0].id : null
}

output "backend_mode" {
  description = "Active Azure Front Door backend mode"
  value       = var.backend_mode
}
