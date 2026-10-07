# aws/modules/vpc/main.tf
# VPC 및 네트워크 리소스 모듈

terraform {
  required_version = ">= 1.14.0"
}

# =================================================
# VPC
# =================================================

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name        = "${var.environment}-vpc"
    Environment = var.environment
  }

  lifecycle {
    create_before_destroy = true
  }
}

# =================================================
# Internet Gateway
# =================================================

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name        = "${var.environment}-igw"
    Environment = var.environment
  }

  lifecycle {
    create_before_destroy = true
  }
}




# =================================================
# Public Subnets
# =================================================

resource "aws_subnet" "public" {
  count = length(var.availability_zones)

  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name        = "${var.environment}-public-${count.index + 1}"
    Environment = var.environment
    Type        = "Public"
    # ELB가 이 서브넷을 사용할 수 있도록 태그 추가
    "kubernetes.io/role/elb" = "1"
  }

  # 서브넷 삭제 시 의존 리소스(ENI, ALB 등) 정리 시간 확보
  timeouts {
    delete = "20m"
  }
}

# =================================================
# Private Subnets (Web Tier)
# =================================================

resource "aws_subnet" "web" {
  count = length(var.availability_zones)

  vpc_id            = aws_vpc.main.id
  cidr_block        = var.web_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  tags = {
    Name                                           = "${var.environment}-web-${count.index + 1}"
    Environment                                    = var.environment
    Type                                           = "Private"
    "kubernetes.io/role/internal-elb"              = "1"
    "kubernetes.io/cluster/${var.environment}-eks" = "shared"
    "karpenter.sh/discovery"                       = "${var.environment}-eks"
  }

  # 서브넷 삭제 시 의존 리소스(ENI, ALB 등) 정리 시간 확보
  timeouts {
    delete = "20m"
  }
}

# =================================================
# Private Subnets (WAS Tier)
# =================================================

resource "aws_subnet" "was" {
  count = length(var.availability_zones)

  vpc_id            = aws_vpc.main.id
  cidr_block        = var.was_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  tags = {
    Name                                           = "${var.environment}-was-${count.index + 1}"
    Environment                                    = var.environment
    Type                                           = "Private"
    "kubernetes.io/role/internal-elb"              = "1"
    "kubernetes.io/cluster/${var.environment}-eks" = "shared"
    "karpenter.sh/discovery"                       = "${var.environment}-eks"
  }

  # 서브넷 삭제 시 의존 리소스(ENI, ALB 등) 정리 시간 확보
  timeouts {
    delete = "20m"
  }
}

# =================================================
# Private Subnets (RDS)
# =================================================

resource "aws_subnet" "rds" {
  count = length(var.availability_zones)

  vpc_id            = aws_vpc.main.id
  cidr_block        = var.rds_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  tags = {
    Name        = "${var.environment}-rds-${count.index + 1}"
    Environment = var.environment
    Type        = "Private"
  }
}

# =================================================
# NAT Gateway
# =================================================

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name        = "${var.environment}-nat-eip"
    Environment = var.environment
  }

  depends_on = [aws_internet_gateway.main]
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  tags = {
    Name        = "${var.environment}-nat"
    Environment = var.environment
  }

  depends_on = [aws_internet_gateway.main]
}

# =================================================
# Route Tables - Public
# =================================================

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name        = "${var.environment}-public-rt"
    Environment = var.environment
  }
}

resource "aws_route_table_association" "public" {
  count = length(aws_subnet.public)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# =================================================
# Route Tables - Private
# =================================================

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = {
    Name        = "${var.environment}-private-rt"
    Environment = var.environment
  }
}

resource "aws_route_table_association" "web" {
  count = length(aws_subnet.web)

  subnet_id      = aws_subnet.web[count.index].id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "was" {
  count = length(aws_subnet.was)

  subnet_id      = aws_subnet.was[count.index].id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "rds" {
  count = length(aws_subnet.rds)

  subnet_id      = aws_subnet.rds[count.index].id
  route_table_id = aws_route_table.private.id
}
