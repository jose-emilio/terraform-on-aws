# ===========================================================================
# Modulo secure-bucket — Bucket S3 listo para produccion
# ===========================================================================
# Bucket con buenas practicas: bloqueo publico, versionado, cifrado y
# logging opcionales. Disenado para ser publicado y consumido por otros
# equipos via Git tags con versionado semantico.
# ===========================================================================

locals {
  default_tags = {
    ManagedBy   = "terraform"
    Module      = "secure-bucket"
    Environment = var.environment
  }

  effective_tags = merge(local.default_tags, var.tags)
}

# --- Bucket S3 ---

resource "aws_s3_bucket" "this" {
  bucket        = var.bucket_name
  force_destroy = var.force_destroy

  tags = merge(local.effective_tags, {
    Name = var.bucket_name
  })
}

# --- Bloqueo de acceso publico ---

resource "aws_s3_bucket_public_access_block" "this" {
  bucket = aws_s3_bucket.this.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# --- Versionado ---

resource "aws_s3_bucket_versioning" "this" {
  bucket = aws_s3_bucket.this.id

  versioning_configuration {
    status = var.enable_versioning ? "Enabled" : "Suspended"
  }
}

# --- Cifrado SSE-S3 ---

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  count  = var.enable_encryption ? 1 : 0
  bucket = aws_s3_bucket.this.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# --- Logging de acceso ---

resource "aws_s3_bucket_logging" "this" {
  count  = var.enable_access_logging ? 1 : 0
  bucket = aws_s3_bucket.this.id

  target_bucket = var.logging_target_bucket
  target_prefix = var.logging_target_prefix
}
