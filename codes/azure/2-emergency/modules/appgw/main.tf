# Application Gateway Module

# Public IP for Application Gateway - Zone Redundant
resource "azurerm_public_ip" "appgw" {
  name                = "pip-appgw-${var.environment}"
  location            = var.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = ["1", "2"]

  tags = var.tags
}

# Local variables for App Gateway configuration
locals {
  backend_address_pool_name      = "aks-backend-pool"
  frontend_port_name_http        = "http-port"
  frontend_ip_configuration_name = "appgw-frontend-ip"
  http_setting_name              = "aks-http-settings"
  listener_name                  = "http-listener"
  request_routing_rule_name      = "http-routing-rule"
  probe_name                     = "health-probe"
}

# Application Gateway - Zone Redundant (가용영역 1, 2에 배포)
resource "azurerm_application_gateway" "main" {
  name                = "appgw-${var.environment}"
  location            = var.location
  resource_group_name = var.resource_group_name
  zones               = ["1", "2"]

  sku {
    name     = "Standard_v2"
    tier     = "Standard_v2"
    capacity = 2
  }

  gateway_ip_configuration {
    name      = "appgw-ip-config"
    subnet_id = var.appgw_subnet_id
  }

  # Frontend IP Configuration
  frontend_ip_configuration {
    name                 = local.frontend_ip_configuration_name
    public_ip_address_id = azurerm_public_ip.appgw.id
  }

  # Frontend Port - HTTP
  frontend_port {
    name = local.frontend_port_name_http
    port = 80
  }

  # Backend Pool - AKS LoadBalancer
  backend_address_pool {
    name         = local.backend_address_pool_name
    ip_addresses = var.backend_ip_addresses
  }

  # HTTP Settings - AKS용 (HTTP)
  backend_http_settings {
    name                  = local.http_setting_name
    cookie_based_affinity = "Disabled"
    port                  = var.backend_port
    protocol              = "Http"
    request_timeout       = 60
    probe_name            = local.probe_name
  }

  # Health Probe - AKS 점검
  probe {
    name                = local.probe_name
    protocol            = "Http"
    path                = var.health_probe_path
    interval            = 30
    timeout             = 20
    unhealthy_threshold = 3
    host                = "127.0.0.1" # Host-agnostic Web listener; works with an empty bootstrap pool
    port                = var.backend_port

    match {
      status_code = ["200-399"]
    }
  }

  # HTTP Listener
  http_listener {
    name                           = local.listener_name
    frontend_ip_configuration_name = local.frontend_ip_configuration_name
    frontend_port_name             = local.frontend_port_name_http
    protocol                       = "Http"
  }

  # Routing Rule
  request_routing_rule {
    name                       = local.request_routing_rule_name
    rule_type                  = "Basic"
    http_listener_name         = local.listener_name
    backend_address_pool_name  = local.backend_address_pool_name
    backend_http_settings_name = local.http_setting_name
    priority                   = 100
  }

  # SSL Policy - Use modern TLS version
  ssl_policy {
    policy_type = "Predefined"
    policy_name = "AppGwSslPolicy20220101"
  }

  tags = var.tags
}
