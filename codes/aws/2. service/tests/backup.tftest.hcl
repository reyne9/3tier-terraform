mock_provider "aws" {}
mock_provider "random" {}
mock_provider "null" {}
variables {
  db_password                = "test-only-password"
  azure_storage_account_name = "testbackups"
  azure_storage_account_key  = "test-only-key"
  azure_tenant_id            = "test-tenant"
  azure_subscription_id      = "test-subscription"
}
run "backup_enabled_without_ssh_key" {
  command = plan
  assert {
    condition     = length(aws_instance.backup_instance) == 1 && length(aws_key_pair.backup_instance) == 0 && aws_instance.backup_instance[0].user_data_replace_on_change
    error_message = "Backup must support SSM-only access and rerun bootstrap when its configuration changes."
  }
}
run "backup_disabled" {
  command = plan
  variables { enable_backup_instance = false }
  assert {
    condition     = length(aws_instance.backup_instance) == 0 && length(aws_cloudwatch_metric_alarm.backup_instance_status) == 0 && output.backup_summary == "Backup instance disabled"
    error_message = "Disabling backup must omit the instance and its alarm without invalid output references."
  }
}
