# aws/main.tf
# AWS Primary Site 인프라 구성

terraform {
  required_version = ">= 1.14.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

# AWS 프로바이더 초기화
provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Environment = var.environment
      Project     = "Multi-Cloud-DR"
      ManagedBy   = "Terraform"
      Site        = "Primary"
    }
  }
}

# =================================================
# AWS VPC 및 네트워크
# =================================================

module "vpc" {
  source = "./modules/vpc"

  environment        = var.environment
  vpc_cidr           = var.aws_vpc_cidr
  availability_zones = var.aws_availability_zones

  public_subnet_cidrs = var.public_subnet_cidrs
  web_subnet_cidrs    = var.web_subnet_cidrs
  was_subnet_cidrs    = var.was_subnet_cidrs
  rds_subnet_cidrs    = var.rds_subnet_cidrs
}


# =================================================
# AWS EKS 클러스터 (Web/WAS Tier)
# =================================================

module "eks" {
  source = "./modules/eks"

  environment        = var.environment
  vpc_id             = module.vpc.vpc_id
  web_subnet_ids     = module.vpc.web_subnet_ids
  was_subnet_ids     = module.vpc.was_subnet_ids
  node_instance_type = var.eks_node_instance_type

  # Web Tier 노드 그룹 설정
  web_desired_size = var.eks_web_desired_size
  web_min_size     = var.eks_web_min_size
  web_max_size     = var.eks_web_max_size

  # WAS Tier 노드 그룹 설정
  was_desired_size = var.eks_was_desired_size
  was_min_size     = var.eks_was_min_size
  was_max_size     = var.eks_was_max_size

  depends_on = [module.vpc]
}

resource "aws_ec2_tag" "karpenter_cluster_security_group" {
  resource_id = module.eks.cluster_security_group_id
  key         = "karpenter.sh/discovery"
  value       = module.eks.cluster_name
}


# =================================================
# AWS RDS MySQL (Multi-AZ)
# =================================================


module "rds" {
  source = "./modules/rds"

  environment           = var.environment
  vpc_id                = module.vpc.vpc_id
  subnet_ids            = module.vpc.rds_subnet_ids
  eks_security_group_id = module.eks.cluster_security_group_id

  database_name   = var.db_name
  master_username = var.db_username
  master_password = var.db_password

  instance_class        = var.rds_instance_class
  allocated_storage     = var.rds_allocated_storage
  max_allocated_storage = var.rds_max_allocated_storage

  backup_retention_period = var.rds_backup_retention
  multi_az                = var.rds_multi_az
  skip_final_snapshot     = var.rds_skip_final_snapshot
  deletion_protection     = var.rds_deletion_protection

  # Enhanced Monitoring 활성화
  enhanced_monitoring_enabled = true
  monitoring_interval         = 60 # 60초 간격으로 수집
}



# =================================================
# 데이터 소스
# =================================================

data "aws_caller_identity" "current" {}

# OIDC Provider for EKS (IAM Role 연동용)
resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list = ["sts.amazonaws.com"]
  # EKS OIDC thumbprint (ap-northeast-2 리전의 고정값)
  thumbprint_list = ["9e99a48a9960b14926bb7f3b02e22da2b0ab7280"]
  url             = module.eks.oidc_provider_url

  tags = {
    Name = "${var.environment}-eks-oidc"
  }
}
