# ──────────────────────────────────────────────────────────────────────────────
# Codigo Terraform SEGURO — Demostracion del exito del pipeline
# ──────────────────────────────────────────────────────────────────────────────
#
# Este fichero corrige todas las misconfiguraciones del directorio insecure/.
# Cuando se sube este codigo al bucket S3 y se lanza el build, las cinco
# validaciones de pre_build pasan y la fase build genera el tfplan.
#
# Controles de seguridad aplicados:
#   aws_kms_key                        → CMK dedicada para cifrado SSE-KMS
#   aws_s3_bucket_public_access_block  → bloquea ACLs y politicas publicas
#   aws_s3_bucket_server_side_encryption_configuration → SSE-KMS con CMK
#   aws_s3_bucket_versioning           → proteccion ante borrados accidentales
#   aws_s3_bucket_logging              → acceso auditado en bucket dedicado
#   Sin aws_s3_bucket_acl              → sin ACL publica
# ──────────────────────────────────────────────────────────────────────────────

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

data "aws_caller_identity" "current" {}

# ── CMK dedicada para cifrado SSE-KMS ─────────────────────────────────────────
#   Una Customer Managed Key permite controlar quien puede cifrar/descifrar,
#   rotar la clave y auditar cada uso via CloudTrail. Mas control granular
#   que SSE-S3 (AES256), donde AWS gestiona la clave sin visibilidad del cliente.
resource "aws_kms_key" "s3" {
  description             = "CMK para cifrado SSE-KMS del bucket de datos lab43"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowAccountRoot"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      }
    ]
  })

  tags = {
    Environment = "lab"
    ManagedBy   = "terraform"
  }
}

resource "aws_kms_alias" "s3" {
  name          = "alias/lab43-s3-datos"
  target_key_id = aws_kms_key.s3.key_id
}

# ── Bucket de logs de acceso ──────────────────────────────────────────────────
#   S3 server access logging requiere un bucket dedicado. Los logs de acceso
#   al bucket principal se escriben aqui con el prefijo "datos/".
resource "aws_s3_bucket" "logs" { #tfsec:ignore:aws-s3-encryption-customer-key #tfsec:ignore:aws-s3-enable-bucket-logging
  # checkov:skip=CKV2_AWS_62: Lab - event notifications fuera de scope
  # checkov:skip=CKV2_AWS_61: Lab - lifecycle policy fuera de scope
  # checkov:skip=CKV_AWS_144: Lab - cross-region replication fuera de scope

  bucket = "mi-datos-lab43-secure-logs"

  tags = {
    Environment = "lab"
    ManagedBy   = "terraform"
  }
}

resource "aws_s3_bucket_public_access_block" "logs" {
  bucket                  = aws_s3_bucket.logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.s3.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_versioning" "logs" {
  bucket = aws_s3_bucket.logs.id

  versioning_configuration {
    status = "Enabled"
  }
}

# ── Bucket S3 con todos los controles de seguridad ────────────────────────────
resource "aws_s3_bucket" "datos" {
  # checkov:skip=CKV2_AWS_62: Lab - event notifications fuera de scope
  # checkov:skip=CKV2_AWS_61: Lab - lifecycle policy fuera de scope
  # checkov:skip=CKV_AWS_144: Lab - cross-region replication fuera de scope

  bucket = "mi-datos-lab43-secure"

  tags = {
    Environment = "lab"
    ManagedBy   = "terraform"
  }
}

# Control 1: Bloqueo de acceso publico
#   Impide que cualquier ACL o politica de bucket pueda hacer objetos publicos,
#   independientemente de como se configuren los recursos individuales.
#   Esta es la primera linea de defensa contra exposiciones accidentales.
resource "aws_s3_bucket_public_access_block" "datos" {
  bucket = aws_s3_bucket.datos.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Control 2: Cifrado en reposo con SSE-KMS usando CMK dedicada
#   Todos los objetos se cifran automaticamente al escribirlos usando la CMK.
#   bucket_key_enabled = true genera una clave derivada por bucket que reduce
#   el numero de llamadas a KMS y por tanto el coste de las operaciones.
resource "aws_s3_bucket_server_side_encryption_configuration" "datos" {
  bucket = aws_s3_bucket.datos.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.s3.arn
    }
    bucket_key_enabled = true
  }
}

# Control 3: Versionado habilitado
#   Cada escritura crea una nueva version del objeto en lugar de sobrescribir.
#   Permite recuperar versiones anteriores y protege contra borrados accidentales
#   o ataques de ransomware que sobreescriben objetos.
resource "aws_s3_bucket_versioning" "datos" {
  bucket = aws_s3_bucket.datos.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Control 4: Logging de acceso al bucket
#   Registra cada peticion GET/PUT/DELETE en el bucket de logs dedicado.
#   Permite auditar quien accede a los datos, desde donde y cuando.
resource "aws_s3_bucket_logging" "datos" {
  bucket        = aws_s3_bucket.datos.id
  target_bucket = aws_s3_bucket.logs.id
  target_prefix = "datos/"
}
