# PlanB/aws/variables.tf

# =================================================
# 기본 설정
# =================================================

variable "aws_region" {
  description = "AWS 리전"
  type        = string
  default     = "ap-northeast-2"
}

variable "environment" {
  description = "환경 (dev/staging/prod)"
  type        = string
  default     = "blue"
}

# =================================================
# VPC 설정
# =================================================

variable "aws_vpc_cidr" {
  description = "VPC CIDR 블록"
  type        = string
  default     = "10.0.0.0/16"
}

variable "aws_availability_zones" {
  description = "가용 영역 목록"
  type        = list(string)
  default     = ["ap-northeast-2a", "ap-northeast-2c"]
}

variable "public_subnet_cidrs" {
  description = "Public 서브넷 CIDR 목록"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "web_subnet_cidrs" {
  description = "Web Tier 서브넷 CIDR 목록"
  type        = list(string)
  default     = ["10.0.11.0/24", "10.0.12.0/24"]
}

variable "was_subnet_cidrs" {
  description = "WAS Tier 서브넷 CIDR 목록"
  type        = list(string)
  default     = ["10.0.21.0/24", "10.0.22.0/24"]
}

variable "rds_subnet_cidrs" {
  description = "RDS 서브넷 CIDR 목록"
  type        = list(string)
  default     = ["10.0.31.0/24", "10.0.32.0/24"]
}

# =================================================
# EKS 설정
# =================================================

variable "eks_node_instance_type" {
  description = "EKS 노드 인스턴스 타입"
  type        = string
  default     = "t3.medium"
}

variable "eks_web_desired_size" {
  description = "Web Tier 원하는 노드 수"
  type        = number
  default     = 2
}

variable "eks_web_min_size" {
  description = "Web Tier 최소 노드 수"
  type        = number
  default     = 2
}

variable "eks_web_max_size" {
  description = "Web Tier 최대 노드 수"
  type        = number
  default     = 4
}

variable "eks_was_desired_size" {
  description = "WAS Tier 원하는 노드 수"
  type        = number
  default     = 2
}

variable "eks_was_min_size" {
  description = "WAS Tier 최소 노드 수"
  type        = number
  default     = 2
}

variable "eks_was_max_size" {
  description = "WAS Tier 최대 노드 수"
  type        = number
  default     = 4
}

# =================================================
# RDS 설정
# =================================================

variable "db_name" {
  description = "데이터베이스 이름"
  type        = string
  default     = "petclinic"
}

variable "db_username" {
  description = "데이터베이스 마스터 사용자명"
  type        = string
  default     = "admin"
}

variable "db_password" {
  description = "데이터베이스 마스터 비밀번호"
  type        = string
  sensitive   = true
}

variable "rds_instance_class" {
  description = "RDS 인스턴스 클래스"
  type        = string
  default     = "db.t3.medium"
}

variable "rds_allocated_storage" {
  description = "RDS 할당 스토리지 (GB)"
  type        = number
  default     = 20
}

variable "rds_max_allocated_storage" {
  description = "RDS 최대 할당 스토리지 (GB)"
  type        = number
  default     = 100
}

variable "rds_multi_az" {
  description = "Multi-AZ 활성화 여부"
  type        = bool
  default     = true
}

variable "rds_skip_final_snapshot" {
  description = "삭제 시 최종 스냅샷 건너뛰기"
  type        = bool
  default     = false
}

variable "rds_deletion_protection" {
  description = "삭제 방지 활성화"
  type        = bool
  default     = false
}

variable "rds_backup_retention" {
  description = "RDS 백업 보관 기간 (일)"
  type        = number
  default     = 7
}

# =================================================
# Azure 연동 변수 (Blob Storage)
# =================================================

variable "azure_storage_account_name" {
  description = "Azure Storage Account 이름"
  type        = string
}

variable "azure_storage_account_key" {
  description = "Azure Storage Account Key"
  type        = string
  sensitive   = true
}

variable "azure_backup_container_name" {
  description = "Azure Blob Container 이름 (백업용)"
  type        = string
  default     = "mysql-backups"
}

variable "azure_tenant_id" {
  description = "Azure Tenant ID"
  type        = string
}

variable "azure_subscription_id" {
  description = "Azure Subscription ID"
  type        = string
}

# =================================================
# 백업 인스턴스 설정
# =================================================

variable "backup_instance_ssh_public_key" {
  description = "선택 SSH 공개 키. 비워 두면 SSM으로 접속합니다."
  type        = string
  default     = ""
}

variable "enable_backup_instance" {
  description = "백업 인스턴스 활성화 여부"
  type        = bool
  default     = true
}



