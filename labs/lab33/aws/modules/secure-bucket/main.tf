# Datos de la cuenta para la excepcion en la bucket policy
data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
}


# ── KMS CMK ───────────────────────────────────────────────────────────────────
#
# Customer Managed Key dedicada al bucket. enable_key_rotation activa la
# rotacion anual automatica de material criptografico sin cambiar el ARN
# de la clave — los objetos cifrados son transparentemente re-cifrados.

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

# ── Bloqueo de acceso publico (4 controles) ───────────────────────────────────
#
# block_public_acls       — rechaza PutBucketAcl y PutObjectAcl que sean publicas
# ignore_public_acls      — ignora ACLs publicas existentes en el bucket
# block_public_policy     — rechaza PutBucketPolicy que conceda acceso publico
# restrict_public_buckets — restringe el acceso anonimo aunque la policy lo permita

resource "aws_s3_bucket_public_access_block" "main" {
  bucket = aws_s3_bucket.main.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ── Cifrado SSE-KMS con Bucket Key ─────────────────────────────────────────────
#
# bucket_key_enabled = true activa el S3 Bucket Key: S3 genera una clave de
# datos derivada de la CMK y la almacena en el bucket. En lugar de una llamada
# a KMS por objeto, solo se llama a KMS para obtener/renovar la Bucket Key.
# Esto reduce las llamadas a KMS hasta un 99%, bajando el coste y la latencia.

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
#
# Habilitar el versionado convierte cada sobrescritura o borrado en una nueva
# version, preservando las anteriores. Protege contra:
#   - Ransomware: el cifrado del atacante crea una nueva version; la original
#     permanece accesible.
#   - Errores humanos: un Delete crea un "delete marker"; restaurar la version
#     anterior es una operacion de un clic.

resource "aws_s3_bucket_versioning" "main" {
  bucket = aws_s3_bucket.main.id
  versioning_configuration {
    status = "Enabled"
  }
}

# ── Ciclo de vida ─────────────────────────────────────────────────────────────
#
# La regla se aplica a todos los objetos (filter {}).
# Con versionado activo, las transiciones se aplican tanto a la version actual
# como a las versiones no actuales (noncurrent).
# Glacier Flexible Retrieval tiene un coste ~$0.004/GB/mes frente a S3 Standard
# (~$0.023/GB/mes) — un ahorro del 83% para datos de acceso infrecuente.

resource "aws_s3_bucket_lifecycle_configuration" "main" {
  bucket = aws_s3_bucket.main.id

  # depends_on evita el error "lifecycle requires versioning" que aparece
  # cuando Terraform intenta crear la regla antes de que el versionado
  # este completamente activo en la API de S3.
  depends_on = [aws_s3_bucket_versioning.main]

  rule {
    id     = "archive-and-expire"
    status = "Enabled"

    filter {}

    # Version actual: Glacier tras transition_days dias
    transition {
      days          = var.transition_days
      storage_class = "GLACIER"
    }

    # Version actual: eliminar tras expiration_days dias
    expiration {
      days = var.expiration_days
    }

    # Versiones no actuales: Glacier tras transition_days dias
    noncurrent_version_transition {
      noncurrent_days = var.transition_days
      storage_class   = "GLACIER"
    }

    # Versiones no actuales: eliminar tras expiration_days dias
    noncurrent_version_expiration {
      noncurrent_days = var.expiration_days
    }
  }
}

# ── Politica de bucket: solo trafico desde el VPC Endpoint ────────────────────
#
# Effect = Deny con dos claves en el mismo operador StringNotEquals (AND logico):
#   - aws:sourceVpce      != vpc_endpoint_id   → peticion NO viene del endpoint
#   - aws:PrincipalAccount != account_id        → principal NO pertenece a la cuenta
#
# El Deny se activa solo cuando AMBAS condiciones son verdaderas.
# Esto significa que los principales de la propia cuenta (usuarios, roles,
# credenciales temporales STS) nunca son bloqueados, aunque no usen el endpoint.
# Solo se bloquean accesos externos (otras cuentas sin el endpoint).
#
# En produccion, restringe aun mas cambiando aws:PrincipalAccount por
# aws:PrincipalArn con el ARN especifico del rol de despliegue.

resource "aws_s3_bucket_policy" "main" {
  bucket = aws_s3_bucket.main.id

  depends_on = [aws_s3_bucket_public_access_block.main]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyExternalNonVPCEndpoint"
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
            "aws:PrincipalAccount" = local.account_id
          }
        }
      }
    ]
  })
}
