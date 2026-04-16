terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }

  backend "s3" {}
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
      Pipeline    = "lab45"
    }
  }
}

# ── Data sources ──────────────────────────────────────────────────────────────
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# ── Sufijo aleatorio ──────────────────────────────────────────────────────────
#
# Genera un sufijo legible (ej: "happy-panda") que se incorpora al nombre de
# todos los recursos desplegados por el pipeline. Se fija en el primer apply
# y no cambia en ejecuciones posteriores salvo que se destruya el recurso.

resource "random_pet" "suffix" {
  length    = 2
  separator = "-"
}

# ═══════════════════════════════════════════════════════════════════════════════
# KMS — Clave compartida para cifrar todos los recursos del target
# ═══════════════════════════════════════════════════════════════════════════════
#
# Usada por: S3 (SSE-KMS), SSM Parameter (SecureString), CloudWatch Log Group.
# La politica permite al servicio logs usar la clave para cifrar los log groups
# (CloudWatch Logs requiere permiso explicito en la key policy).

resource "aws_kms_key" "target" {
  description             = "CMK para cifrar los recursos del target ${var.project}."
  deletion_window_in_days = 7
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EnableRootAccess"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "AllowCloudWatchLogs"
        Effect    = "Allow"
        Principal = { Service = "logs.${data.aws_region.current.region}.amazonaws.com" }
        Action    = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:DescribeKey"]
        Resource  = "*"
        Condition = {
          ArnLike = {
            "kms:EncryptionContext:aws:logs:arn" = "arn:aws:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:/${var.project}/*"
          }
        }
      }
    ]
  })
}

resource "aws_kms_alias" "target" {
  name          = "alias/${var.project}-${random_pet.suffix.id}"
  target_key_id = aws_kms_key.target.key_id
}

# ═══════════════════════════════════════════════════════════════════════════════
# S3 — Bucket de datos de ejemplo
# ═══════════════════════════════════════════════════════════════════════════════
#
# Recurso principal que el pipeline despliega. El smoke test verificara:
#   - El bucket existe
#   - El versionado esta habilitado
#   - El cifrado SSE-KMS esta habilitado
#   - El acceso publico esta bloqueado

resource "aws_s3_bucket" "data" {
  # checkov:skip=CKV_AWS_18:  Lab - access logging requiere un bucket dedicado, fuera de scope
  # checkov:skip=CKV_AWS_52:  Lab - MFA delete operacionalmente costoso en entorno de laboratorio
  # checkov:skip=CKV_AWS_144: Lab - cross-region replication fuera de scope
  # checkov:skip=CKV2_AWS_61: Lab - lifecycle policy fuera de scope
  # checkov:skip=CKV2_AWS_62: Lab - event notifications fuera de scope

  bucket = "${var.project}-${random_pet.suffix.id}"

  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "data" {
  bucket                  = aws_s3_bucket.data.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "data" {
  bucket = aws_s3_bucket.data.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "data" {
  bucket = aws_s3_bucket.data.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.target.arn
    }
    bucket_key_enabled = true
  }
}

# ═══════════════════════════════════════════════════════════════════════════════
# SSM Parameter Store — Configuracion del entorno
# ═══════════════════════════════════════════════════════════════════════════════
#
# SecureString cifrado con la CMK del target (CKV_AWS_337, CKV2_AWS_34).
# El smoke test usa --with-decryption para verificar el valor.

resource "aws_ssm_parameter" "environment" {
  name   = "/${var.project}/${random_pet.suffix.id}/environment"
  type   = "SecureString"
  value  = var.environment
  key_id = aws_kms_key.target.arn

  tags = { Purpose = "pipeline-smoke-test" }
}

# ═══════════════════════════════════════════════════════════════════════════════
# CloudWatch Log Group — Logs de la aplicacion
# ═══════════════════════════════════════════════════════════════════════════════
#
# Cifrado con CMK (CKV_AWS_158). Retencion de 365 dias (CKV_AWS_338).

resource "aws_cloudwatch_log_group" "app" {
  name              = "/${var.project}/${random_pet.suffix.id}/app"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.target.arn
}
