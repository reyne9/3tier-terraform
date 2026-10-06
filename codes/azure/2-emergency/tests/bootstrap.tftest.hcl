mock_provider "azurerm" {
  mock_data "azurerm_resource_group" {
    defaults = {
      name     = "rg-dr-test"
      location = "koreacentral"
      id       = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-dr-test"
    }
  }
  mock_data "azurerm_virtual_network" {
    defaults = {
      id = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-dr-test/providers/Microsoft.Network/virtualNetworks/vnet-dr-test"
    }
  }
  mock_data "azurerm_subnet" {
    defaults = {
      id = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-dr-test/providers/Microsoft.Network/virtualNetworks/vnet-dr-test/subnets/test"
    }
  }
}
variables {
  subscription_id      = "11111111-1111-1111-1111-111111111111"
  tenant_id            = "11111111-1111-1111-1111-111111111111"
  db_password          = "Test-only-password123!"
  storage_account_name = "testbackup123"
}
run "bootstrap_without_backend" {
  command = plan
  assert {
    condition     = length(var.backend_ip_addresses) == 0 && var.backend_port == 80
    error_message = "First apply must not require a not-yet-created Kubernetes service IP."
  }
}
run "reject_placeholder_backend" {
  command = plan
  variables { backend_ip_addresses = ["REPLACE_WITH_WAS_LOADBALANCER_IP"] }
  expect_failures = [var.backend_ip_addresses]
}
