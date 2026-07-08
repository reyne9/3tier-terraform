# aws/modules/rds/main.tf
# RDS MySQL 모듈

terraform {
  required_version = ">= 1.14.0"
}

# =================================================
# RDS 서브넷 그룹
# =================================================

resource "aws_db_subnet_group" "main" {
  name       = "${var.environment}-rds-subnet-group"
  subnet_ids = var.subnet_ids

  tags = {
    Name        = "${var.environment}-rds-subnet-group"
    Environment = var.environment
  }
}

# =================================================
# RDS 보안 그룹
# =================================================

resource "aws_security_group" "rds" {
  name        = "${var.environment}-rds-sg"
  description = "Security group for RDS MySQL"
  vpc_id      = var.vpc_id

  ingress {
    description     = "MySQL from EKS"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [var.eks_security_group_id]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.environment}-rds-sg"
    Environment = var.environment
  }
}

# =================================================
# RDS 파라미터 그룹
# =================================================

resource "aws_db_parameter_group" "main" {
  name   = "${var.environment}-mysql8-params"
  family = "mysql8.0"

  parameter {
    name  = "character_set_server"
    value = "utf8mb4"
  }

  parameter {
    name  = "collation_server"
    value = "utf8mb4_unicode_ci"
  }

  parameter {
    name  = "max_connections"
    value = "1000"
  }

  parameter {
    name  = "slow_query_log"
    value = "1"
  }

  parameter {
    name  = "long_query_time"
    value = "2"
  }

  tags = {
    Name        = "${var.environment}-mysql8-params"
    Environment = var.environment
  }
}

# =================================================
# Enhanced Monitoring IAM Role
# =================================================

resource "aws_iam_role" "rds_enhanced_monitoring" {
  count = var.enhanced_monitoring_enabled ? 1 : 0
  name  = "${var.environment}-rds-enhanced-monitoring-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "monitoring.rds.amazonaws.com"
      }
    }]
  })

  tags = {
    Name        = "${var.environment}-rds-enhanced-monitoring-role"
    Environment = var.environment
  }
}

resource "aws_iam_role_policy_attachment" "rds_enhanced_monitoring" {
  count      = var.enhanced_monitoring_enabled ? 1 : 0
  role       = aws_iam_role.rds_enhanced_monitoring[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

# =================================================
# RDS 인스턴스
# =================================================

resource "aws_db_instance" "main" {
  identifier = "${var.environment}-rds"

  engine         = "mysql"
  engine_version = "8.0"
  instance_class = var.instance_class

  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.max_allocated_storage
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name  = var.database_name
  username = var.master_username
  password = var.master_password

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  parameter_group_name   = aws_db_parameter_group.main.name

  multi_az                = var.multi_az
  publicly_accessible     = false
  backup_retention_period = 7
  backup_window           = "03:00-04:00"
  maintenance_window      = "mon:04:00-mon:05:00"

  # Enhanced Monitoring
  monitoring_interval = var.enhanced_monitoring_enabled ? var.monitoring_interval : 0
  monitoring_role_arn = var.enhanced_monitoring_enabled ? aws_iam_role.rds_enhanced_monitoring[0].arn : null

  enabled_cloudwatch_logs_exports = ["error", "general", "slowquery"]

  skip_final_snapshot       = var.skip_final_snapshot
  final_snapshot_identifier = "${var.environment}-rds-final-snapshot-${formatdate("YYYY-MM-DD-hhmm", timestamp())}"

  deletion_protection = var.deletion_protection

  tags = {
    Name        = "${var.environment}-rds"
    Environment = var.environment
  }

  depends_on = [aws_iam_role_policy_attachment.rds_enhanced_monitoring]
}
