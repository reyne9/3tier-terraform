# aws/monitoring/outputs.tf
# 모니터링 모듈 출력 정의

# =================================================
# SNS Topic Outputs
# =================================================

output "sns_topic_arn" {
  description = "SNS 알림 토픽 ARN"
  value       = aws_sns_topic.alerts.arn
}

output "sns_topic_name" {
  description = "SNS 알림 토픽 이름"
  value       = aws_sns_topic.alerts.name
}

# =================================================
# CloudWatch Dashboard Outputs
# =================================================

output "dashboard_name" {
  description = "CloudWatch 대시보드 이름"
  value       = aws_cloudwatch_dashboard.eks_monitoring.dashboard_name
}

output "dashboard_arn" {
  description = "CloudWatch 대시보드 ARN"
  value       = aws_cloudwatch_dashboard.eks_monitoring.dashboard_arn
}

output "dashboard_url" {
  description = "CloudWatch 대시보드 URL"
  value       = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards:name=${aws_cloudwatch_dashboard.eks_monitoring.dashboard_name}"
}

# =================================================
# CloudWatch Log Group Outputs
# =================================================

output "container_insights_log_group" {
  description = "Container Insights 로그 그룹 이름"
  value       = aws_cloudwatch_log_group.container_insights.name
}

output "application_log_group" {
  description = "애플리케이션 로그 그룹 이름"
  value       = aws_cloudwatch_log_group.application.name
}

# =================================================
# Lambda Function Outputs
# =================================================

output "auto_recovery_lambda_arn" {
  description = "자동 복구 Lambda 함수 ARN"
  value       = aws_lambda_function.auto_recovery.arn
}

output "auto_recovery_lambda_name" {
  description = "자동 복구 Lambda 함수 이름"
  value       = aws_lambda_function.auto_recovery.function_name
}

# =================================================
# Alarm ARNs
# =================================================

output "alarm_arns" {
  description = "생성된 모든 알람 ARN 목록"
  value = {
    # Node Level
    node_cpu_high            = aws_cloudwatch_metric_alarm.node_cpu_high.arn
    node_memory_high         = aws_cloudwatch_metric_alarm.node_memory_high.arn
    node_disk_high           = aws_cloudwatch_metric_alarm.node_disk_high.arn
    node_status_check_failed = aws_cloudwatch_metric_alarm.node_status_check_failed.arn
    node_count_low           = aws_cloudwatch_metric_alarm.node_count_low.arn

    # Pod Level
    pod_cpu_high        = aws_cloudwatch_metric_alarm.pod_cpu_high.arn
    pod_memory_high     = aws_cloudwatch_metric_alarm.pod_memory_high.arn
    pod_restart_high    = aws_cloudwatch_metric_alarm.pod_restart_high.arn
    pod_network_rx_high = aws_cloudwatch_metric_alarm.pod_network_rx_high.arn
    pod_network_tx_high = aws_cloudwatch_metric_alarm.pod_network_tx_high.arn

    # Container Level
    container_cpu_high    = aws_cloudwatch_metric_alarm.container_cpu_high.arn
    container_memory_high = aws_cloudwatch_metric_alarm.container_memory_high.arn
    service_count_low     = aws_cloudwatch_metric_alarm.service_count_low.arn

    # ALB
    alb_surge_queue  = var.alb_name != "" ? aws_cloudwatch_metric_alarm.alb_surge_queue[0].arn : null
    alb_5xx_errors   = var.alb_name != "" ? aws_cloudwatch_metric_alarm.alb_5xx_errors[0].arn : null
    alb_latency_high = var.alb_name != "" ? aws_cloudwatch_metric_alarm.alb_latency_high[0].arn : null

    # RDS
    rds_storage_low      = var.rds_instance_identifier != "" ? aws_cloudwatch_metric_alarm.rds_storage_low[0].arn : null
    rds_connections_high = var.rds_instance_identifier != "" ? aws_cloudwatch_metric_alarm.rds_connections_high[0].arn : null
    rds_disk_queue_high  = var.rds_instance_identifier != "" ? aws_cloudwatch_metric_alarm.rds_disk_queue_high[0].arn : null
    rds_cpu_high         = var.rds_instance_identifier != "" ? aws_cloudwatch_metric_alarm.rds_cpu_high[0].arn : null

    # Route53 Health Check
    route53_primary_health   = var.enable_route53_monitoring && var.primary_health_check_id != "" ? aws_cloudwatch_metric_alarm.route53_primary_health[0].arn : null
    route53_secondary_health = var.enable_route53_monitoring && var.secondary_health_check_id != "" ? aws_cloudwatch_metric_alarm.route53_secondary_health[0].arn : null
    route53_aws_alb_health   = var.enable_route53_monitoring && var.aws_alb_health_check_id != "" ? aws_cloudwatch_metric_alarm.route53_aws_alb_health[0].arn : null
  }
}

# =================================================
# Route53 Health Check Outputs
# =================================================

output "route53_alarms" {
  description = "Route53 Health Check 알람 정보"
  value = {
    primary_health_alarm       = var.enable_route53_monitoring && var.primary_health_check_id != "" ? aws_cloudwatch_metric_alarm.route53_primary_health[0].arn : null
    secondary_health_alarm     = var.enable_route53_monitoring && var.secondary_health_check_id != "" ? aws_cloudwatch_metric_alarm.route53_secondary_health[0].arn : null
    aws_alb_health_alarm       = var.enable_route53_monitoring && var.aws_alb_health_check_id != "" ? aws_cloudwatch_metric_alarm.route53_aws_alb_health[0].arn : null
    primary_percentage_alarm   = var.enable_route53_monitoring && var.primary_health_check_id != "" ? aws_cloudwatch_metric_alarm.route53_primary_percentage[0].arn : null
    secondary_percentage_alarm = var.enable_route53_monitoring && var.secondary_health_check_id != "" ? aws_cloudwatch_metric_alarm.route53_secondary_percentage[0].arn : null
    all_sites_down_alarm       = var.enable_route53_monitoring && var.primary_health_check_id != "" && var.secondary_health_check_id != "" ? aws_cloudwatch_composite_alarm.all_sites_down[0].arn : null
  }
}

# =================================================
# Container/Pod Alarm Outputs
# =================================================

output "container_alarms" {
  description = "컨테이너 레벨 알람 정보"
  value = {
    container_cpu_high    = aws_cloudwatch_metric_alarm.container_cpu_high.arn
    container_memory_high = aws_cloudwatch_metric_alarm.container_memory_high.arn
    pod_network_rx_high   = aws_cloudwatch_metric_alarm.pod_network_rx_high.arn
    pod_network_tx_high   = aws_cloudwatch_metric_alarm.pod_network_tx_high.arn
    service_count_low     = aws_cloudwatch_metric_alarm.service_count_low.arn
  }
}
