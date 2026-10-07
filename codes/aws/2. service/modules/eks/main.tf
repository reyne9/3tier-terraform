# aws/modules/eks/main.tf
# EKS 클러스터 및 노드 그룹 모듈

terraform {
  required_version = ">= 1.14.0"
}

# =================================================
# EKS 삭제 전 Kubernetes 생성 AWS 리소스 정리
# =================================================
# AWS Load Balancer Controller가 생성한 ALB/NLB, Target Group 등을
# EKS 클러스터 삭제 전에 먼저 정리합니다.

resource "null_resource" "cleanup_k8s_resources" {
  triggers = {
    cluster_name = "${var.environment}-eks"
    vpc_id       = var.vpc_id
  }

  depends_on = [aws_eks_node_group.web, aws_eks_node_group.was]

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["/bin/bash", "-c"]
    command     = <<-BASH
      set -euo pipefail
      export KUBECONFIG="$(mktemp)"
      trap 'rm -f "$KUBECONFIG"' EXIT
      AWS_REGION=$${AWS_REGION:-$${AWS_DEFAULT_REGION:-ap-northeast-2}}
      aws eks update-kubeconfig --name "${self.triggers.cluster_name}" --region "$AWS_REGION" >/dev/null
      kubectl delete ingress --all --all-namespaces --wait=true --timeout=300s
      while read -r namespace name; do
        kubectl delete service "$name" -n "$namespace" --wait=true --timeout=300s
      done < <(kubectl get services --all-namespaces -o json | jq -r '.items[] | select(.spec.type == "LoadBalancer") | [.metadata.namespace, .metadata.name] | @tsv')
      # Controller finalizers remove cloud LBs; do not force-detach managed ENIs.
      for attempt in $(seq 1 60); do
        count=$(aws elbv2 describe-load-balancers --region "$AWS_REGION" \
          --query "length(LoadBalancers[?VpcId=='${self.triggers.vpc_id}'])" --output text)
        [ "$count" = "0" ] && exit 0
        sleep 10
      done
      echo "Load balancers remain in the VPC. Resolve them before retrying destroy." >&2
      exit 1
    BASH
  }
}

# =================================================
# EKS 클러스터 IAM Role
# =================================================

resource "aws_iam_role" "eks_cluster" {
  name = "${var.environment}-eks-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "eks.amazonaws.com"
      }
    }]
  })

  tags = {
    Name        = "${var.environment}-eks-cluster-role"
    Environment = var.environment
  }
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks_cluster.name
}

resource "aws_iam_role_policy_attachment" "eks_vpc_resource_controller" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSVPCResourceController"
  role       = aws_iam_role.eks_cluster.name
}

# =================================================
# EKS 클러스터
# =================================================

resource "aws_eks_cluster" "main" {
  name     = "${var.environment}-eks"
  role_arn = aws_iam_role.eks_cluster.arn
  version  = var.kubernetes_version

  access_config {
    authentication_mode = "API_AND_CONFIG_MAP"
  }

  vpc_config {
    subnet_ids              = concat(var.web_subnet_ids, var.was_subnet_ids)
    endpoint_private_access = true
    endpoint_public_access  = true
    public_access_cidrs     = ["0.0.0.0/0"]
  }

  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  tags = {
    Name        = "${var.environment}-eks"
    Environment = var.environment
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy,
    aws_iam_role_policy_attachment.eks_vpc_resource_controller,
  ]
}

# =================================================
# EKS 노드 그룹 IAM Role
# =================================================

resource "aws_iam_role" "eks_nodes" {
  name = "${var.environment}-eks-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })

  tags = {
    Name        = "${var.environment}-eks-node-role"
    Environment = var.environment
  }
}

resource "aws_iam_role_policy_attachment" "eks_worker_node_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.eks_nodes.name
}

resource "aws_iam_role_policy_attachment" "eks_cni_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.eks_nodes.name
}

resource "aws_iam_role_policy_attachment" "eks_container_registry_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.eks_nodes.name
}

# =================================================
# EKS 노드 그룹 - Web Tier
# =================================================

resource "aws_eks_node_group" "web" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.environment}-web-nodes"
  node_role_arn   = aws_iam_role.eks_nodes.arn
  subnet_ids      = var.web_subnet_ids

  instance_types = [var.node_instance_type]

  scaling_config {
    desired_size = var.web_desired_size
    max_size     = var.web_max_size
    min_size     = var.web_min_size
  }

  update_config {
    max_unavailable = 1
  }

  labels = {
    tier = "web"
  }

  tags = {
    Name        = "${var.environment}-web-nodes"
    Environment = var.environment
    Tier        = "Web"
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_node_policy,
    aws_iam_role_policy_attachment.eks_cni_policy,
    aws_iam_role_policy_attachment.eks_container_registry_policy,
  ]
}

# =================================================
# EKS 노드 그룹 - WAS Tier
# =================================================

resource "aws_eks_node_group" "was" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.environment}-was-nodes"
  node_role_arn   = aws_iam_role.eks_nodes.arn
  subnet_ids      = var.was_subnet_ids

  instance_types = [var.node_instance_type]

  scaling_config {
    desired_size = var.was_desired_size
    max_size     = var.was_max_size
    min_size     = var.was_min_size
  }

  update_config {
    max_unavailable = 1
  }

  labels = {
    tier = "was"
  }

  tags = {
    Name        = "${var.environment}-was-nodes"
    Environment = var.environment
    Tier        = "WAS"
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_node_policy,
    aws_iam_role_policy_attachment.eks_cni_policy,
    aws_iam_role_policy_attachment.eks_container_registry_policy,
  ]
}

# =================================================
# EKS Add-ons
# =================================================

resource "aws_eks_addon" "vpc_cni" {
  cluster_name         = aws_eks_cluster.main.name
  addon_name           = "vpc-cni"
  configuration_values = jsonencode({ enableNetworkPolicy = "true" })
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "kube-proxy"
}

resource "aws_eks_addon" "coredns" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "coredns"

  depends_on = [
    aws_eks_node_group.web,
    aws_eks_node_group.was,
  ]
}

# =================================================
# CloudWatch Observability Add-on (Container Insights)
# =================================================
# 이 애드온은 CloudWatch Agent와 Fluent Bit를 자동으로 설치하여
# Container Insights 메트릭과 로그를 수집합니다.
# 수동으로 CloudWatch Agent를 설치할 필요가 없습니다.

resource "aws_eks_addon" "cloudwatch_observability" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "amazon-cloudwatch-observability"

  depends_on = [
    aws_eks_node_group.web,
    aws_eks_node_group.was,
    aws_iam_role_policy_attachment.cloudwatch_agent_server_policy,
  ]
}

# CloudWatch Observability 애드온에 필요한 IAM 정책
resource "aws_iam_role_policy_attachment" "cloudwatch_agent_server_policy" {
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
  role       = aws_iam_role.eks_nodes.name
}
