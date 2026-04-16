# ===========================================================================
# Módulo validated-bucket — Bucket S3 con nombre validado por regex
# ===========================================================================
# Garantiza que el nombre del bucket cumple la política corporativa
# (prefijo 'empresa-') antes de intentar crearlo en AWS.

locals {
  default_tags = {
    ManagedBy = "terraform"
    Module    = "validated-bucket"
  }

  effective_tags = merge(local.default_tags, var.tags)
}

resource "aws_s3_bucket" "this" {
  bucket        = var.bucket_name
  force_destroy = var.force_destroy

  tags = merge(local.effective_tags, {
    Name = var.bucket_name
  })
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket = aws_s3_bucket.this.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
