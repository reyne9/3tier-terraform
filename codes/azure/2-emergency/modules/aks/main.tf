# AKS Cluster Module

resource "azurerm_kubernetes_cluster" "main" {
  name                = "aks-dr-${var.environment}"
  location            = var.location
  resource_group_name = var.resource_group_name
  dns_prefix          = "aks-dr-${var.environment}"

  kubernetes_version = var.kubernetes_version

  # Web 노드풀 (default_node_pool) - 가용영역 1, 2에 분산
  default_node_pool {
    name                = "web"
    node_count          = var.web_node_count
    vm_size             = var.node_vm_size
    vnet_subnet_id      = var.web_subnet_id
    zones               = ["1", "2"]
    enable_auto_scaling = true
    min_count           = var.web_node_min_count
    max_count           = var.web_node_max_count

    node_labels = {
      "tier" = "web"
    }

    upgrade_settings {
      max_surge = "10%"
    }
  }

  identity {
    type = "SystemAssigned"
  }

  oidc_issuer_enabled = true

  key_vault_secrets_provider {
    secret_rotation_enabled = true
  }

  network_profile {
    network_plugin    = "azure"
    network_policy    = "azure"
    service_cidr      = "10.240.0.0/16"
    dns_service_ip    = "10.240.0.10"
    load_balancer_sku = "standard"
    load_balancer_profile {
      managed_outbound_ip_count = 1
    }
  }

  tags = var.tags
}

# WAS 노드풀 - 가용영역 1, 2에 분산
resource "azurerm_kubernetes_cluster_node_pool" "was" {
  name                  = "was"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.main.id
  vm_size               = var.node_vm_size
  node_count            = var.was_node_count
  vnet_subnet_id        = var.was_subnet_id
  zones                 = ["1", "2"]
  enable_auto_scaling   = true
  min_count             = var.was_node_min_count
  max_count             = var.was_node_max_count

  node_labels = {
    "tier" = "was"
  }

  upgrade_settings {
    max_surge = "10%"
  }

  tags = var.tags
}

# Custom VNet is outside the AKS-managed node resource group.
resource "azurerm_role_assignment" "vnet" {
  scope                = var.vnet_id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_kubernetes_cluster.main.identity[0].principal_id
}

# Query the single managed egress IP instead of guessing an Azure IP range.
data "azurerm_public_ip" "outbound" {
  name                = basename(one(azurerm_kubernetes_cluster.main.network_profile[0].load_balancer_profile[0].effective_outbound_ips))
  resource_group_name = azurerm_kubernetes_cluster.main.node_resource_group
}
