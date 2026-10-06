# aws/monitoring/variables.tf
# EKS 모니터링 모듈 변수 정의

# =================================================
# General Variables
# =================================================

variable "aws_region" {
  description = "AWS 리전"
  type        = string
  default     = "ap-northeast-2"
}

variable "environment" {
  description = "환경 이름 (dev, staging, prod)"
  type        = string
  default     = "prod"
}

variable "alert_email" {
  description = "알람 수신 이메일 주소 (deprecated - Slack 사용 권장)"
  type        = string
  default     = ""
}

# =================================================
# Slack Integration Variables
# =================================================

variable "slack_workspace_id" {
  description = "Slack Workspace ID (Team ID) - AWS Chatbot에서 Slack 연동 후 확인 가능"
  type        = string
  default     = ""
}

variable "slack_channel_id" {
  description = "Slack Channel ID - 알림을 받을 채널 ID"
  type        = string
  default     = ""
}

variable "log_retention_days" {
  description = "CloudWatch 로그 보존 기간 (일)"
  type        = number
  default     = 30
}

# =================================================
# EKS Cluster Variables
# =================================================

variable "eks_cluster_name" {
  description = "EKS 클러스터 이름"
  type        = string
}

variable "min_node_count" {
  description = "최소 노드 수 (이 값 미만시 알람)"
  type        = number
  default     = 2
}

# =================================================
# ALB Variables
# =================================================

variable "alb_name" {
  description = "Application Load Balancer 이름"
  type        = string
  default     = ""
}

variable "alb_arn_suffix" {
  description = "ALB ARN Suffix (예: app/my-alb/1234567890)"
  type        = string
  default     = ""
}

variable "target_group_arn_suffix" {
  description = "Target Group ARN Suffix"
  type        = string
  default     = ""
}

# =================================================
# RDS Variables
# =================================================

variable "rds_instance_identifier" {
  description = "RDS 인스턴스 식별자"
  type        = string
  default     = ""
}

# =================================================
# Threshold Variables - Node Level
# =================================================

variable "cpu_threshold" {
  description = "CPU 사용률 임계값 (%)"
  type        = number
  default     = 80
}

variable "memory_threshold" {
  description = "메모리 사용률 임계값 (%)"
  type        = number
  default     = 80
}

variable "disk_threshold" {
  description = "디스크 사용률 임계값 (%)"
  type        = number
  default     = 80
}

# =================================================
# Threshold Variables - Pod Level
# =================================================

variable "pod_cpu_threshold" {
  description = "Pod CPU 사용률 임계값 (%)"
  type        = number
  default     = 85
}

variable "pod_memory_threshold" {
  description = "Pod 메모리 사용률 임계값 (%)"
  type        = number
  default     = 85
}

variable "pod_restart_threshold" {
  description = "Pod 재시작 횟수 임계값 (자동 복구 트리거)"
  type        = number
  default     = 5
}

# =================================================
# Threshold Variables - ALB
# =================================================

variable "surge_queue_threshold" {
  description = "ALB 거부된 연결 수 임계값 (기존 변수명 유지)"
  type        = number
  default     = 100
}

variable "http_5xx_threshold" {
  description = "HTTP 5XX 에러 횟수 임계값"
  type        = number
  default     = 10
}

variable "latency_threshold" {
  description = "응답 지연 시간 임계값 (초)"
  type        = number
  default     = 2.0
}

# =================================================
# Threshold Variables - RDS
# =================================================

variable "rds_storage_threshold" {
  description = "RDS 여유 스토리지 임계값 (GB)"
  type        = number
  default     = 10
}

variable "rds_connections_threshold" {
  description = "RDS 연결 수 임계값"
  type        = number
  default     = 100
}

variable "rds_disk_queue_threshold" {
  description = "RDS 디스크 큐 깊이 임계값"
  type        = number
  default     = 10
}

variable "rds_latency_threshold" {
  description = "RDS Read/Write Latency 임계값 (초)"
  type        = number
  default     = 0.1 # 100ms
}

variable "rds_freeable_memory_threshold" {
  description = "RDS Freeable Memory 임계값 (bytes)"
  type        = number
  default     = 268435456 # 256MB
}

# =================================================
# Route53 Health Check Variables
# =================================================

variable "enable_route53_monitoring" {
  description = "Route53 Health Check 모니터링 활성화"
  type        = bool
  default     = true
}

variable "primary_health_check_id" {
  description = "Primary (AWS) Route53 Health Check ID"
  type        = string
  default     = ""
}

variable "secondary_health_check_id" {
  description = "Secondary (Azure) Route53 Health Check ID"
  type        = string
  default     = ""
}

variable "aws_alb_health_check_id" {
  description = "AWS ALB Direct Route53 Health Check ID (페일오버 감지용)"
  type        = string
  default     = ""
}

variable "domain_name" {
  description = "모니터링 대상 도메인 이름"
  type        = string
  default     = ""
}

# =================================================
# Container/Pod Detailed Variables
# =================================================

variable "container_cpu_threshold" {
  description = "컨테이너 CPU 사용률 임계값 (%)"
  type        = number
  default     = 80
}

variable "container_memory_threshold" {
  description = "컨테이너 메모리 사용률 임계값 (%)"
  type        = number
  default     = 80
}

variable "pod_network_rx_threshold" {
  description = "Pod 네트워크 수신 임계값 (bytes/sec)"
  type        = number
  default     = 100000000 # 100MB/s
}

variable "pod_network_tx_threshold" {
  description = "Pod 네트워크 송신 임계값 (bytes/sec)"
  type        = number
  default     = 100000000 # 100MB/s
}

variable "service_count_threshold" {
  description = "최소 서비스 수 임계값"
  type        = number
  default     = 1
}
