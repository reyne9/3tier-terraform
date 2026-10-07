# The source password is already a sensitive Terraform input for RDS. The
# application receives it through a pod-scoped IRSA role and Secrets Store CSI.
resource "aws_secretsmanager_secret" "petclinic_db" {
  name                    = "portfolio-petclinic-db"
  description             = "PetClinic WAS database connection"
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "petclinic_db" {
  secret_id = aws_secretsmanager_secret.petclinic_db.id
  secret_string = jsonencode({
    url      = "jdbc:mysql://${module.rds.db_instance_address}:${module.rds.db_port}/${module.rds.db_name}"
    username = var.db_username
    password = var.db_password
  })
}

locals {
  eks_oidc_hostpath = trimsuffix(trimprefix(module.eks.oidc_provider_url, "https://"), "/")
}

resource "aws_iam_role" "petclinic_was" {
  name = "${var.environment}-petclinic-was-secrets"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = aws_iam_openid_connect_provider.eks.arn }
      Condition = {
        StringEquals = {
          "${local.eks_oidc_hostpath}:aud" = "sts.amazonaws.com"
          "${local.eks_oidc_hostpath}:sub" = "system:serviceaccount:was:petclinic-was"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "petclinic_db_read" {
  name = "petclinic-db-read"
  role = aws_iam_role.petclinic_was.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
      Resource = aws_secretsmanager_secret.petclinic_db.arn
    }]
  })
}
