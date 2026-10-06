mock_provider "aws" {
  mock_data "aws_route53_zone" {
    defaults = { zone_id = "Z123456789" }
  }
  mock_data "aws_lb" {
    defaults = {
      dns_name = "test-alb.ap-northeast-2.elb.amazonaws.com"
      zone_id  = "Z123456789"
    }
  }
}
mock_provider "aws" {
  alias = "us_east_1"
  mock_data "aws_acm_certificate" {
    defaults = { arn = "arn:aws:acm:us-east-1:123456789012:certificate/11111111-1111-1111-1111-111111111111" }
  }
}
variables {
  domain_name                 = "example.com"
  eks_cluster_name            = "test-eks"
  azure_frontdoor_domain_name = "test.azurefd.net"
}
run "normal_allows_writes_and_keeps_failover" {
  command = plan
  assert {
    condition     = contains(aws_cloudfront_distribution.main[0].default_cache_behavior[0].allowed_methods, "POST") && aws_cloudfront_distribution.main[0].default_cache_behavior[0].target_origin_id == "multi-cloud-failover-group"
    error_message = "Normal mode must forward writes to AWS while retaining origin failover."
  }
}
run "dr_routes_writes_to_frontdoor" {
  command = plan
  variables { traffic_mode = "azure_dr" }
  assert {
    condition     = aws_cloudfront_distribution.main[0].default_cache_behavior[0].target_origin_id == "azure-frontdoor-dr" && contains(aws_cloudfront_distribution.main[0].default_cache_behavior[0].allowed_methods, "POST")
    error_message = "DR must route writes directly to Front Door."
  }
}
run "disabled_edge" {
  command = plan
  variables { enable_custom_domain = false }
  assert {
    condition     = length(aws_cloudfront_distribution.main) == 0
    error_message = "Disabled edge should create no distribution."
  }
}
