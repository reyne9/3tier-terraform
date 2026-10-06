# aws/monitoring/main.tf
# EKS 컨테이너 모니터링 및 자동 복구 설정
#
# 참고: Container Insights 메트릭 수집은 EKS 모듈의
# amazon-cloudwatch-observability 애드온에서 자동으로 처리
# 이 모듈은 수집된 메트릭을 기반으로 알람, 대시보드, 자동 복구만 설정

terraform {
  required_version = ">= 1.14.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Environment = var.environment
      Project     = "Multi-Cloud-DR"
      ManagedBy   = "Terraform"
      Component   = "Monitoring"
    }
  }
}

# Route53 metrics are only available in us-east-1
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  default_tags {
    tags = {
      Environment = var.environment
      Project     = "Multi-Cloud-DR"
      ManagedBy   = "Terraform"
      Component   = "Monitoring-Route53"
    }
  }
}

# =================================================
# 데이터 소스
# =================================================

data "aws_caller_identity" "current" {}

data "aws_eks_cluster" "main" {
  name = var.eks_cluster_name
}

data "aws_eks_node_groups" "all" {
  cluster_name = var.eks_cluster_name
}

data "aws_lb" "alb" {
  count = var.alb_name != "" ? 1 : 0
  name  = var.alb_name
}

data "aws_db_instance" "rds" {
  count                  = var.rds_instance_identifier != "" ? 1 : 0
  db_instance_identifier = var.rds_instance_identifier
}

# =================================================
# SNS Topic for Alerts
# =================================================

resource "aws_sns_topic" "alerts" {
  name = "${var.environment}-eks-monitoring-alerts"

  tags = {
    Name = "${var.environment}-eks-monitoring-alerts"
  }
}

# SNS Topic for Route53 Health Check Alerts (us-east-1)
resource "aws_sns_topic" "route53_alerts" {
  provider = aws.us_east_1
  name     = "${var.environment}-route53-health-alerts"

  tags = {
    Name = "${var.environment}-route53-health-alerts"
  }
}

# Email subscription for Route53 alerts
resource "aws_sns_topic_subscription" "route53_email" {
  provider  = aws.us_east_1
  count     = var.alert_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.route53_alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# =================================================
# Slack Integration via AWS Chatbot
# =================================================

# Slack 채널 구성을 위한 AWS Chatbot 설정 (ap-northeast-2)
resource "aws_chatbot_slack_channel_configuration" "alerts" {
  count              = var.slack_workspace_id != "" && var.slack_channel_id != "" ? 1 : 0
  configuration_name = "${var.environment}-eks-monitoring-slack"
  iam_role_arn       = aws_iam_role.chatbot[0].arn
  slack_channel_id   = var.slack_channel_id
  slack_team_id      = var.slack_workspace_id
  sns_topic_arns     = [aws_sns_topic.alerts.arn]
  logging_level      = "INFO"

  tags = {
    Name = "${var.environment}-eks-monitoring-slack"
  }
}

# Slack 채널 구성을 위한 AWS Chatbot 설정 (us-east-1 for Route53)
resource "aws_chatbot_slack_channel_configuration" "route53_alerts" {
  provider           = aws.us_east_1
  count              = var.slack_workspace_id != "" && var.slack_channel_id != "" ? 1 : 0
  configuration_name = "${var.environment}-route53-monitoring-slack"
  iam_role_arn       = aws_iam_role.chatbot_useast1[0].arn
  slack_channel_id   = var.slack_channel_id
  slack_team_id      = var.slack_workspace_id
  sns_topic_arns     = [aws_sns_topic.route53_alerts.arn]
  logging_level      = "INFO"

  tags = {
    Name = "${var.environment}-route53-monitoring-slack"
  }
}

# AWS Chatbot IAM Role
resource "aws_iam_role" "chatbot" {
  count = var.slack_workspace_id != "" && var.slack_channel_id != "" ? 1 : 0
  name  = "${var.environment}-chatbot-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "chatbot.amazonaws.com"
      }
    }]
  })

  tags = {
    Name = "${var.environment}-chatbot-role"
  }
}

resource "aws_iam_role_policy" "chatbot" {
  count = var.slack_workspace_id != "" && var.slack_channel_id != "" ? 1 : 0
  name  = "${var.environment}-chatbot-policy"
  role  = aws_iam_role.chatbot[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "cloudwatch:Describe*",
          "cloudwatch:Get*",
          "cloudwatch:List*"
        ]
        Resource = "*"
      }
    ]
  })
}

# AWS Chatbot IAM Role (us-east-1)
resource "aws_iam_role" "chatbot_useast1" {
  provider = aws.us_east_1
  count    = var.slack_workspace_id != "" && var.slack_channel_id != "" ? 1 : 0
  name     = "${var.environment}-chatbot-role-useast1"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "chatbot.amazonaws.com"
      }
    }]
  })

  tags = {
    Name = "${var.environment}-chatbot-role-useast1"
  }
}

resource "aws_iam_role_policy" "chatbot_useast1" {
  provider = aws.us_east_1
  count    = var.slack_workspace_id != "" && var.slack_channel_id != "" ? 1 : 0
  name     = "${var.environment}-chatbot-policy-useast1"
  role     = aws_iam_role.chatbot_useast1[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "cloudwatch:Describe*",
          "cloudwatch:Get*",
          "cloudwatch:List*"
        ]
        Resource = "*"
      }
    ]
  })
}

# =================================================
# CloudWatch Log Group for Container Insights
# =================================================
# 참고: 로그 그룹은 CloudWatch Observability 애드온이 자동 생성하지만,
# Terraform으로 관리하면 보존 기간 등을 명시적으로 제어할 수 있습니다.

resource "aws_cloudwatch_log_group" "container_insights" {
  name              = "/aws/containerinsights/${var.eks_cluster_name}/performance"
  retention_in_days = var.log_retention_days

  tags = {
    Name = "${var.environment}-container-insights"
  }
}

resource "aws_cloudwatch_log_group" "application" {
  name              = "/aws/containerinsights/${var.eks_cluster_name}/application"
  retention_in_days = var.log_retention_days

  tags = {
    Name = "${var.environment}-application-logs"
  }
}

# =================================================
# EC2 Instance Alarms (EKS Worker Nodes)
# =================================================

# CPUUtilization Alarm
resource "aws_cloudwatch_metric_alarm" "node_cpu_high" {
  alarm_name          = "${var.eks_cluster_name}-node-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "node_cpu_utilization"
  namespace           = "ContainerInsights"
  period              = 300
  statistic           = "Average"
  threshold           = var.cpu_threshold
  alarm_description   = "10 분 내 2개의 데이터 포인트에 대한 node_cpu_utilization > ${var.cpu_threshold}"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = var.eks_cluster_name
  }

  tags = {
    Name = "${var.eks_cluster_name}-node-cpu-high"
  }
}

# StatusCheckFailed Alarm (EC2 인스턴스 상태 체크)
data "aws_eks_node_group" "monitoring" {
  for_each        = data.aws_eks_node_groups.all.names
  cluster_name    = var.eks_cluster_name
  node_group_name = each.value
}

locals {
  node_asg_names = sort(flatten([
    for group in data.aws_eks_node_group.monitoring : [
      for asg in group.resources[0].autoscaling_groups : asg.name
    ]
  ]))
}

resource "aws_cloudwatch_metric_alarm" "node_status_check_failed" {
  alarm_name          = "${var.environment}-eks-node-status-check-failed"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  threshold           = 0
  alarm_description   = "EKS 노드 상태 체크 실패 - 자동 복구 트리거"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
  treat_missing_data  = "missing"

  metric_query {
    id          = "failed"
    expression  = "MAX(METRICS())"
    return_data = true
  }

  dynamic "metric_query" {
    for_each = local.node_asg_names
    content {
      id          = "node${metric_query.key}"
      return_data = false
      metric {
        namespace   = "AWS/EC2"
        metric_name = "StatusCheckFailed"
        period      = 60
        stat        = "Maximum"
        dimensions  = { AutoScalingGroupName = metric_query.value }
      }
    }
  }
}

# Memory Utilization Alarm
resource "aws_cloudwatch_metric_alarm" "node_memory_high" {
  alarm_name          = "${var.eks_cluster_name}-node-memory-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "node_memory_utilization"
  namespace           = "ContainerInsights"
  period              = 300
  statistic           = "Average"
  threshold           = var.memory_threshold
  alarm_description   = "10 분 내 2개의 데이터 포인트에 대한 node_memory_utilization > ${var.memory_threshold}"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = var.eks_cluster_name
  }

  tags = {
    Name = "${var.eks_cluster_name}-node-memory-high"
  }
}

# Disk Utilization Alarm
resource "aws_cloudwatch_metric_alarm" "node_disk_high" {
  alarm_name          = "${var.eks_cluster_name}-node-disk-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "node_filesystem_utilization"
  namespace           = "ContainerInsights"
  period              = 300
  statistic           = "Average"
  threshold           = var.disk_threshold
  alarm_description   = "10 분 내 2개의 데이터 포인트에 대한 node_filesystem_utilization > ${var.disk_threshold}"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = var.eks_cluster_name
  }

  tags = {
    Name = "${var.eks_cluster_name}-node-disk-high"
  }
}

# Node Status (노드 수 모니터링)
resource "aws_cloudwatch_metric_alarm" "node_count_low" {
  alarm_name          = "${var.eks_cluster_name}-node-count-low"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  metric_name         = "cluster_node_count"
  namespace           = "ContainerInsights"
  period              = 300
  statistic           = "Average"
  threshold           = var.min_node_count
  alarm_description   = "10 분 내 2개의 데이터 포인트에 대한 cluster_node_count < ${var.min_node_count}"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = var.eks_cluster_name
  }

  tags = {
    Name = "${var.eks_cluster_name}-node-count-low"
  }
}

# =================================================
# ALB Alarms
# =================================================

# RejectedConnectionCount Alarm
resource "aws_cloudwatch_metric_alarm" "alb_surge_queue" {
  count               = var.alb_name != "" ? 1 : 0
  alarm_name          = "${var.environment}-alb-surge-queue-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "RejectedConnectionCount"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Sum"
  threshold           = var.surge_queue_threshold
  alarm_description   = "ALB 거부된 연결 수가 ${var.surge_queue_threshold}을 초과했습니다"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
  }

  tags = {
    Name = "${var.environment}-alb-surge-queue-high"
  }
}

# HTTPCode_ELB_5XX Alarm
resource "aws_cloudwatch_metric_alarm" "alb_5xx_errors" {
  count               = var.alb_name != "" ? 1 : 0
  alarm_name          = "${var.eks_cluster_name}-alb-5xx-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "HTTPCode_ELB_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = 300
  statistic           = "Sum"
  threshold           = var.http_5xx_threshold
  alarm_description   = "5 분 내 1개의 데이터 포인트에 대한 HTTPCode_ELB_5XX_Count > ${var.http_5xx_threshold}"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
  }

  tags = {
    Name = "${var.eks_cluster_name}-alb-5xx-high"
  }
}

# Target 5XX Errors
resource "aws_cloudwatch_metric_alarm" "target_5xx_errors" {
  count               = var.alb_name != "" ? 1 : 0
  alarm_name          = "${var.environment}-target-5xx-errors-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "HTTPCode_Target_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = 300
  statistic           = "Sum"
  threshold           = var.http_5xx_threshold
  alarm_description   = "Target 5XX 에러가 ${var.http_5xx_threshold}회를 초과했습니다"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
  }

  tags = {
    Name = "${var.environment}-target-5xx-errors-high"
  }
}

# Latency Alarm
resource "aws_cloudwatch_metric_alarm" "alb_latency_high" {
  count               = var.alb_name != "" ? 1 : 0
  alarm_name          = "${var.eks_cluster_name}-alb-latency-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "TargetResponseTime"
  namespace           = "AWS/ApplicationELB"
  period              = 300
  extended_statistic  = "p90"
  threshold           = var.latency_threshold
  alarm_description   = "10 분 내 2개의 데이터 포인트에 대한 TargetResponseTime > ${var.latency_threshold}"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
  }

  tags = {
    Name = "${var.eks_cluster_name}-alb-latency-high"
  }
}

# Unhealthy Host Count
resource "aws_cloudwatch_metric_alarm" "unhealthy_hosts" {
  count               = var.alb_name != "" && var.target_group_arn_suffix != "" ? 1 : 0
  alarm_name          = "${var.eks_cluster_name}-alb-unhealthy-host"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "UnHealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = 300
  statistic           = "Average"
  threshold           = 1
  alarm_description   = "5 분 내 1개의 데이터 포인트에 대한 UnHealthyHostCount >= 1"
  alarm_actions       = []
  ok_actions          = []
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
    TargetGroup  = var.target_group_arn_suffix
  }

  tags = {
    Name = "${var.eks_cluster_name}-alb-unhealthy-host"
  }
}

# =================================================
# RDS Alarms
# =================================================

# FreeStorageSpace Alarm
resource "aws_cloudwatch_metric_alarm" "rds_storage_low" {
  count               = var.rds_instance_identifier != "" ? 1 : 0
  alarm_name          = "${var.environment}-rds-storage-low"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  metric_name         = "FreeStorageSpace"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = var.rds_storage_threshold * 1024 * 1024 * 1024 # GB to Bytes
  alarm_description   = "RDS 여유 스토리지가 ${var.rds_storage_threshold}GB 미만입니다"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  dimensions = {
    DBInstanceIdentifier = var.rds_instance_identifier
  }

  tags = {
    Name = "${var.environment}-rds-storage-low"
  }
}

# DatabaseConnections Alarm
resource "aws_cloudwatch_metric_alarm" "rds_connections_high" {
  count               = var.rds_instance_identifier != "" ? 1 : 0
  alarm_name          = "${var.environment}-rds-connections-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "DatabaseConnections"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = var.rds_connections_threshold
  alarm_description   = "RDS 연결 수가 ${var.rds_connections_threshold}개를 초과했습니다"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  dimensions = {
    DBInstanceIdentifier = var.rds_instance_identifier
  }

  tags = {
    Name = "${var.environment}-rds-connections-high"
  }
}

# DiskQueueDepth Alarm
resource "aws_cloudwatch_metric_alarm" "rds_disk_queue_high" {
  count               = var.rds_instance_identifier != "" ? 1 : 0
  alarm_name          = "${var.environment}-rds-disk-queue-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "DiskQueueDepth"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = var.rds_disk_queue_threshold
  alarm_description   = "RDS 디스크 큐 깊이가 ${var.rds_disk_queue_threshold}을 초과했습니다"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  dimensions = {
    DBInstanceIdentifier = var.rds_instance_identifier
  }

  tags = {
    Name = "${var.environment}-rds-disk-queue-high"
  }
}

# RDS CPU Utilization
resource "aws_cloudwatch_metric_alarm" "rds_cpu_high" {
  count               = var.rds_instance_identifier != "" ? 1 : 0
  alarm_name          = "${var.rds_instance_identifier}-rds-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = var.cpu_threshold
  alarm_description   = "10 분 내 2개의 데이터 포인트에 대한 CPUUtilization > ${var.cpu_threshold}"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBInstanceIdentifier = var.rds_instance_identifier
  }

  tags = {
    Name = "${var.rds_instance_identifier}-rds-cpu-high"
  }
}

# RDS Read Latency
resource "aws_cloudwatch_metric_alarm" "rds_read_latency_high" {
  count               = var.rds_instance_identifier != "" ? 1 : 0
  alarm_name          = "${var.rds_instance_identifier}-rds-read-latency-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "ReadLatency"
  namespace           = "AWS/RDS"
  period              = 300
  extended_statistic  = "p90"
  threshold           = var.rds_latency_threshold
  alarm_description   = "10 분 내 2개의 데이터 포인트에 대한 ReadLatency > ${var.rds_latency_threshold}"
  alarm_actions       = []
  ok_actions          = []
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBInstanceIdentifier = var.rds_instance_identifier
  }

  tags = {
    Name = "${var.rds_instance_identifier}-rds-read-latency-high"
  }
}

# RDS Write Latency
resource "aws_cloudwatch_metric_alarm" "rds_write_latency_high" {
  count               = var.rds_instance_identifier != "" ? 1 : 0
  alarm_name          = "${var.rds_instance_identifier}-rds-write-latency-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "WriteLatency"
  namespace           = "AWS/RDS"
  period              = 300
  extended_statistic  = "p90"
  threshold           = var.rds_latency_threshold
  alarm_description   = "10 분 내 2개의 데이터 포인트에 대한 WriteLatency > ${var.rds_latency_threshold}"
  alarm_actions       = []
  ok_actions          = []
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBInstanceIdentifier = var.rds_instance_identifier
  }

  tags = {
    Name = "${var.rds_instance_identifier}-rds-write-latency-high"
  }
}

# RDS Freeable Memory Low
resource "aws_cloudwatch_metric_alarm" "rds_memory_low" {
  count               = var.rds_instance_identifier != "" ? 1 : 0
  alarm_name          = "${var.rds_instance_identifier}-rds-memory-low"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  metric_name         = "FreeableMemory"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = var.rds_freeable_memory_threshold
  alarm_description   = "10 분 내 2개의 데이터 포인트에 대한 FreeableMemory < ${var.rds_freeable_memory_threshold}"
  alarm_actions       = []
  ok_actions          = []
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBInstanceIdentifier = var.rds_instance_identifier
  }

  tags = {
    Name = "${var.rds_instance_identifier}-rds-memory-low"
  }
}

# =================================================
# Container Insights - Pod Level Alarms
# =================================================

# Pod CPU Utilization
resource "aws_cloudwatch_metric_alarm" "pod_cpu_high" {
  alarm_name          = "${var.eks_cluster_name}-pod-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "pod_cpu_utilization"
  namespace           = "ContainerInsights"
  period              = 300
  statistic           = "Average"
  threshold           = var.pod_cpu_threshold
  alarm_description   = "10 분 내 2개의 데이터 포인트에 대한 pod_cpu_utilization > ${var.pod_cpu_threshold}"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = var.eks_cluster_name
  }

  tags = {
    Name = "${var.eks_cluster_name}-pod-cpu-high"
  }
}

# Pod Memory Utilization
resource "aws_cloudwatch_metric_alarm" "pod_memory_high" {
  alarm_name          = "${var.eks_cluster_name}-pod-memory-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "pod_memory_utilization"
  namespace           = "ContainerInsights"
  period              = 300
  statistic           = "Average"
  threshold           = var.pod_memory_threshold
  alarm_description   = "10 분 내 2개의 데이터 포인트에 대한 pod_memory_utilization > ${var.pod_memory_threshold}"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = var.eks_cluster_name
  }

  tags = {
    Name = "${var.eks_cluster_name}-pod-memory-high"
  }
}

# Pod Restart Count (자동 복구 트리거)
resource "aws_cloudwatch_metric_alarm" "pod_restart_high" {
  alarm_name          = "${var.eks_cluster_name}-pod-restart-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "pod_number_of_container_restarts"
  namespace           = "ContainerInsights"
  period              = 300
  statistic           = "Sum"
  threshold           = var.pod_restart_threshold
  alarm_description   = "5 분 내 1개의 데이터 포인트에 대한 pod_number_of_container_restarts > ${var.pod_restart_threshold}"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = var.eks_cluster_name
  }

  tags = {
    Name = "${var.eks_cluster_name}-pod-restart-high"
  }
}

# =================================================
# Container Level Alarms (상세 컨테이너 메트릭)
# =================================================

# Container CPU Utilization
resource "aws_cloudwatch_metric_alarm" "container_cpu_high" {
  alarm_name          = "${var.eks_cluster_name}-container-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "container_cpu_utilization"
  namespace           = "ContainerInsights"
  period              = 300
  statistic           = "Average"
  threshold           = var.container_cpu_threshold
  alarm_description   = "10 분 내 2개의 데이터 포인트에 대한 container_cpu_utilization > ${var.container_cpu_threshold}"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = var.eks_cluster_name
  }

  tags = {
    Name = "${var.eks_cluster_name}-container-cpu-high"
  }
}

# Container Memory Utilization
resource "aws_cloudwatch_metric_alarm" "container_memory_high" {
  alarm_name          = "${var.eks_cluster_name}-container-memory-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "container_memory_utilization"
  namespace           = "ContainerInsights"
  period              = 300
  statistic           = "Average"
  threshold           = var.container_memory_threshold
  alarm_description   = "10 분 내 2개의 데이터 포인트에 대한 container_memory_utilization > ${var.container_memory_threshold}"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = var.eks_cluster_name
  }

  tags = {
    Name = "${var.eks_cluster_name}-container-memory-high"
  }
}

# Pod Network RX (수신)
resource "aws_cloudwatch_metric_alarm" "pod_network_rx_high" {
  alarm_name          = "${var.environment}-pod-network-rx-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "pod_network_rx_bytes"
  namespace           = "ContainerInsights"
  period              = 300
  statistic           = "Average"
  threshold           = var.pod_network_rx_threshold
  alarm_description   = "Pod 네트워크 수신량이 임계값을 초과했습니다"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  dimensions = {
    ClusterName = var.eks_cluster_name
  }

  tags = {
    Name = "${var.environment}-pod-network-rx-high"
  }
}

# Pod Network TX (송신)
resource "aws_cloudwatch_metric_alarm" "pod_network_tx_high" {
  alarm_name          = "${var.environment}-pod-network-tx-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "pod_network_tx_bytes"
  namespace           = "ContainerInsights"
  period              = 300
  statistic           = "Average"
  threshold           = var.pod_network_tx_threshold
  alarm_description   = "Pod 네트워크 송신량이 임계값을 초과했습니다"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  dimensions = {
    ClusterName = var.eks_cluster_name
  }

  tags = {
    Name = "${var.environment}-pod-network-tx-high"
  }
}

# Service Count (실행 중인 서비스 수)
resource "aws_cloudwatch_metric_alarm" "service_count_low" {
  alarm_name          = "${var.environment}-service-count-low"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  metric_name         = "service_number_of_running_pods"
  namespace           = "ContainerInsights"
  period              = 300
  statistic           = "Average"
  threshold           = var.service_count_threshold
  alarm_description   = "실행 중인 서비스 Pod 수가 ${var.service_count_threshold}개 미만입니다"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  dimensions = {
    ClusterName = var.eks_cluster_name
  }

  tags = {
    Name = "${var.environment}-service-count-low"
  }
}

# =================================================
# Route53 Health Check Alarms
# =================================================

# Primary Health Check (AWS) 알람
resource "aws_cloudwatch_metric_alarm" "route53_primary_health" {
  provider            = aws.us_east_1
  count               = var.enable_route53_monitoring && var.primary_health_check_id != "" ? 1 : 0
  alarm_name          = "route53-primary-health-check-failed"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  metric_name         = "HealthCheckStatus"
  namespace           = "AWS/Route53"
  period              = 60
  statistic           = "Minimum"
  threshold           = 1
  alarm_description   = "1 분 내 1개의 데이터 포인트에 대한 HealthCheckStatus < 1"
  alarm_actions       = [aws_sns_topic.route53_alerts.arn]
  ok_actions          = [aws_sns_topic.route53_alerts.arn]
  treat_missing_data  = "notBreaching"

  dimensions = {
    HealthCheckId = var.primary_health_check_id
  }

  tags = {
    Name = "route53-primary-health-check-failed"
  }
}

# Secondary Health Check (Azure) 알람
resource "aws_cloudwatch_metric_alarm" "route53_secondary_health" {
  provider            = aws.us_east_1
  count               = var.enable_route53_monitoring && var.secondary_health_check_id != "" ? 1 : 0
  alarm_name          = "route53-secondary-health-check-failed"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  metric_name         = "HealthCheckStatus"
  namespace           = "AWS/Route53"
  period              = 60
  statistic           = "Minimum"
  threshold           = 1
  alarm_description   = "1 분 내 1개의 데이터 포인트에 대한 HealthCheckStatus < 1"
  alarm_actions       = [aws_sns_topic.route53_alerts.arn]
  ok_actions          = [aws_sns_topic.route53_alerts.arn]
  treat_missing_data  = "notBreaching"

  dimensions = {
    HealthCheckId = var.secondary_health_check_id
  }

  tags = {
    Name = "route53-secondary-health-check-failed"
  }
}

# Route53 Health Check Percentage (Primary)
resource "aws_cloudwatch_metric_alarm" "route53_primary_percentage" {
  provider            = aws.us_east_1
  count               = var.enable_route53_monitoring && var.primary_health_check_id != "" ? 1 : 0
  alarm_name          = "${var.environment}-route53-primary-percentage-low"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  metric_name         = "HealthCheckPercentageHealthy"
  namespace           = "AWS/Route53"
  period              = 60
  statistic           = "Average"
  threshold           = 50
  alarm_description   = "Primary Health Check 정상 비율이 50% 미만입니다"
  alarm_actions       = [aws_sns_topic.route53_alerts.arn]
  ok_actions          = [aws_sns_topic.route53_alerts.arn]

  dimensions = {
    HealthCheckId = var.primary_health_check_id
  }

  tags = {
    Name = "${var.environment}-route53-primary-percentage-low"
  }
}

# Route53 Health Check Percentage (Secondary)
resource "aws_cloudwatch_metric_alarm" "route53_secondary_percentage" {
  provider            = aws.us_east_1
  count               = var.enable_route53_monitoring && var.secondary_health_check_id != "" ? 1 : 0
  alarm_name          = "${var.environment}-route53-secondary-percentage-low"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  metric_name         = "HealthCheckPercentageHealthy"
  namespace           = "AWS/Route53"
  period              = 60
  statistic           = "Average"
  threshold           = 50
  alarm_description   = "Secondary Health Check 정상 비율이 50% 미만입니다"
  alarm_actions       = [aws_sns_topic.route53_alerts.arn]
  ok_actions          = [aws_sns_topic.route53_alerts.arn]

  dimensions = {
    HealthCheckId = var.secondary_health_check_id
  }

  tags = {
    Name = "${var.environment}-route53-secondary-percentage-low"
  }
}

# AWS ALB Direct Health Check (페일오버 감지용)
resource "aws_cloudwatch_metric_alarm" "route53_aws_alb_health" {
  provider            = aws.us_east_1
  count               = var.enable_route53_monitoring && var.aws_alb_health_check_id != "" ? 1 : 0
  alarm_name          = "route53-aws-alb-health-check-failed"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  metric_name         = "HealthCheckStatus"
  namespace           = "AWS/Route53"
  period              = 60
  statistic           = "Minimum"
  threshold           = 1
  alarm_description   = "AWS ALB 직접 헬스체크 실패 - CloudFront 페일오버 감지"
  alarm_actions       = [aws_sns_topic.route53_alerts.arn]
  ok_actions          = [aws_sns_topic.route53_alerts.arn]
  treat_missing_data  = "notBreaching"

  dimensions = {
    HealthCheckId = var.aws_alb_health_check_id
  }

  tags = {
    Name     = "route53-aws-alb-health-check-failed"
    Purpose  = "AWS-ALB-Direct-Monitoring"
    Severity = "HIGH"
  }
}

# Composite Alarm: 모든 Health Check가 실패했을 때
resource "aws_cloudwatch_composite_alarm" "all_sites_down" {
  provider          = aws.us_east_1
  count             = var.enable_route53_monitoring && var.primary_health_check_id != "" && var.secondary_health_check_id != "" ? 1 : 0
  alarm_name        = "${var.environment}-all-sites-down-critical"
  alarm_description = "CRITICAL: Primary와 Secondary 사이트 모두 Health Check 실패"

  alarm_rule = "ALARM(${aws_cloudwatch_metric_alarm.route53_primary_health[0].alarm_name}) AND ALARM(${aws_cloudwatch_metric_alarm.route53_secondary_health[0].alarm_name})"

  alarm_actions = [aws_sns_topic.route53_alerts.arn]
  ok_actions    = [aws_sns_topic.route53_alerts.arn]

  tags = {
    Name     = "${var.environment}-all-sites-down-critical"
    Severity = "CRITICAL"
  }
}

# =================================================
# Auto Recovery - Lambda Function
# =================================================

# IAM Role for Lambda
resource "aws_iam_role" "auto_recovery_lambda" {
  name = "${var.environment}-auto-recovery-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })

  tags = {
    Name = "${var.environment}-auto-recovery-lambda-role"
  }
}

resource "aws_iam_role_policy" "auto_recovery_lambda" {
  name = "${var.environment}-auto-recovery-lambda-policy"
  role = aws_iam_role.auto_recovery_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Effect = "Allow"
        Action = [
          "eks:DescribeCluster",
          "eks:ListNodegroups",
          "eks:DescribeNodegroup",
          "eks:UpdateNodegroupConfig"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "autoscaling:DescribeAutoScalingGroups",
          "autoscaling:SetDesiredCapacity",
          "autoscaling:TerminateInstanceInAutoScalingGroup"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceStatus",
          "ec2:TerminateInstances",
          "ec2:RebootInstances"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "sns:Publish"
        ]
        Resource = aws_sns_topic.alerts.arn
      }
    ]
  })
}

# Lambda Function for Auto Recovery
data "archive_file" "lambda_zip" {
  type        = "zip"
  output_path = "${path.module}/lambda/auto_recovery_generated.zip"

  source {
    content  = file("${path.module}/lambda/index.py")
    filename = "index.py"
  }
}

resource "aws_lambda_function" "auto_recovery" {
  filename         = data.archive_file.lambda_zip.output_path
  function_name    = "${var.environment}-eks-auto-recovery"
  role             = aws_iam_role.auto_recovery_lambda.arn
  handler          = "index.handler"
  runtime          = "python3.11"
  timeout          = 300
  memory_size      = 256
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  environment {
    variables = {
      CLUSTER_NAME  = var.eks_cluster_name
      SNS_TOPIC_ARN = aws_sns_topic.alerts.arn
      ENVIRONMENT   = var.environment
    }
  }

  tags = {
    Name = "${var.environment}-eks-auto-recovery"
  }

  depends_on = [aws_cloudwatch_log_group.lambda_logs, aws_iam_role_policy.auto_recovery_lambda]
}

resource "aws_cloudwatch_log_group" "lambda_logs" {
  name              = "/aws/lambda/${var.environment}-eks-auto-recovery"
  retention_in_days = var.log_retention_days

  tags = {
    Name = "${var.environment}-lambda-logs"
  }
}

# SNS Subscription for Lambda (Auto Recovery Trigger)
resource "aws_sns_topic_subscription" "lambda_trigger" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.auto_recovery.arn
}

resource "aws_lambda_permission" "sns_invoke" {
  statement_id  = "AllowSNSInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.auto_recovery.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.alerts.arn
}

# =================================================
# CloudWatch Dashboard
# =================================================

resource "aws_cloudwatch_dashboard" "eks_monitoring" {
  dashboard_name = "${var.environment}-eks-monitoring-dashboard"

  dashboard_body = jsonencode({
    widgets = [
      # Row 1: Cluster Overview
      {
        type   = "text"
        x      = 0
        y      = 0
        width  = 24
        height = 1
        properties = {
          markdown = "# 🎯 EKS Cluster Monitoring Dashboard - ${var.environment}"
        }
      },

      # Row 2: Node Metrics
      {
        type   = "text"
        x      = 0
        y      = 1
        width  = 24
        height = 1
        properties = {
          markdown = "## 📊 Node Metrics"
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 2
        width  = 6
        height = 6
        properties = {
          title  = "Node CPU Utilization"
          region = var.aws_region
          view   = "gauge"
          metrics = [
            ["ContainerInsights", "node_cpu_utilization", "ClusterName", var.eks_cluster_name, { stat = "Average" }]
          ]
          period = 300
          yAxis = {
            left = { min = 0, max = 100 }
          }
          annotations = {
            horizontal = [{
              value = var.cpu_threshold
              label = "Threshold"
              color = "#ff0000"
            }]
          }
        }
      },
      {
        type   = "metric"
        x      = 6
        y      = 2
        width  = 6
        height = 6
        properties = {
          title  = "Node Memory Utilization"
          region = var.aws_region
          view   = "gauge"
          metrics = [
            ["ContainerInsights", "node_memory_utilization", "ClusterName", var.eks_cluster_name, { stat = "Average" }]
          ]
          period = 300
          yAxis = {
            left = { min = 0, max = 100 }
          }
          annotations = {
            horizontal = [{
              value = var.memory_threshold
              label = "Threshold"
              color = "#ff0000"
            }]
          }
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 2
        width  = 6
        height = 6
        properties = {
          title  = "Node Disk Utilization"
          region = var.aws_region
          view   = "gauge"
          metrics = [
            ["ContainerInsights", "node_filesystem_utilization", "ClusterName", var.eks_cluster_name, { stat = "Average" }]
          ]
          period = 300
          yAxis = {
            left = { min = 0, max = 100 }
          }
          annotations = {
            horizontal = [{
              value = var.disk_threshold
              label = "Threshold"
              color = "#ff0000"
            }]
          }
        }
      },
      {
        type   = "metric"
        x      = 18
        y      = 2
        width  = 6
        height = 6
        properties = {
          title  = "Node Count & Status"
          region = var.aws_region
          view   = "singleValue"
          metrics = [
            ["ContainerInsights", "cluster_node_count", "ClusterName", var.eks_cluster_name, { stat = "Average", label = "Total Nodes" }],
            ["ContainerInsights", "cluster_failed_node_count", "ClusterName", var.eks_cluster_name, { stat = "Average", label = "Failed Nodes", color = "#ff0000" }]
          ]
          period = 300
        }
      },

      # Row 3: EC2 Status Check
      {
        type   = "metric"
        x      = 0
        y      = 8
        width  = 12
        height = 4
        properties = {
          title   = "EC2 Status Check Failed"
          region  = var.aws_region
          view    = "singleValue"
          stacked = true
          metrics = [
            ["AWS/EC2", "StatusCheckFailed", { stat = "Sum", label = "Status Check Failed" }],
            ["AWS/EC2", "StatusCheckFailed_Instance", { stat = "Sum", label = "Instance Check Failed" }],
            ["AWS/EC2", "StatusCheckFailed_System", { stat = "Sum", label = "System Check Failed" }]
          ]
          period = 60
        }
      },

      # Row 4: Pod Metrics
      {
        type   = "text"
        x      = 0
        y      = 12
        width  = 24
        height = 1
        properties = {
          markdown = "## 🐳 Container/Pod Metrics"
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 13
        width  = 8
        height = 6
        properties = {
          title  = "Pod CPU Utilization"
          region = var.aws_region
          view   = "gauge"
          metrics = [
            ["ContainerInsights", "pod_cpu_utilization", "ClusterName", var.eks_cluster_name, { stat = "Average" }]
          ]
          period = 300
          yAxis = {
            left = { min = 0, max = 100 }
          }
          annotations = {
            horizontal = [{
              value = var.pod_cpu_threshold
              label = "Threshold"
              color = "#ff0000"
            }]
          }
        }
      },
      {
        type   = "metric"
        x      = 8
        y      = 13
        width  = 8
        height = 6
        properties = {
          title  = "Pod Memory Utilization"
          region = var.aws_region
          view   = "gauge"
          metrics = [
            ["ContainerInsights", "pod_memory_utilization", "ClusterName", var.eks_cluster_name, { stat = "Average" }]
          ]
          period = 300
          yAxis = {
            left = { min = 0, max = 100 }
          }
          annotations = {
            horizontal = [{
              value = var.pod_memory_threshold
              label = "Threshold"
              color = "#ff0000"
            }]
          }
        }
      },
      {
        type   = "metric"
        x      = 16
        y      = 13
        width  = 8
        height = 6
        properties = {
          title  = "Pod Restart Count (Auto Recovery Trigger)"
          region = var.aws_region
          metrics = [
            ["ContainerInsights", "pod_number_of_container_restarts", "ClusterName", var.eks_cluster_name, { stat = "Sum", color = "#ff0000" }]
          ]
          period = 300
          annotations = {
            horizontal = [{
              value = var.pod_restart_threshold
              label = "Auto Recovery Threshold"
              color = "#ff0000"
            }]
          }
        }
      },

      # Row 5: ALB Metrics
      {
        type   = "text"
        x      = 0
        y      = 19
        width  = 24
        height = 1
        properties = {
          markdown = "## 🌐 ALB Metrics"
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 20
        width  = 6
        height = 6
        properties = {
          title  = "Request Count"
          region = var.aws_region
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", var.alb_arn_suffix, { stat = "Sum" }]
          ]
          period = 60
        }
      },
      {
        type   = "metric"
        x      = 6
        y      = 20
        width  = 6
        height = 6
        properties = {
          title  = "HTTP 5XX Errors"
          region = var.aws_region
          metrics = [
            ["AWS/ApplicationELB", "HTTPCode_ELB_5XX_Count", "LoadBalancer", var.alb_arn_suffix, { stat = "Sum", label = "ELB 5XX", color = "#ff0000" }],
            ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", var.alb_arn_suffix, { stat = "Sum", label = "Target 5XX", color = "#ff9900" }]
          ]
          period = 300
          annotations = {
            horizontal = [{
              value = var.http_5xx_threshold
              label = "Threshold"
              color = "#ff0000"
            }]
          }
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 20
        width  = 6
        height = 6
        properties = {
          title  = "Target Response Time (Latency)"
          region = var.aws_region
          metrics = [
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", var.alb_arn_suffix, { stat = "p50", label = "p50" }],
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", var.alb_arn_suffix, { stat = "p95", label = "p95", color = "#ff9900" }],
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", var.alb_arn_suffix, { stat = "p99", label = "p99", color = "#ff0000" }]
          ]
          period = 300
          annotations = {
            horizontal = [{
              value = var.latency_threshold
              label = "Threshold"
              color = "#ff0000"
            }]
          }
        }
      },
      {
        type   = "metric"
        x      = 18
        y      = 20
        width  = 6
        height = 6
        properties = {
          title  = "Rejected Connections"
          region = var.aws_region
          metrics = [
            ["AWS/ApplicationELB", "RejectedConnectionCount", "LoadBalancer", var.alb_arn_suffix, { stat = "Sum", color = "#ff9900" }]
          ]
          period = 60
          annotations = {
            horizontal = [{
              value = var.surge_queue_threshold
              label = "Threshold"
              color = "#ff0000"
            }]
          }
        }
      },

      # Row 6: Healthy/Unhealthy Hosts
      {
        type   = "metric"
        x      = 0
        y      = 26
        width  = 12
        height = 4
        properties = {
          title  = "Target Health Status"
          region = var.aws_region
          metrics = [
            ["AWS/ApplicationELB", "HealthyHostCount", "TargetGroup", var.target_group_arn_suffix, "LoadBalancer", var.alb_arn_suffix, { stat = "Average", label = "Healthy", color = "#2ca02c" }],
            ["AWS/ApplicationELB", "UnHealthyHostCount", "TargetGroup", var.target_group_arn_suffix, "LoadBalancer", var.alb_arn_suffix, { stat = "Average", label = "Unhealthy", color = "#ff0000" }]
          ]
          period = 60
        }
      },

      # Row 7: RDS Metrics
      {
        type   = "text"
        x      = 0
        y      = 30
        width  = 24
        height = 1
        properties = {
          markdown = "## 🗄️ RDS Database Metrics"
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 31
        width  = 6
        height = 6
        properties = {
          title  = "RDS CPU Utilization"
          region = var.aws_region
          view   = "gauge"
          metrics = [
            ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", var.rds_instance_identifier, { stat = "Average" }]
          ]
          period = 300
          yAxis = {
            left = { min = 0, max = 100 }
          }
          annotations = {
            horizontal = [{
              value = var.cpu_threshold
              label = "Threshold"
              color = "#ff0000"
            }]
          }
        }
      },
      {
        type   = "metric"
        x      = 6
        y      = 31
        width  = 6
        height = 6
        properties = {
          title  = "Free Storage Space (GB)"
          region = var.aws_region
          metrics = [
            ["AWS/RDS", "FreeStorageSpace", "DBInstanceIdentifier", var.rds_instance_identifier, { stat = "Average" }]
          ]
          period = 300
          annotations = {
            horizontal = [{
              value = var.rds_storage_threshold * 1024 * 1024 * 1024
              label = "Threshold"
              color = "#ff0000"
            }]
          }
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 31
        width  = 6
        height = 6
        properties = {
          title  = "Database Connections"
          region = var.aws_region
          metrics = [
            ["AWS/RDS", "DatabaseConnections", "DBInstanceIdentifier", var.rds_instance_identifier, { stat = "Average" }]
          ]
          period = 300
          annotations = {
            horizontal = [{
              value = var.rds_connections_threshold
              label = "Threshold"
              color = "#ff0000"
            }]
          }
        }
      },
      {
        type   = "metric"
        x      = 18
        y      = 31
        width  = 6
        height = 6
        properties = {
          title  = "Disk Queue Depth"
          region = var.aws_region
          metrics = [
            ["AWS/RDS", "DiskQueueDepth", "DBInstanceIdentifier", var.rds_instance_identifier, { stat = "Average" }]
          ]
          period = 300
          annotations = {
            horizontal = [{
              value = var.rds_disk_queue_threshold
              label = "Threshold"
              color = "#ff0000"
            }]
          }
        }
      },

      # Row 7.5: RDS Latency & Memory
      {
        type   = "metric"
        x      = 0
        y      = 37
        width  = 6
        height = 6
        properties = {
          title  = "RDS Read/Write Latency (p90)"
          region = var.aws_region
          metrics = [
            ["AWS/RDS", "ReadLatency", "DBInstanceIdentifier", var.rds_instance_identifier, { stat = "p90", label = "Read p90" }],
            ["AWS/RDS", "WriteLatency", "DBInstanceIdentifier", var.rds_instance_identifier, { stat = "p90", label = "Write p90", color = "#ff9900" }]
          ]
          period = 300
          annotations = {
            horizontal = [{
              value = var.rds_latency_threshold
              label = "Threshold (100ms)"
              color = "#ff0000"
            }]
          }
        }
      },
      {
        type   = "metric"
        x      = 6
        y      = 37
        width  = 6
        height = 6
        properties = {
          title  = "RDS Freeable Memory"
          region = var.aws_region
          metrics = [
            ["AWS/RDS", "FreeableMemory", "DBInstanceIdentifier", var.rds_instance_identifier, { stat = "Average" }]
          ]
          period = 300
          annotations = {
            horizontal = [{
              value = var.rds_freeable_memory_threshold
              label = "Threshold (25%)"
              color = "#ff0000"
            }]
          }
        }
      },

      # Row 7.7: RDS Enhanced Monitoring
      {
        type   = "text"
        x      = 0
        y      = 43
        width  = 24
        height = 1
        properties = {
          markdown = "## 🔍 RDS Enhanced Monitoring (OS-Level Metrics)"
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 44
        width  = 8
        height = 6
        properties = {
          title  = "RDS Read/Write IOPS"
          region = var.aws_region
          metrics = [
            ["AWS/RDS", "ReadIOPS", "DBInstanceIdentifier", var.rds_instance_identifier, { stat = "Average", label = "Read IOPS", color = "#2ca02c" }],
            ["AWS/RDS", "WriteIOPS", "DBInstanceIdentifier", var.rds_instance_identifier, { stat = "Average", label = "Write IOPS", color = "#ff9900" }]
          ]
          period = 60
          yAxis = {
            left = { min = 0 }
          }
        }
      },
      {
        type   = "metric"
        x      = 8
        y      = 44
        width  = 8
        height = 6
        properties = {
          title  = "RDS Read/Write Throughput"
          region = var.aws_region
          metrics = [
            ["AWS/RDS", "ReadThroughput", "DBInstanceIdentifier", var.rds_instance_identifier, { stat = "Average", label = "Read Throughput", color = "#2ca02c" }],
            ["AWS/RDS", "WriteThroughput", "DBInstanceIdentifier", var.rds_instance_identifier, { stat = "Average", label = "Write Throughput", color = "#ff9900" }]
          ]
          period = 60
          yAxis = {
            left = { min = 0 }
          }
        }
      },
      {
        type   = "metric"
        x      = 16
        y      = 44
        width  = 8
        height = 6
        properties = {
          title  = "RDS Network Throughput"
          region = var.aws_region
          metrics = [
            ["AWS/RDS", "NetworkReceiveThroughput", "DBInstanceIdentifier", var.rds_instance_identifier, { stat = "Average", label = "Network RX", color = "#2ca02c" }],
            ["AWS/RDS", "NetworkTransmitThroughput", "DBInstanceIdentifier", var.rds_instance_identifier, { stat = "Average", label = "Network TX", color = "#ff9900" }]
          ]
          period = 60
          yAxis = {
            left = { min = 0 }
          }
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 50
        width  = 8
        height = 6
        properties = {
          title  = "RDS Database Connections"
          region = var.aws_region
          view   = "timeSeries"
          metrics = [
            ["AWS/RDS", "DatabaseConnections", "DBInstanceIdentifier", var.rds_instance_identifier, { stat = "Average", label = "Active Connections" }]
          ]
          period = 60
          yAxis = {
            left = { min = 0 }
          }
          annotations = {
            horizontal = [{
              value = var.rds_connections_threshold
              label = "Threshold"
              color = "#ff0000"
            }]
          }
        }
      },
      {
        type   = "metric"
        x      = 8
        y      = 50
        width  = 8
        height = 6
        properties = {
          title  = "RDS Swap Usage"
          region = var.aws_region
          view   = "timeSeries"
          metrics = [
            ["AWS/RDS", "SwapUsage", "DBInstanceIdentifier", var.rds_instance_identifier, { stat = "Average", label = "Swap Usage" }]
          ]
          period = 60
          yAxis = {
            left = { min = 0 }
          }
        }
      },
      {
        type   = "metric"
        x      = 16
        y      = 50
        width  = 8
        height = 6
        properties = {
          title  = "RDS LVM IOPS"
          region = var.aws_region
          metrics = [
            ["AWS/RDS", "LVMReadIOPS", "DBInstanceIdentifier", var.rds_instance_identifier, { stat = "Average", label = "LVM Read IOPS", color = "#2ca02c" }],
            ["AWS/RDS", "LVMWriteIOPS", "DBInstanceIdentifier", var.rds_instance_identifier, { stat = "Average", label = "LVM Write IOPS", color = "#ff9900" }]
          ]
          period = 60
          yAxis = {
            left = { min = 0 }
          }
        }
      },

      # Row 8: Route53 Health Check Metrics
      {
        type   = "text"
        x      = 0
        y      = 56
        width  = 24
        height = 1
        properties = {
          markdown = "## Route53 Health Check & Failover Status"
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 57
        width  = 6
        height = 6
        properties = {
          title   = "AWS ALB Direct Health Check"
          region  = "us-east-1"
          view    = "singleValue"
          stacked = true
          metrics = var.aws_alb_health_check_id != "" ? [
            ["AWS/Route53", "HealthCheckStatus", "HealthCheckId", var.aws_alb_health_check_id, { stat = "Minimum", label = "ALB Status (1=Healthy)", color = "#1f77b4" }]
          ] : []
          period = 60
          yAxis = {
            left = { min = 0, max = 1 }
          }
          annotations = {
            horizontal = [{
              value = 1
              label = "Healthy"
              color = "#2ca02c"
            }]
          }
        }
      },
      {
        type   = "metric"
        x      = 6
        y      = 57
        width  = 6
        height = 6
        properties = {
          title   = "CloudFront (End-to-End) Health Check"
          region  = "us-east-1"
          view    = "singleValue"
          stacked = true
          metrics = var.primary_health_check_id != "" ? [
            ["AWS/Route53", "HealthCheckStatus", "HealthCheckId", var.primary_health_check_id, { stat = "Minimum", label = "Health Status (1=Healthy)", color = "#2ca02c" }]
          ] : []
          period = 60
          yAxis = {
            left = { min = 0, max = 1 }
          }
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 57
        width  = 6
        height = 6
        properties = {
          title  = "Azure Blob Storage Health Check"
          region = "us-east-1"
          metrics = var.secondary_health_check_id != "" ? [
            ["AWS/Route53", "HealthCheckStatus", "HealthCheckId", var.secondary_health_check_id, { stat = "Minimum", label = "Health Status (1=Healthy)", color = "#ff9900" }]
          ] : []
          period = 60
          yAxis = {
            left = { min = 0, max = 1 }
          }
          view = "singleValue"
        }
      },
      {
        type   = "metric"
        x      = 18
        y      = 57
        width  = 6
        height = 6
        properties = {
          title  = "Health Check Percentage"
          region = "us-east-1"
          metrics = concat(
            var.aws_alb_health_check_id != "" ? [
              ["AWS/Route53", "HealthCheckPercentageHealthy", "HealthCheckId", var.aws_alb_health_check_id, { stat = "Average", label = "AWS ALB", color = "#1f77b4" }]
            ] : [],
            var.primary_health_check_id != "" ? [
              ["AWS/Route53", "HealthCheckPercentageHealthy", "HealthCheckId", var.primary_health_check_id, { stat = "Average", label = "CloudFront", color = "#2ca02c" }]
            ] : [],
            var.secondary_health_check_id != "" ? [
              ["AWS/Route53", "HealthCheckPercentageHealthy", "HealthCheckId", var.secondary_health_check_id, { stat = "Average", label = "Azure Blob", color = "#ff9900" }]
            ] : []
          )
          period = 60
          yAxis = {
            left = { min = 0, max = 100 }
          }
          view = "singleValue"
          annotations = {
            horizontal = [{
              value = 50
              label = "Failover Threshold"
              color = "#ff0000"
            }]
          }
        }
      },

      # Row 9: Detailed Container Metrics
      {
        type   = "text"
        x      = 0
        y      = 63
        width  = 24
        height = 1
        properties = {
          markdown = "## Detailed Container Metrics"
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 64
        width  = 6
        height = 6
        properties = {
          title  = "Container CPU Utilization"
          region = var.aws_region
          metrics = [
            ["ContainerInsights", "container_cpu_utilization", "ClusterName", var.eks_cluster_name, { stat = "Average" }]
          ]
          period = 300
          yAxis = {
            left = { min = 0, max = 100 }
          }
          view = "gauge"
          annotations = {
            horizontal = [{
              value = var.container_cpu_threshold
              label = "Threshold"
              color = "#ff0000"
            }]
          }
        }
      },
      {
        type   = "metric"
        x      = 6
        y      = 64
        width  = 6
        height = 6
        properties = {
          title  = "Container Memory Utilization"
          region = var.aws_region
          metrics = [
            ["ContainerInsights", "container_memory_utilization", "ClusterName", var.eks_cluster_name, { stat = "Average" }]
          ]
          period = 300
          yAxis = {
            left = { min = 0, max = 100 }
          }
          view = "gauge"
          annotations = {
            horizontal = [{
              value = var.container_memory_threshold
              label = "Threshold"
              color = "#ff0000"
            }]
          }
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 64
        width  = 6
        height = 6
        properties = {
          title  = "Pod Network I/O"
          region = var.aws_region
          metrics = [
            ["ContainerInsights", "pod_network_rx_bytes", "ClusterName", var.eks_cluster_name, { stat = "Average", label = "RX (bytes/sec)", color = "#2ca02c" }],
            ["ContainerInsights", "pod_network_tx_bytes", "ClusterName", var.eks_cluster_name, { stat = "Average", label = "TX (bytes/sec)", color = "#ff9900" }]
          ]
          period = 300
        }
      },
      {
        type   = "metric"
        x      = 18
        y      = 64
        width  = 6
        height = 6
        properties = {
          title  = "Running Pods & Services"
          region = var.aws_region
          metrics = [
            ["ContainerInsights", "cluster_number_of_running_pods", "ClusterName", var.eks_cluster_name, { stat = "Average", label = "Running Pods", color = "#2ca02c" }],
            ["ContainerInsights", "service_number_of_running_pods", "ClusterName", var.eks_cluster_name, { stat = "Average", label = "Service Pods", color = "#1f77b4" }]
          ]
          period = 300
        }
      },

      # Row 10: Alarm Status
      {
        type   = "text"
        x      = 0
        y      = 57
        width  = 24
        height = 1
        properties = {
          markdown = "## Alarm Status & Auto Recovery"
        }
      },
      {
        type   = "alarm"
        x      = 0
        y      = 58
        width  = 12
        height = 4
        properties = {
          title = "Infrastructure Alarms"
          alarms = [
            aws_cloudwatch_metric_alarm.node_cpu_high.arn,
            aws_cloudwatch_metric_alarm.node_memory_high.arn,
            aws_cloudwatch_metric_alarm.node_disk_high.arn,
            aws_cloudwatch_metric_alarm.node_status_check_failed.arn,
            aws_cloudwatch_metric_alarm.node_count_low.arn
          ]
        }
      },
      {
        type   = "alarm"
        x      = 12
        y      = 58
        width  = 12
        height = 4
        properties = {
          title = "Application & Database Alarms"
          alarms = concat(
            [
              aws_cloudwatch_metric_alarm.pod_cpu_high.arn,
              aws_cloudwatch_metric_alarm.pod_memory_high.arn,
              aws_cloudwatch_metric_alarm.pod_restart_high.arn,
              aws_cloudwatch_metric_alarm.container_cpu_high.arn,
              aws_cloudwatch_metric_alarm.container_memory_high.arn
            ],
            var.rds_instance_identifier != "" ? [
              aws_cloudwatch_metric_alarm.rds_read_latency_high[0].arn,
              aws_cloudwatch_metric_alarm.rds_write_latency_high[0].arn,
              aws_cloudwatch_metric_alarm.rds_memory_low[0].arn
            ] : []
          )
        }
      }
    ]
  })
}

# Adopt log groups created by the EKS Observability add-on before monitoring apply.
data "aws_cloudwatch_log_groups" "container_insights" {
  log_group_name_prefix = "/aws/containerinsights/${var.eks_cluster_name}/"
}

import {
  for_each = toset([for name in data.aws_cloudwatch_log_groups.container_insights.log_group_names : name if name == "/aws/containerinsights/${var.eks_cluster_name}/performance"])
  to       = aws_cloudwatch_log_group.container_insights
  id       = each.value
}

import {
  for_each = toset([for name in data.aws_cloudwatch_log_groups.container_insights.log_group_names : name if name == "/aws/containerinsights/${var.eks_cluster_name}/application"])
  to       = aws_cloudwatch_log_group.application
  id       = each.value
}
