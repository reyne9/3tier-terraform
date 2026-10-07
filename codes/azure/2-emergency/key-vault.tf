resource "azurerm_key_vault" "petclinic" {
  name                       = substr("kv-${var.environment}-${substr(md5(data.azurerm_resource_group.main.id), 0, 8)}", 0, 24)
  location                   = data.azurerm_resource_group.main.location
  resource_group_name        = data.azurerm_resource_group.main.name
  tenant_id                  = var.tenant_id
  sku_name                   = "standard"
  enable_rbac_authorization  = true
  soft_delete_retention_days = 7
  tags                       = var.tags
}

resource "azurerm_role_assignment" "key_vault_csi" {
  scope                = azurerm_key_vault.petclinic.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = module.aks.key_vault_csi_object_id
}

resource "azurerm_role_assignment" "key_vault_writer" {
  scope                = azurerm_key_vault.petclinic.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

data "azurerm_client_config" "current" {}

resource "azurerm_key_vault_secret" "db_url" {
  name         = "petclinic-db-url"
  value        = "jdbc:mysql://${module.db.mysql_server_fqdn}:3306/${module.db.mysql_database_name}?sslMode=REQUIRED&serverTimezone=UTC"
  key_vault_id = azurerm_key_vault.petclinic.id
  depends_on   = [azurerm_role_assignment.key_vault_writer]
}

resource "azurerm_key_vault_secret" "db_username" {
  name         = "petclinic-db-username"
  value        = var.db_username
  key_vault_id = azurerm_key_vault.petclinic.id
  depends_on   = [azurerm_role_assignment.key_vault_writer]
}

resource "azurerm_key_vault_secret" "db_password" {
  name         = "petclinic-db-password"
  value        = var.db_password
  key_vault_id = azurerm_key_vault.petclinic.id
  depends_on   = [azurerm_role_assignment.key_vault_writer]
}
