# MySQL Flexible Server Module

resource "azurerm_mysql_flexible_server" "main" {
  name                   = "mysql-dr-${var.environment}"
  location               = var.location
  resource_group_name    = var.resource_group_name
  administrator_login    = var.db_username
  administrator_password = var.db_password

  delegated_subnet_id = var.delegated_subnet_id
  private_dns_zone_id = azurerm_private_dns_zone.mysql.id

  depends_on = [azurerm_private_dns_zone_virtual_network_link.mysql]

  sku_name = var.mysql_sku
  version  = "8.0.21"

  backup_retention_days        = 7
  geo_redundant_backup_enabled = false

  # Zone 설정 (HA 비활성화 - Burstable edition은 HA 미지원)
  zone = "1"

  storage {
    size_gb = var.mysql_storage_gb
  }

  tags = var.tags
}

resource "azurerm_mysql_flexible_database" "main" {
  name                = var.db_name
  resource_group_name = var.resource_group_name
  server_name         = azurerm_mysql_flexible_server.main.name
  charset             = "utf8mb4"
  collation           = "utf8mb4_unicode_ci"
}

# Require TLS even on the private network.
resource "azurerm_mysql_flexible_server_configuration" "require_secure_transport" {
  name                = "require_secure_transport"
  resource_group_name = var.resource_group_name
  server_name         = azurerm_mysql_flexible_server.main.name
  value               = "ON"
}

resource "azurerm_private_dns_zone" "mysql" {
  name                = "${var.environment}.private.mysql.database.azure.com"
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "mysql" {
  name                  = "mysql-${var.environment}"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.mysql.name
  virtual_network_id    = var.vnet_id
  registration_enabled  = false
  tags                  = var.tags
}
