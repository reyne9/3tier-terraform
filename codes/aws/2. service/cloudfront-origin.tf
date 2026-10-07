# Only CloudFront origin-facing addresses can open the public ALB listener.
# The AWS Load Balancer Controller attaches this security group by its Name tag.
data "aws_ec2_managed_prefix_list" "cloudfront_origin" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

resource "aws_security_group" "cloudfront_origin" {
  name        = "portfolio-cloudfront-origin"
  description = "CloudFront origin-facing access to the PetClinic ALB"
  vpc_id      = module.vpc.vpc_id

  tags = {
    Name = "portfolio-cloudfront-origin"
  }
}

resource "aws_vpc_security_group_ingress_rule" "cloudfront_http" {
  security_group_id = aws_security_group.cloudfront_origin.id
  prefix_list_id    = data.aws_ec2_managed_prefix_list.cloudfront_origin.id
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  description       = "CloudFront origin-facing HTTP"
}

resource "aws_vpc_security_group_egress_rule" "cloudfront_to_web" {
  security_group_id = aws_security_group.cloudfront_origin.id
  cidr_ipv4         = var.aws_vpc_cidr
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  description       = "ALB to private web targets"
}
