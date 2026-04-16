# ===========================================================================
# Módulo validated-bucket — Bucket S3 con nombre validado (LocalStack)
# ===========================================================================
# Sin bloqueo de acceso público (emulación parcial en LocalStack).

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
