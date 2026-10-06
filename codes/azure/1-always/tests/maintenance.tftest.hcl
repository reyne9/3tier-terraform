mock_provider "azurerm" {}
variables {
  subscription_id      = "11111111-1111-1111-1111-111111111111"
  tenant_id            = "11111111-1111-1111-1111-111111111111"
  storage_account_name = "testbackups123"
}
run "maintenance_bootstrap" {
  command = plan
  assert {
    condition     = var.frontdoor_backend_mode == "maintenance" && var.azure_appgw_ip == ""
    error_message = "Maintenance must deploy without an emergency App Gateway."
  }
}
