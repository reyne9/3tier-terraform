# aws/route53/outputs.tf
# CloudFront + Route53 배포 정보

# =================================================
# Route53 정보
# =================================================

output "route53_zone_id" {
  description = "Route53 Hosted Zone ID"
  value       = var.enable_custom_domain ? data.aws_route53_zone.main[0].zone_id : ""
}

output "route53_zone_name" {
  description = "Route53 Hosted Zone 이름"
  value       = var.enable_custom_domain ? data.aws_route53_zone.main[0].name : ""
}

output "dns_record" {
  description = "Route53 DNS 레코드 정보"
  value = var.enable_custom_domain && local.alb_dns_name != null ? {
    domain = var.domain_name
    type   = "A (Alias to CloudFront)"
    target = aws_cloudfront_distribution.main[0].domain_name
    status = "Active"
    } : {
    status = "Not configured"
  }
}

# =================================================
# CloudFront 정보
# =================================================

output "cloudfront_distribution_id" {
  description = "CloudFront Distribution ID"
  value       = var.enable_custom_domain && local.alb_dns_name != null ? aws_cloudfront_distribution.main[0].id : ""
}

output "cloudfront_domain_name" {
  description = "CloudFront Domain Name (CDN endpoint)"
  value       = var.enable_custom_domain && local.alb_dns_name != null ? aws_cloudfront_distribution.main[0].domain_name : ""
}

output "cloudfront_url" {
  description = "CloudFront HTTPS URL"
  value       = var.enable_custom_domain && local.alb_dns_name != null ? "https://${var.domain_name}" : ""
}

output "cloudfront_status" {
  description = "CloudFront Distribution 상태"
  value       = var.enable_custom_domain && local.alb_dns_name != null ? aws_cloudfront_distribution.main[0].status : "Not deployed"
}

# =================================================
# Origin Failover 설정 정보
# =================================================

output "origin_failover_config" {
  description = "CloudFront Origin Failover 구성"
  value = var.enable_custom_domain && local.alb_dns_name != null ? {
    traffic_mode     = var.traffic_mode
    failover_enabled = var.traffic_mode == "normal"
    primary_origin   = local.alb_dns_name
    secondary_origin = local.azure_frontdoor_domain_name
    failover_codes   = [500, 502, 503, 504]
    origin_group_id  = "multi-cloud-failover-group"
    active_origin_id = var.traffic_mode == "azure_dr" ? "azure-frontdoor-dr" : "multi-cloud-failover-group"
    allowed_methods  = var.traffic_mode == "azure_dr" ? ["GET", "HEAD", "OPTIONS", "PUT", "PATCH", "POST", "DELETE"] : ["GET", "HEAD"]
    } : {
    failover_enabled = false
    message          = "Custom domain is disabled or ALB not configured"
  }
}

output "ssl_certificate_info" {
  description = "SSL 인증서 정보"
  value = var.enable_custom_domain && length(data.aws_acm_certificate.main) > 0 ? {
    arn              = data.aws_acm_certificate.main[0].arn
    domain           = data.aws_acm_certificate.main[0].domain
    status           = data.aws_acm_certificate.main[0].status
    https_enabled    = true
    certificate_type = "ACM (us-east-1)"
    } : {
    https_enabled = false
    message       = "ACM certificate not found in us-east-1"
  }
}

# =================================================
# 관리 명령어
# =================================================

output "management_commands" {
  description = "CloudFront 관리 명령어"
  value = var.enable_custom_domain && local.alb_dns_name != null ? {
    cache_invalidation = "aws cloudfront create-invalidation --distribution-id ${aws_cloudfront_distribution.main[0].id} --paths '/*'"
    get_distribution   = "aws cloudfront get-distribution --id ${aws_cloudfront_distribution.main[0].id}"
    list_invalidations = "aws cloudfront list-invalidations --distribution-id ${aws_cloudfront_distribution.main[0].id}"
    update_origin      = "aws cloudfront get-distribution-config --id ${aws_cloudfront_distribution.main[0].id} > dist-config.json"
  } : {}
}

output "monitoring_commands" {
  description = "모니터링 및 확인 명령어"
  value = var.enable_custom_domain && local.alb_dns_name != null ? {
    dns_lookup       = "dig ${var.domain_name}"
    curl_test        = "curl -I https://${var.domain_name}"
    check_cloudfront = "aws cloudfront get-distribution --id ${aws_cloudfront_distribution.main[0].id} --query 'Distribution.Status'"
    check_origins    = "aws cloudfront get-distribution --id ${aws_cloudfront_distribution.main[0].id} --query 'Distribution.DistributionConfig.Origins'"
  } : {}
}

# =================================================
# Route53 Health Check Outputs
# =================================================

output "health_check_ids" {
  description = "Route53 Health Check ID 목록"
  value = var.enable_custom_domain ? {
    aws_alb_health_check_id         = length(aws_route53_health_check.aws_alb) > 0 ? aws_route53_health_check.aws_alb[0].id : ""
    cloudfront_health_check_id      = length(aws_route53_health_check.cloudfront) > 0 ? aws_route53_health_check.cloudfront[0].id : ""
    azure_frontdoor_health_check_id = length(aws_route53_health_check.azure_frontdoor) > 0 ? aws_route53_health_check.azure_frontdoor[0].id : ""
  } : {}
}

output "health_check_config" {
  description = "Route53 Health Check 구성 정보"
  value = var.enable_custom_domain ? {
    aws_alb = length(aws_route53_health_check.aws_alb) > 0 ? {
      id      = aws_route53_health_check.aws_alb[0].id
      fqdn    = local.alb_dns_name
      type    = "HTTP"
      port    = 80
      purpose = "AWS ALB 직접 모니터링 (페일오버 감지용)"
    } : null
    cloudfront = length(aws_route53_health_check.cloudfront) > 0 ? {
      id      = aws_route53_health_check.cloudfront[0].id
      fqdn    = var.domain_name
      type    = "HTTPS_STR_MATCH"
      port    = 443
      purpose = "CloudFront End-to-End 모니터링"
    } : null
    azure_frontdoor = length(aws_route53_health_check.azure_frontdoor) > 0 ? {
      id      = aws_route53_health_check.azure_frontdoor[0].id
      fqdn    = local.azure_frontdoor_domain_name
      type    = "HTTPS"
      port    = 443
      purpose = "Azure Front Door 점검 페이지/DR 진입점 모니터링"
    } : null
  } : {}
}

output "health_check_commands" {
  description = "Health Check 관리 명령어"
  value = var.enable_custom_domain && length(aws_route53_health_check.aws_alb) > 0 ? {
    check_aws_status        = "aws route53 get-health-check-status --health-check-id ${aws_route53_health_check.aws_alb[0].id}"
    check_cloudfront_status = length(aws_route53_health_check.cloudfront) > 0 ? "aws route53 get-health-check-status --health-check-id ${aws_route53_health_check.cloudfront[0].id}" : ""
    check_frontdoor_status  = length(aws_route53_health_check.azure_frontdoor) > 0 ? "aws route53 get-health-check-status --health-check-id ${aws_route53_health_check.azure_frontdoor[0].id}" : ""
    list_all_checks         = "aws route53 list-health-checks"
  } : {}
}

output "traffic_mode" {
  description = "현재 CloudFront 트래픽 모드"
  value       = var.traffic_mode
}

output "active_traffic_path" {
  description = "현재 사용자 트래픽 경로"
  value = var.traffic_mode == "azure_dr" ? (
    "Route53 -> CloudFront -> Azure Front Door -> Application Gateway -> AKS"
    ) : (
    "Route53 -> CloudFront -> AWS ALB (5xx GET/HEAD: Azure Front Door -> Blob maintenance)"
  )
}

# =================================================
# 배포 요약
# =================================================

output "deployment_summary" {
  description = "배포 요약 정보"
  value       = var.enable_custom_domain && local.alb_dns_name != null ? "CloudFront + Route53 deployment completed" : "Custom domain is disabled or ALB not configured. Please check terraform.tfvars."
}
