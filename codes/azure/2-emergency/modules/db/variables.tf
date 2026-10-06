# DB Module Variables

variable "environment" {
  description = "환경 이름"
  type        = string
}

variable "location" {
  description = "Azure 리전"
  type        = string
}

variable "resource_group_name" {
  description = "Resource Group 이름"
  type        = string
}

variable "db_name" {
  description = "데이터베이스 이름"
  type        = string
}

variable "db_username" {
  description = "MySQL 관리자 사용자명"
  type        = string
  sensitive   = true
}

variable "db_password" {
  description = "MySQL 관리자 비밀번호"
  type        = string
  sensitive   = true
}

variable "mysql_sku" {
  description = "MySQL SKU"
  type        = string
}

variable "mysql_storage_gb" {
  description = "MySQL 스토리지 (GB)"
  type        = number
}

variable "tags" {
  description = "리소스 태그"
  type        = map(string)
}

variable "admin_ip" {
  description = "관리자 IP 주소 (MySQL 접근 허용)"
  type        = string
  default     = ""
}

variable "aks_outbound_ip" {
  description = "AKS에서 실제 사용하는 egress IPv4 주소"
  type        = string
}
