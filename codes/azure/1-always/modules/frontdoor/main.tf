# Azure Front Door Module for Multi-Cloud DR

resource "azurerm_cdn_frontdoor_profile" "main" {
  name                = "afd-multicloud-${var.environment}"
  resource_group_name = var.resource_group_name
  sku_name            = "Standard_AzureFrontDoor"

  tags = var.tags
}

resource "azurerm_cdn_frontdoor_endpoint" "main" {
  name                     = "multicloud-endpoint"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.main.id

  tags = var.tags
}

# Azure DR Origin Group
resource "azurerm_cdn_frontdoor_origin_group" "main" {
  name                     = "failover-group"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.main.id

  session_affinity_enabled = false

  health_probe {
    protocol            = var.backend_mode == "azure_service" ? "Http" : "Https"
    path                = "/"
    request_type        = "GET"
    interval_in_seconds = 30
  }

  load_balancing {
    additional_latency_in_milliseconds = 50
    sample_size                        = 4
    successful_samples_required        = 3
  }
}

# maintenance mode: Azure Blob Static Website
resource "azurerm_cdn_frontdoor_origin" "azure_blob" {
  name                          = "azure-blob-secondary"
  cdn_frontdoor_origin_group_id = azurerm_cdn_frontdoor_origin_group.main.id

  enabled                        = var.backend_mode == "maintenance"
  host_name                      = var.azure_blob_fqdn
  http_port                      = 80
  https_port                     = 443
  origin_host_header             = var.azure_blob_fqdn
  priority                       = 1
  weight                         = 1000
  certificate_name_check_enabled = true
}

# azure_service mode: Azure Application Gateway -> AKS
resource "azurerm_cdn_frontdoor_origin" "azure_appgw" {
  count = var.azure_appgw_ip != "" ? 1 : 0

  name                          = "azure-aks-appgw"
  cdn_frontdoor_origin_group_id = azurerm_cdn_frontdoor_origin_group.main.id

  enabled                        = var.backend_mode == "azure_service"
  host_name                      = var.azure_appgw_ip
  http_port                      = 80
  https_port                     = 443
  origin_host_header             = var.azure_appgw_ip
  priority                       = 1
  weight                         = 1000
  certificate_name_check_enabled = false # IP address doesn't have cert
}

# Route: Default route for all traffic
resource "azurerm_cdn_frontdoor_route" "default" {
  name                          = "default-route"
  cdn_frontdoor_endpoint_id     = azurerm_cdn_frontdoor_endpoint.main.id
  cdn_frontdoor_origin_group_id = azurerm_cdn_frontdoor_origin_group.main.id
  cdn_frontdoor_origin_ids = concat(
    [azurerm_cdn_frontdoor_origin.azure_blob.id],
    var.azure_appgw_ip != "" ? [azurerm_cdn_frontdoor_origin.azure_appgw[0].id] : []
  )

  enabled                = true
  forwarding_protocol    = var.backend_mode == "azure_service" ? "HttpOnly" : "HttpsOnly"
  https_redirect_enabled = true
  patterns_to_match      = ["/*"]
  supported_protocols    = ["Http", "Https"]

  link_to_default_domain = true

  lifecycle {
    precondition {
      condition     = var.backend_mode != "azure_service" || var.azure_appgw_ip != ""
      error_message = "backend_mode가 azure_service이면 azure_appgw_ip를 입력해야 합니다."
    }
  }
}

# Custom Domain (Optional)
resource "azurerm_cdn_frontdoor_custom_domain" "main" {
  count = var.custom_domain != "" ? 1 : 0

  name                     = replace(var.custom_domain, ".", "-")
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.main.id
  host_name                = var.custom_domain

  tls {
    certificate_type    = "ManagedCertificate"
    minimum_tls_version = "TLS12"
  }
}

# Associate Custom Domain with Route
resource "azurerm_cdn_frontdoor_custom_domain_association" "main" {
  count = var.custom_domain != "" ? 1 : 0

  cdn_frontdoor_custom_domain_id = azurerm_cdn_frontdoor_custom_domain.main[0].id
  cdn_frontdoor_route_ids        = [azurerm_cdn_frontdoor_route.default.id]
}
