# ── Locales ───────────────────────────────────────────────────────────────────

locals {
  account_id = "000000000000" # ID de cuenta simulado por LocalStack
  tags = {
    Project   = var.project
    ManagedBy = "terraform"
  }
}

# ── Customer Managed Key (CMK) ────────────────────────────────────────────────
# LocalStack soporta KMS completo: CMK, alias, cifrado y descifrado.
# enable_key_rotation se acepta pero la rotación no se ejecuta realmente.

resource "aws_kms_key" "main" {
  description             = "CMK del Lab13 — cifrado de EBS y S3"
  enable_key_rotation     = true
  deletion_window_in_days = 7
  multi_region            = false

  # En LocalStack se usa una policy simplificada sin data source de caller identity.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EnableRootAccess"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${local.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      }
    ]
  })

  tags = merge(local.tags, { Name = "${var.project}-cmk" })
}

resource "aws_kms_alias" "main" {
  name          = "alias/${var.project}-main"
  target_key_id = aws_kms_key.main.key_id
}

# ── Bucket S3 cifrado con la CMK ──────────────────────────────────────────────
# EBS no está disponible en LocalStack Community, se omite.
# S3 con SSE-KMS sí es funcional en LocalStack.

resource "aws_s3_bucket" "main" {
  bucket        = "${var.project}-data-${local.account_id}"
  force_destroy = true

  tags = merge(local.tags, { Name = "${var.project}-data" })
}

resource "aws_s3_bucket_server_side_encryption_configuration" "main" {
  bucket = aws_s3_bucket.main.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_alias.main.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "main" {
  bucket                  = aws_s3_bucket.main.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Nota: aws_s3_bucket_policy se omite en LocalStack ya que la evaluación de
# condiciones de política (StringNotEqualsIfExists) no está implementada
# en LocalStack Community y devuelve error al hacer PutBucketPolicy.
