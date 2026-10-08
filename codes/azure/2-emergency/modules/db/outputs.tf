# DB Module Outputs

output "mysql_server_id" {
  description = "MySQL Server ID"
  value       = azurerm_mysql_flexible_server.main.id
}

output "mysql_server_name" {
  description = "MySQL Server Name"
  value       = azurerm_mysql_flexible_server.main.name
}

output "mysql_server_fqdn" {
  description = "MySQL Server FQDN"
  value       = azurerm_mysql_flexible_server.main.fqdn
}

output "mysql_database_name" {
  description = "MySQL Database Name"
  value       = azurerm_mysql_flexible_database.main.name
}

output "private_dns_zone_name" {
  value = azurerm_private_dns_zone.mysql.name
}

output "network_configuration" {
  description = "사설 DB 연결과 TLS 구성"
  value = {
    delegated_subnet_id = azurerm_mysql_flexible_server.main.delegated_subnet_id
    linked_vnet_id      = azurerm_private_dns_zone_virtual_network_link.mysql.virtual_network_id
    require_tls         = azurerm_mysql_flexible_server_configuration.require_secure_transport.value
  }
}
