# PlanB/azure/1-always/outputs.tf
# Terraform Outputs

output "resource_group_name" {
  description = "Resource Group 이름"
  value       = azurerm_resource_group.main.name
}

output "resource_group_id" {
  description = "Resource Group ID"
  value       = azurerm_resource_group.main.id
}

output "storage_account_name" {
  description = "Storage Account 이름"
  value       = azurerm_storage_account.backups.name
}

output "storage_account_key" {
  description = "Storage Account Key"
  value       = azurerm_storage_account.backups.primary_access_key
  sensitive   = true
}

output "blob_container_url" {
  description = "Blob Container URL (백업용)"
  value       = "https://${azurerm_storage_account.backups.name}.blob.core.windows.net/${var.backup_container_name}"
}

output "static_website_url" {
  description = "점검 페이지 URL (Blob Storage Static Website)"
  value       = azurerm_storage_account.backups.primary_web_endpoint
}

output "static_website_endpoint" {
  description = "점검 페이지 접속 주소 (인터넷 공개)"
  value       = "https://${azurerm_storage_account.backups.name}.z12.web.core.windows.net/"
}

output "vnet_id" {
  description = "VNet ID"
  value       = azurerm_virtual_network.main.id
}

output "vnet_name" {
  description = "VNet Name"
  value       = azurerm_virtual_network.main.name
}

output "web_subnet_id" {
  description = "Web Subnet ID"
  value       = azurerm_subnet.web.id
}

output "was_subnet_id" {
  description = "WAS Subnet ID"
  value       = azurerm_subnet.was.id
}

output "db_subnet_id" {
  description = "DB Subnet ID"
  value       = azurerm_subnet.db.id
}

output "appgw_subnet_id" {
  description = "Application Gateway Subnet ID"
  value       = azurerm_subnet.appgw.id
}

output "route53_subdomain" {
  description = "Route53 서브도메인 (활성화된 경우)"
  value       = var.enable_route53 ? var.subdomain_name : "Route53 비활성화"
}

output "route53_cname_target" {
  description = "Route53 CNAME 타겟"
  value       = module.frontdoor.frontdoor_endpoint_hostname
}

output "frontdoor_endpoint" {
  description = "Front Door Endpoint URL"
  value       = module.frontdoor.frontdoor_endpoint_hostname
}

output "frontdoor_id" {
  description = "Front Door Profile ID"
  value       = module.frontdoor.frontdoor_id
}

output "deployment_summary" {
  description = "배포 요약"
  value       = <<-EOT

  ========================================
  PlanB Azure 1-always 배포 완료
  ========================================

  Resource Group: ${azurerm_resource_group.main.name}
  Location: ${azurerm_resource_group.main.location}

  Azure Front Door:
    - Endpoint: ${module.frontdoor.frontdoor_endpoint_hostname}
    - Primary Origin: ${var.aws_alb_fqdn}
    - Secondary Origin (Blob): ${var.storage_account_name}.z12.web.core.windows.net
    - Secondary Origin (AppGW): ${var.azure_appgw_ip != "" ? var.azure_appgw_ip : "Not configured yet"}

  Storage Account:
    - Name: ${azurerm_storage_account.backups.name}
    - 백업 Container: ${var.backup_container_name}
    - 점검 페이지: https://${azurerm_storage_account.backups.name}.z12.web.core.windows.net/

  Route53 설정:
    - 활성화: ${var.enable_route53}
    - 도메인: ${var.enable_route53 ? var.domain_name : "비활성화"}
    - CNAME 타겟: ${module.frontdoor.frontdoor_endpoint_hostname}

  네트워크 (예약됨):
    - VNet: ${azurerm_virtual_network.main.name} (${var.vnet_cidr})
    - AppGW Subnet: ${azurerm_subnet.appgw.name}
    - Web Subnet: ${azurerm_subnet.web.name}
    - WAS Subnet: ${azurerm_subnet.was.name}
    - DB Subnet: ${azurerm_subnet.db.name}

  테스트:
    curl https://${module.frontdoor.frontdoor_endpoint_hostname}/
    ${var.enable_route53 ? "curl https://${var.domain_name}/" : ""}

  백업 확인:
    az storage blob list \
      --account-name ${azurerm_storage_account.backups.name} \
      --container-name ${var.backup_container_name} \
      --output table

  월 예상 비용: ~$40 (Front Door ~$35 + Storage ~$5)

  ========================================
  EOT
}
