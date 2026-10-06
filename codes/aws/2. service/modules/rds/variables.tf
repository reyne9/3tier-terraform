# aws/modules/rds/variables.tf

variable "environment" {
  description = "환경 이름"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "subnet_ids" {
  description = "RDS 서브넷 ID 리스트"
  type        = list(string)
}

variable "eks_security_group_id" {
  description = "EKS 보안 그룹 ID"
  type        = string
}

variable "instance_class" {
  description = "RDS 인스턴스 클래스"
  type        = string
  default     = "db.t3.medium"
}

variable "allocated_storage" {
  description = "할당된 스토리지 (GB)"
  type        = number
  default     = 100
}

variable "max_allocated_storage" {
  description = "최대 스토리지 (GB)"
  type        = number
  default     = 200
}

variable "database_name" {
  description = "데이터베이스 이름"
  type        = string
}

variable "master_username" {
  description = "마스터 사용자명"
  type        = string
  sensitive   = true
}

variable "master_password" {
  description = "마스터 비밀번호"
  type        = string
  sensitive   = true
}

variable "multi_az" {
  description = "Multi-AZ 배포 여부"
  type        = bool
  default     = false
}

variable "skip_final_snapshot" {
  description = "최종 스냅샷 생략 여부"
  type        = bool
  default     = false
}

variable "deletion_protection" {
  description = "삭제 방지 활성화"
  type        = bool
  default     = true
}

variable "enhanced_monitoring_enabled" {
  description = "Enhanced Monitoring 활성화 여부"
  type        = bool
  default     = false
}

variable "monitoring_interval" {
  description = "Enhanced Monitoring 수집 간격 (초) - 0, 1, 5, 10, 15, 30, 60 중 선택"
  type        = number
  default     = 60
}

variable "backup_retention_period" {
  type    = number
  default = 7
  validation {
    condition     = var.backup_retention_period >= 0 && var.backup_retention_period <= 35
    error_message = "RDS backup retention must be between 0 and 35 days."
  }
}
