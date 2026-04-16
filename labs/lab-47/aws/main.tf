# ── Data sources ──────────────────────────────────────────────────────────────
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

# ═══════════════════════════════════════════════════════════════════════════════
# KMS — Clave maestra compartida para todos los servicios del laboratorio
# ═══════════════════════════════════════════════════════════════════════════════
#
# Una sola CMK simplifica la gestión para el laboratorio. En producción se
# recomienda una CMK por servicio para aplicar el principio de mínimo privilegio:
# si la clave de CloudTrail se ve comprometida, los logs de Firehose en S3
# permanecen protegidos con su propia clave independiente.
#
# La política incluye statements para cuatro servicios:
#   1. EnableRootAccess       → la cuenta raíz puede administrar la clave
#   2. AllowCloudWatchLogs    → CloudWatch Logs puede cifrar/descifrar log groups
#   3. AllowCloudTrail        → CloudTrail puede cifrar los archivos de log en S3
#   4. AllowFirehose          → Kinesis Firehose puede cifrar los datos entregados a S3

resource "aws_kms_key" "main" {
  description             = "CMK compartida para ${var.project}: CloudWatch Logs, CloudTrail, Firehose, S3."
  deletion_window_in_days = 7
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EnableRootAccess"
        Effect    = "Allow"
        Principal = { AWS = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        # CloudWatch Logs requiere este statement para cifrar eventos antes de
        # escribirlos en disco. La condición ArnLike limita el acceso a los
        # log groups de esta cuenta, evitando el uso cruzado entre cuentas.
        Sid    = "AllowCloudWatchLogs"
        Effect = "Allow"
        Principal = { Service = "logs.${var.region}.amazonaws.com" }
        Action = [
          "kms:Encrypt*", "kms:Decrypt*", "kms:ReEncrypt*",
          "kms:GenerateDataKey*", "kms:Describe*"
        ]
        Resource = "*"
        Condition = {
          ArnLike = {
            "kms:EncryptionContext:aws:logs:arn" = "arn:${data.aws_partition.current.partition}:logs:${var.region}:${data.aws_caller_identity.current.account_id}:*"
          }
        }
      },
      {
        # CloudTrail necesita GenerateDataKey para cifrar cada archivo de log
        # antes de subirlo a S3. La condición StringLike vincula la clave al
        # ARN del trail, evitando que otros trails de otras cuentas la usen.
        Sid    = "AllowCloudTrail"
        Effect = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = ["kms:GenerateDataKey*", "kms:Decrypt", "kms:DescribeKey"]
        Resource  = "*"
        Condition = {
          StringLike = {
            "kms:EncryptionContext:aws:cloudtrail:arn" = "arn:${data.aws_partition.current.partition}:cloudtrail:*:${data.aws_caller_identity.current.account_id}:trail/*"
          }
        }
      },
      {
        # Kinesis Firehose necesita GenerateDataKey para cifrar los datos
        # con SSE-KMS antes de entregarlos al bucket S3 de archivo.
        Sid    = "AllowFirehose"
        Effect = "Allow"
        Principal = { Service = "firehose.amazonaws.com" }
        Action    = ["kms:GenerateDataKey*", "kms:Decrypt", "kms:Encrypt*"]
        Resource  = "*"
      }
    ]
  })

  tags = { Project = var.project, ManagedBy = "terraform" }
}

resource "aws_kms_alias" "main" {
  name          = "alias/${var.project}-main"
  target_key_id = aws_kms_key.main.key_id
}

# ═══════════════════════════════════════════════════════════════════════════════
# S3 — Bucket de archivo centralizado para CloudTrail y Firehose
# ═══════════════════════════════════════════════════════════════════════════════
#
# Un único bucket recibe los logs de dos fuentes distintas en prefijos separados:
#   cloudtrail/ → archivos JSON cifrados escritos directamente por CloudTrail
#   firehose/   → objetos GZIP escritos por Kinesis Firehose, particionados por fecha
#
# El versionado garantiza que ningún objeto pueda sobrescribirse silenciosamente.
# Esto es especialmente relevante para los logs de auditoría: si alguien con
# acceso S3 intenta eliminar un log, la versión anterior queda preservada.

resource "aws_s3_bucket" "archive" {
  bucket        = "${var.project}-archive-${data.aws_caller_identity.current.account_id}"
  force_destroy = true

  tags = {
    Project   = var.project
    ManagedBy = "terraform"
    Purpose   = "telemetry-archive"
  }
}

resource "aws_s3_bucket_versioning" "archive" {
  bucket = aws_s3_bucket.archive.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "archive" {
  bucket = aws_s3_bucket.archive.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.main.arn
    }
    # bucket_key_enabled reduce el número de llamadas KMS en un ~99%: en lugar de
    # cifrar cada objeto individualmente con la CMK, S3 genera una clave de bucket
    # que descifra localmente. Esto reduce los costes de KMS significativamente
    # en buckets con alto volumen de objetos (logs de Firehose).
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "archive" {
  bucket                  = aws_s3_bucket.archive.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ═══════════════════════════════════════════════════════════════════════════════
# S3 Lifecycle — Política FinOps: Standard → Glacier Deep Archive tras N días
# ═══════════════════════════════════════════════════════════════════════════════
#
# Los logs de red y auditoría rara vez se consultan después de las primeras
# semanas. Pasado ese periodo de "acceso caliente", son datos fríos que se
# conservan por obligación legal o de compliance, no por necesidad operativa.
#
# Glacier Deep Archive (GDA) es el tier más económico de AWS:
#   S3 Standard:       ~$0.023/GB/mes
#   Glacier Deep Archive: ~$0.00099/GB/mes
#   Ahorro:            ~95.7% de reducción de coste de almacenamiento
#
# Consideraciones de GDA:
#   - Tiempo de recuperación: 12 horas (standard) o 48 horas (bulk)
#   - Duración mínima de almacenamiento cobrada: 180 días
#   - No apto para logs que necesiten acceso en minutos (usar Glacier Instant)
#
# La regla también limpia:
#   - Cargas multiparte incompletas a los 7 días (Firehose usa multipart)
#   - Versiones no actuales a los 180 días (versionado habilitado)

resource "aws_s3_bucket_lifecycle_configuration" "archive" {
  bucket     = aws_s3_bucket.archive.id
  depends_on = [aws_s3_bucket_versioning.archive]

  rule {
    id     = "transition-to-glacier-deep-archive"
    status = "Enabled"

    filter {
      prefix = ""
    }

    transition {
      days          = var.glacier_transition_days
      storage_class = "DEEP_ARCHIVE"
    }

    # Las cargas multiparte incompletas generan costes ocultos. Firehose usa
    # multipart upload para objetos grandes. Si la carga falla a medias, las
    # partes parciales se cobran en S3 Standard hasta que se limpian.
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }

    # Con versionado habilitado, los objetos eliminados o sobreescritos generan
    # versiones no actuales. Se limpian a los 180 días para no acumular versiones
    # antiguas de logs que ya están en Glacier.
    noncurrent_version_expiration {
      noncurrent_days = 180
    }
  }
}
