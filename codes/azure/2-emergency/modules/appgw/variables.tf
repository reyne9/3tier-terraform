# Application Gateway Module Variables

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

variable "appgw_subnet_id" {
  description = "Application Gateway Subnet ID"
  type        = string
}

variable "backend_ip_addresses" {
  description = "Web LoadBalancer IP 목록. 최초 배포는 비워 두고 deploy-complete.sh로 연결합니다."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for ip in var.backend_ip_addresses : can(cidrnetmask("${ip}/32"))])
    error_message = "backend_ip_addresses에는 유효한 IPv4 주소만 입력하세요."
  }
}

variable "backend_port" {
  description = "Backend Port"
  type        = number
  default     = 80
}

variable "health_probe_path" {
  description = "Health Probe Path"
  type        = string
  default     = "/"
}

variable "tags" {
  description = "리소스 태그"
  type        = map(string)
}
