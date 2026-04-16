# Modulo secure-bucket — version LocalStack.
#
# Limitaciones conocidas en Community:
#   aws_kms_key          — recurso creado, pero SSE-KMS no aplica cifrado real.
#   aws_s3_bucket_policy — bucket policy aceptada, pero la condicion
#                          aws:sourceVpce no se evalua realmente.
#   aws_vpc_endpoint     — recurso creado, no enruta trafico real.
#
# Todos los demas recursos (bucket, public access block, versionado, lifecycle)
# funcionan correctamente en LocalStack Community.

# ── KMS CMK ───────────────────────────────────────────────────────────────────

resource "aws_kms_key" "s3" {
  description             = "CMK para cifrado SSE-KMS del bucket ${var.bucket_name}"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  tags                    = var.tags
}

resource "aws_kms_alias" "s3" {
  name          = "alias/${var.project}-datalake"
  target_key_id = aws_kms_key.s3.key_id
}

# ── Bucket ────────────────────────────────────────────────────────────────────

resource "aws_s3_bucket" "main" {
  bucket = var.bucket_name
  tags   = var.tags
}

# ── Bloqueo de acceso publico ─────────────────────────────────────────────────

resource "aws_s3_bucket_public_access_block" "main" {
  bucket = aws_s3_bucket.main.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ── Cifrado SSE-KMS con Bucket Key ────────────────────────────────────────────

resource "aws_s3_bucket_server_side_encryption_configuration" "main" {
  bucket = aws_s3_bucket.main.id

  rule {
    bucket_key_enabled = true
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.s3.arn
    }
  }
}

# ── Versionado ────────────────────────────────────────────────────────────────

resource "aws_s3_bucket_versioning" "main" {
  bucket = aws_s3_bucket.main.id
  versioning_configuration {
    status = "Enabled"
  }
}

# ── Ciclo de vida ─────────────────────────────────────────────────────────────

resource "aws_s3_bucket_lifecycle_configuration" "main" {
  bucket = aws_s3_bucket.main.id

  depends_on = [aws_s3_bucket_versioning.main]

  rule {
    id     = "archive-and-expire"
    status = "Enabled"

    filter {}

    transition {
      days          = var.transition_days
      storage_class = "GLACIER"
    }

    expiration {
      days = var.expiration_days
    }

    noncurrent_version_transition {
      noncurrent_days = var.transition_days
      storage_class   = "GLACIER"
    }

    noncurrent_version_expiration {
      noncurrent_days = var.expiration_days
    }
  }
}

# ── Politica de bucket ────────────────────────────────────────────────────────
# La condicion aws:sourceVpce se acepta sin error pero no se evalua en
# LocalStack Community — el bucket es accesible sin restriccion de endpoint.

resource "aws_s3_bucket_policy" "main" {
  bucket = aws_s3_bucket.main.id

  depends_on = [aws_s3_bucket_public_access_block.main]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyNonVPCEndpoint"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.main.arn,
          "${aws_s3_bucket.main.arn}/*"
        ]
        Condition = {
          StringNotEquals = {
            "aws:sourceVpce"       = var.vpc_endpoint_id
            "aws:PrincipalAccount" = "000000000000"
          }
        }
      }
    ]
  })
}
