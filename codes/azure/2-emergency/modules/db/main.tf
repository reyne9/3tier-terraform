# MySQL Flexible Server Module

resource "azurerm_mysql_flexible_server" "main" {
  name                   = "mysql-dr-${var.environment}"
  location               = var.location
  resource_group_name    = var.resource_group_name
  administrator_login    = var.db_username
  administrator_password = var.db_password

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

# MySQL 서버 설정 - SSL 요구사항 비활성화
resource "azurerm_mysql_flexible_server_configuration" "require_secure_transport" {
  name                = "require_secure_transport"
  resource_group_name = var.resource_group_name
  server_name         = azurerm_mysql_flexible_server.main.name
  value               = "OFF"
}

# MySQL 방화벽 규칙 - AKS Outbound IP 대역 허용
resource "azurerm_mysql_flexible_server_firewall_rule" "aks_subnet" {
  name                = "AllowAKSSubnet"
  resource_group_name = var.resource_group_name
  server_name         = azurerm_mysql_flexible_server.main.name
  start_ip_address    = var.aks_outbound_ip
  end_ip_address      = var.aks_outbound_ip
}

# MySQL 방화벽 규칙 - 현재 관리자 IP 허용 (선택사항)
resource "azurerm_mysql_flexible_server_firewall_rule" "admin_ip" {
  count               = var.admin_ip != "" ? 1 : 0
  name                = "AllowAdminIP"
  resource_group_name = var.resource_group_name
  server_name         = azurerm_mysql_flexible_server.main.name
  start_ip_address    = var.admin_ip
  end_ip_address      = var.admin_ip
}
