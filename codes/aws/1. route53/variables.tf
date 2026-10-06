# aws/route53/variables.tf

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
# Route53 & Custom Domain
# =================================================

variable "enable_custom_domain" {
  description = "커스텀 도메인 활성화"
  type        = bool
  default     = true
}

variable "domain_name" {
  description = "도메인 이름 (예: example.com)"
  type        = string
}

# =================================================
# AWS Primary Site (EKS ALB)
# =================================================

variable "eks_cluster_name" {
  description = "EKS 클러스터 이름 (ALB 자동 검색용)"
  type        = string
  default     = ""
}

variable "alb_dns_name" {
  description = "Ingress ALB DNS 이름. 비워 두면 eks_cluster_name 태그로 자동 조회"
  type        = string
  default     = ""
}

variable "alb_zone_id" {
  description = "Ingress ALB Hosted Zone ID. 비워 두면 eks_cluster_name 태그로 자동 조회"
  type        = string
  default     = ""
}

# =================================================
# Azure Secondary Site (Front Door)
# =================================================

variable "azure_frontdoor_domain_name" {
  description = "Azure Front Door endpoint hostname (1-always의 frontdoor_endpoint output, protocol 제외)"
  type        = string

  validation {
    condition = (
      trimspace(var.azure_frontdoor_domain_name) != "" &&
      !startswith(trimspace(var.azure_frontdoor_domain_name), "http://") &&
      !startswith(trimspace(var.azure_frontdoor_domain_name), "https://")
    )
    error_message = "azure_frontdoor_domain_name에는 protocol 없이 Front Door hostname만 입력해야 합니다."
  }
}

variable "traffic_mode" {
  description = "CloudFront 트래픽 모드: normal=ALB/점검 페이지 failover, azure_dr=Front Door 전체 서비스 직접 전환"
  type        = string
  default     = "normal"

  validation {
    condition     = contains(["normal", "azure_dr"], var.traffic_mode)
    error_message = "traffic_mode는 normal 또는 azure_dr여야 합니다."
  }
}

# =================================================
# Health Check Settings
# =================================================

variable "health_check_search_string" {
  description = "헬스체크에서 찾을 문자열 (HTTPS_STR_MATCH용)"
  type        = string
  default     = "PetClinic"
}
