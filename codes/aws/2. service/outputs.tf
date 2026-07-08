output "aws_region" {
  description = "AWS 리전"
  value       = var.aws_region
}

output "environment" {
  description = "환경 이름"
  value       = var.environment
}

output "aws_account_id" {
  description = "AWS 계정 ID"
  value       = data.aws_caller_identity.current.account_id
}

output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "vpc_cidr" {
  description = "VPC CIDR 블록"
  value       = module.vpc.vpc_cidr
}

output "public_subnet_ids" {
  description = "Public 서브넷 ID 리스트"
  value       = module.vpc.public_subnet_ids
}

output "web_subnet_ids" {
  description = "Web Tier 서브넷 ID 리스트"
  value       = module.vpc.web_subnet_ids
}

output "was_subnet_ids" {
  description = "WAS Tier 서브넷 ID 리스트"
  value       = module.vpc.was_subnet_ids
}

output "rds_subnet_ids" {
  description = "RDS 서브넷 ID 리스트"
  value       = module.vpc.rds_subnet_ids
}

output "nat_gateway_id" {
  description = "NAT Gateway ID"
  value       = module.vpc.nat_gateway_id
}

output "eks_cluster_id" {
  description = "EKS 클러스터 ID"
  value       = module.eks.cluster_id
}

output "eks_cluster_name" {
  description = "EKS 클러스터 이름"
  value       = module.eks.cluster_name
}

output "eks_cluster_endpoint" {
  description = "EKS 클러스터 엔드포인트"
  value       = module.eks.cluster_endpoint
}

output "eks_cluster_security_group_id" {
  description = "EKS 클러스터 보안 그룹 ID"
  value       = module.eks.cluster_security_group_id
}

output "eks_web_node_group_id" {
  description = "Web Tier 노드 그룹 ID"
  value       = module.eks.web_node_group_id
}

output "eks_was_node_group_id" {
  description = "WAS Tier 노드 그룹 ID"
  value       = module.eks.was_node_group_id
}

output "eks_kubeconfig_command" {
  description = "kubectl 설정 명령어"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
}

output "rds_instance_id" {
  description = "RDS 인스턴스 ID"
  value       = module.rds.db_instance_id
}

output "rds_endpoint" {
  description = "RDS 엔드포인트 (host:port)"
  value       = module.rds.db_instance_endpoint
}

output "rds_address" {
  description = "RDS 주소 (호스트명만)"
  value       = module.rds.db_instance_address
}

output "rds_port" {
  description = "RDS 포트"
  value       = module.rds.db_port
}

output "rds_database_name" {
  description = "데이터베이스 이름"
  value       = module.rds.db_name
}

output "rds_jdbc_url" {
  description = "JDBC 연결 URL"
  value       = "jdbc:mysql://${module.rds.db_instance_address}:${module.rds.db_port}/${module.rds.db_name}"
}

output "rds_availability_zone" {
  description = "RDS 인스턴스 가용영역"
  value       = module.rds.db_availability_zone
}

output "backup_instance_id" {
  description = "백업 인스턴스 ID"
  value       = aws_instance.backup_instance.id
}

output "backup_instance_private_ip" {
  description = "백업 인스턴스 Private IP"
  value       = aws_instance.backup_instance.private_ip
}

output "backup_instance_availability_zone" {
  description = "백업 인스턴스 가용영역"
  value       = aws_instance.backup_instance.availability_zone
}

output "backup_instance_ssh_command" {
  description = "SSM Session Manager 접속 명령어"
  value       = "aws ssm start-session --target ${aws_instance.backup_instance.id}"
}

output "backup_logs_command" {
  description = "백업 로그 확인 명령어"
  value       = "sudo tail -f /var/log/mysql-backup-to-azure.log"
}


output "deployment_summary" {
  description = "배포 요약 정보"
  value       = <<-EOT
  
  ╔════════════════════════════════════════════════╗
  ║           AWS Primary Site (Plan B)            ║
  ╚════════════════════════════════════════════════╝
  
  환경: ${var.environment}
  리전: ${var.aws_region}
  계정: ${data.aws_caller_identity.current.account_id}
  
  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  📦 VPC & 네트워크
  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  VPC ID: ${module.vpc.vpc_id}
  CIDR: ${module.vpc.vpc_cidr}
  가용영역: ${join(", ", var.aws_availability_zones)}
  
  서브넷:
    - Public: ${length(module.vpc.public_subnet_ids)}개
    - Web Tier: ${length(module.vpc.web_subnet_ids)}개
    - WAS Tier: ${length(module.vpc.was_subnet_ids)}개
    - RDS: ${length(module.vpc.rds_subnet_ids)}개
  
  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  ☸️  EKS 클러스터
  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  클러스터명: ${module.eks.cluster_name}
  엔드포인트: ${module.eks.cluster_endpoint}
  
  노드 그룹:
    - Web Tier: ${var.eks_web_desired_size}대 (${var.eks_web_min_size}-${var.eks_web_max_size})
    - WAS Tier: ${var.eks_was_desired_size}대 (${var.eks_was_min_size}-${var.eks_was_max_size})
    - 인스턴스: ${var.eks_node_instance_type}
  
  kubectl 설정:
    aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}
  
  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  🗄️  RDS MySQL
  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  엔드포인트: ${module.rds.db_instance_address}:${module.rds.db_port}
  데이터베이스: ${module.rds.db_name}
  Availability Zone: ${module.rds.db_availability_zone}
  Multi-AZ: ${var.rds_multi_az ? "활성화" : "비활성화"}
  스토리지: ${var.rds_allocated_storage}GB (최대 ${var.rds_max_allocated_storage}GB)

  JDBC URL:
    jdbc:mysql://${module.rds.db_instance_address}:${module.rds.db_port}/${module.rds.db_name}

  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  💾 백업 시스템 (Plan B)
  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  인스턴스 ID: ${aws_instance.backup_instance.id}
  Private IP: ${aws_instance.backup_instance.private_ip}
  Availability Zone: ${aws_instance.backup_instance.availability_zone}
  ✅ Same AZ as RDS: ${aws_instance.backup_instance.availability_zone == module.rds.db_availability_zone ? "YES" : "NO"}
  
  백업 설정:
    - 주기: 5분마다
    - 대상: ${module.rds.db_instance_address}
    - 저장소: Azure Blob Storage
      * Account: ${var.azure_storage_account_name}
      * Container: ${var.azure_backup_container_name}
  
  접속:
    aws ssm start-session --target ${aws_instance.backup_instance.id}
  
  로그 확인:
    sudo tail -f /var/log/mysql-backup-to-azure.log
  
  Azure 백업 확인:
    az storage blob list \\
      --account-name ${var.azure_storage_account_name} \\
      --container-name ${var.azure_backup_container_name} \\
      --output table
  
  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  📋 다음 단계
  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  1. kubectl 설정:
     aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}
  
  2. 노드 확인:
     kubectl get nodes
  
  3. AWS Load Balancer Controller 설치:
     cd k8s-manifests/scripts
     ./install-lb-controller.sh
  
  4. 애플리케이션 배포:
     ./deploy-app.sh
  
  5. 백업 확인:
     aws ssm start-session --target ${aws_instance.backup_instance.id}
     sudo tail -f /var/log/mysql-backup-to-azure.log
  
  
  EOT
}

output "quick_commands" {
  description = "자주 사용하는 명령어"
  value = {
    kubectl_setup  = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
    backup_ssh     = "aws ssm start-session --target ${aws_instance.backup_instance.id}"
    backup_logs    = "sudo tail -f /var/log/mysql-backup-to-azure.log"
    rds_connection = "mysql -h ${module.rds.db_instance_address} -u ${var.db_username} -p"
    check_nodes    = "kubectl get nodes"
    check_pods     = "kubectl get pods -A"
    check_ingress  = "kubectl get ingress -A"
  }
}

output "azure_backup_info" {
  description = "Azure 백업 저장소 정보"
  value = {
    storage_account = var.azure_storage_account_name
    container       = var.azure_backup_container_name
    tenant_id       = var.azure_tenant_id
    subscription_id = var.azure_subscription_id
  }
  sensitive = true
}
