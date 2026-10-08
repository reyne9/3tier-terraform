# PlanB/azure/2-emergency/main.tf
# 재해 시 배포: MySQL + AKS 클러스터 + Application Gateway

terraform {
  required_version = ">= 1.14.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
  tenant_id       = var.tenant_id
}

# =================================================
# Data Sources (1-always에서 생성된 리소스)
# =================================================

data "azurerm_resource_group" "main" {
  name = var.resource_group_name
}

data "azurerm_virtual_network" "main" {
  name                = var.vnet_name
  resource_group_name = var.resource_group_name
}

# Subnet 1: Application Gateway 전용 서브넷
data "azurerm_subnet" "appgw" {
  name                 = "snet-appgw"
  virtual_network_name = var.vnet_name
  resource_group_name  = var.resource_group_name
}

# Subnet 2: Web Pod 서브넷 (AKS Web 노드풀용)
data "azurerm_subnet" "web" {
  name                 = "snet-web"
  virtual_network_name = var.vnet_name
  resource_group_name  = var.resource_group_name
}

# Subnet 3: WAS Pod 서브넷 (AKS WAS 노드풀용)
data "azurerm_subnet" "was" {
  name                 = "snet-was"
  virtual_network_name = var.vnet_name
  resource_group_name  = var.resource_group_name
}

# Subnet 4: DB 서브넷 (MySQL Flexible Server용)
data "azurerm_subnet" "db" {
  name                 = "snet-db"
  virtual_network_name = var.vnet_name
  resource_group_name  = var.resource_group_name
}

data "azurerm_storage_account" "backups" {
  name                = var.storage_account_name
  resource_group_name = var.resource_group_name
}

# =================================================
# Module: MySQL Database
# =================================================

module "db" {
  source = "./modules/db"

  environment         = var.environment
  location            = data.azurerm_resource_group.main.location
  resource_group_name = data.azurerm_resource_group.main.name

  db_name             = var.db_name
  db_username         = var.db_username
  db_password         = var.db_password
  mysql_sku           = var.mysql_sku
  mysql_storage_gb    = var.mysql_storage_gb
  delegated_subnet_id = data.azurerm_subnet.db.id
  vnet_id             = data.azurerm_virtual_network.main.id

  tags = var.tags
}

# =================================================
# Module: AKS Cluster
# =================================================

module "aks" {
  source = "./modules/aks"

  environment         = var.environment
  location            = data.azurerm_resource_group.main.location
  resource_group_name = data.azurerm_resource_group.main.name
  resource_group_id   = data.azurerm_resource_group.main.id
  vnet_id             = data.azurerm_virtual_network.main.id

  web_subnet_id = data.azurerm_subnet.web.id
  was_subnet_id = data.azurerm_subnet.was.id

  kubernetes_version = var.kubernetes_version
  node_vm_size       = var.node_vm_size

  web_node_count     = var.web_node_count
  web_node_min_count = var.web_node_min_count
  web_node_max_count = var.web_node_max_count

  was_node_count     = var.was_node_count
  was_node_min_count = var.was_node_min_count
  was_node_max_count = var.was_node_max_count

  tags = var.tags
}

# =================================================
# Module: Application Gateway
# =================================================

module "appgw" {
  source = "./modules/appgw"

  environment         = var.environment
  location            = data.azurerm_resource_group.main.location
  resource_group_name = data.azurerm_resource_group.main.name

  appgw_subnet_id = data.azurerm_subnet.appgw.id

  backend_ip_addresses = var.backend_ip_addresses
  backend_port         = var.backend_port
  health_probe_path    = var.health_probe_path

  tags = var.tags
}
