# PlanB/azure/2-emergency/outputs.tf

# MySQL Outputs
output "mysql_fqdn" {
  description = "MySQL 서버 FQDN"
  value       = module.db.mysql_server_fqdn
  sensitive   = true
}

output "mysql_server_name" {
  description = "MySQL 서버 이름"
  value       = module.db.mysql_server_name
}

output "mysql_database_name" {
  description = "MySQL 데이터베이스 이름"
  value       = module.db.mysql_database_name
}

# AKS Outputs
output "aks_cluster_name" {
  description = "AKS 클러스터 이름"
  value       = module.aks.aks_cluster_name
}

output "petclinic_key_vault_name" {
  value       = azurerm_key_vault.petclinic.name
  description = "PetClinic database Key Vault"
}

output "key_vault_csi_client_id" {
  value       = module.aks.key_vault_csi_client_id
  description = "AKS Key Vault CSI add-on identity client ID"
}

output "tenant_id" {
  value       = var.tenant_id
  description = "Azure tenant ID for SecretProviderClass"
  sensitive   = true
}

output "aks_cluster_id" {
  description = "AKS 클러스터 ID"
  value       = module.aks.aks_cluster_id
}

output "aks_fqdn" {
  description = "AKS FQDN"
  value       = module.aks.aks_cluster_fqdn
}

output "aks_kubeconfig_command" {
  description = "AKS kubeconfig 설정 명령어"
  value       = "az aks get-credentials --resource-group ${var.resource_group_name} --name ${module.aks.aks_cluster_name}"
}

# Application Gateway Outputs
output "appgw_public_ip" {
  description = "Application Gateway Public IP (1-always Front Door Origin으로 사용)"
  value       = module.appgw.appgw_public_ip
}

output "appgw_name" {
  description = "Application Gateway 이름"
  value       = module.appgw.appgw_name
}

output "appgw_id" {
  description = "Application Gateway ID"
  value       = module.appgw.appgw_id
}

output "resource_group_name" {
  description = "Resource Group 이름"
  value       = data.azurerm_resource_group.main.name
}

output "deployment_summary" {
  description = "배포 요약"
  value       = <<-EOT

  ========================================
  PlanB Azure 2-emergency 배포 완료
  ========================================

  재해 대응: MySQL + AKS + Application Gateway

  MySQL:
    - Server: ${module.db.mysql_server_name}
    - FQDN: ${module.db.mysql_server_fqdn}
    - Database: ${module.db.mysql_database_name}

  AKS 클러스터:
    - Name: ${module.aks.aks_cluster_name}
    - Kubernetes: ${coalesce(var.kubernetes_version, "Azure recommended")}
    - Web Nodes: ${var.web_node_count} (min: ${var.web_node_min_count}, max: ${var.web_node_max_count})
    - WAS Nodes: ${var.was_node_count} (min: ${var.was_node_min_count}, max: ${var.was_node_max_count})
    - VM Size: ${var.node_vm_size}

  Application Gateway:
    - Name: ${module.appgw.appgw_name}
    - Public IP: ${module.appgw.appgw_public_ip}
    - Backend: ${join(", ", var.backend_ip_addresses)}
    - Backend Port: ${var.backend_port}

  ⚠️  IMPORTANT: DB 복원·서비스 검증 후 수동 전환 필요
    Application Gateway IP:
    ${module.appgw.appgw_public_ip}

  다음 단계:
    1. 최신 MySQL dump 복구
       cd scripts
       ./restore-db.sh

    2. kubectl 설정
       az aks get-credentials --resource-group ${var.resource_group_name} --name ${module.aks.aks_cluster_name}

    3. Kubernetes 리소스 배포
       cd scripts
       ./deploy-complete.sh

    4. Application Gateway/AKS에서 읽기·쓰기 검증

    5. 1-always Front Door backend를 Azure 서비스로 전환
       # 1-always terraform.tfvars에 추가:
       azure_appgw_ip = "${module.appgw.appgw_public_ip}"
       frontdoor_backend_mode = "azure_service"

       # 1-always 디렉토리에서 terraform apply
       cd ../1-always
       terraform apply

    6. AWS CloudFront를 Front Door 직접 Origin으로 수동 전환
       # codes/aws/1. route53/terraform.tfvars
       azure_frontdoor_domain_name = "<1-always frontdoor_endpoint>"
       traffic_mode = "azure_dr"

       cd ../../aws/1.\ route53
       terraform apply

  트래픽 흐름:
    User → Route53 → CloudFront → Front Door → Application Gateway → AKS

  Failover 시나리오:
    1. AWS 장애 (자동, GET/HEAD): CloudFront → Front Door → HTTPS Blob 점검 페이지
    2. 2-emergency 배포·최신 dump 복원·검증 후 (수동):
       CloudFront → Front Door → Application Gateway → AKS

  ========================================
  EOT
}

output "mysql_username" {
  value     = var.db_username
  sensitive = true
}

output "storage_account_name" {
  value = var.storage_account_name
}

output "backup_container_name" {
  value = var.backup_container_name
}

output "mysql_private_dns_zone" {
  value = module.db.private_dns_zone_name
}
