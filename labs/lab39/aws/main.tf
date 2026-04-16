# ── Data sources ──────────────────────────────────────────────────────────────
# aws_caller_identity devuelve el Account ID de la cuenta activa.
# Se usa para generar nombres de bucket globalmente unicos (S3 exige
# nombres unicos a nivel mundial). Se asocia al proveedor primario
# porque el Account ID es identico en todas las regiones.
data "aws_caller_identity" "current" {
  provider = aws.primary
}

# ══════════════════════════════════════════════════════════════════════════════
# REGION PRIMARIA — us-east-1
# ══════════════════════════════════════════════════════════════════════════════

# ── S3: Bucket de artefactos (us-east-1) ─────────────────────────────────────
# Todos los recursos de esta seccion declaran provider = aws.primary para
# que Terraform dirija las llamadas API a us-east-1.
resource "aws_s3_bucket" "artifacts_primary" {
  provider = aws.primary
  bucket   = "${var.project}-artifacts-${data.aws_caller_identity.current.account_id}-use1"

  tags = {
    Name        = "${var.project}-artifacts-primary"
    Project     = var.project
    Environment = var.environment
    Region      = var.primary_region
    ManagedBy   = "terraform"
    # Este tag sera el objetivo del ejercicio de Drift (Paso 2).
    # Modificalo manualmente en la consola de S3 para simular un cambio
    # no gestionado por Terraform y luego detectalo con -refresh-only.
    Owner       = "platform-team"
  }
}

resource "aws_s3_bucket_versioning" "artifacts_primary" {
  provider = aws.primary
  bucket   = aws_s3_bucket.artifacts_primary.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "artifacts_primary" {
  provider = aws.primary
  bucket   = aws_s3_bucket.artifacts_primary.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ── SSM: Parametro de configuracion regional (us-east-1) ─────────────────────
# Almacena la region activa en SSM para que las aplicaciones puedan
# descubrirla en tiempo de ejecucion sin hardcodear valores.
resource "aws_ssm_parameter" "config_primary" {
  provider    = aws.primary
  name        = "/${var.project}/config/primary-region"
  type        = "String"
  value       = var.primary_region
  description = "Region primaria activa del proyecto ${var.project}"

  tags = {
    Project   = var.project
    Region    = var.primary_region
    ManagedBy = "terraform"
  }
}

# ══════════════════════════════════════════════════════════════════════════════
# REGION SECUNDARIA — eu-west-3
# ══════════════════════════════════════════════════════════════════════════════

# ── S3: Bucket de artefactos para recuperacion ante desastres (eu-west-3) ─────
# Mismo patron que la region primaria pero apuntando a eu-west-3 mediante
# provider = aws.secondary. Los sufijos -use1 / -euw3 en los nombres hacen
# explicita la region y evitan colisiones accidentales.
resource "aws_s3_bucket" "artifacts_secondary" {
  provider = aws.secondary
  bucket   = "${var.project}-artifacts-${data.aws_caller_identity.current.account_id}-euw3"

  tags = {
    Name        = "${var.project}-artifacts-secondary"
    Project     = var.project
    Environment = var.environment
    Region      = var.secondary_region
    ManagedBy   = "terraform"
    Owner       = "platform-team"
  }
}

resource "aws_s3_bucket_versioning" "artifacts_secondary" {
  provider = aws.secondary
  bucket   = aws_s3_bucket.artifacts_secondary.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "artifacts_secondary" {
  provider = aws.secondary
  bucket   = aws_s3_bucket.artifacts_secondary.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ── SSM: Parametro de configuracion regional (eu-west-3) ─────────────────────
resource "aws_ssm_parameter" "config_secondary" {
  provider    = aws.secondary
  name        = "/${var.project}/config/secondary-region"
  type        = "String"
  value       = var.secondary_region
  description = "Region secundaria activa del proyecto ${var.project}"

  tags = {
    Project   = var.project
    Region    = var.secondary_region
    ManagedBy = "terraform"
  }
}

# ══════════════════════════════════════════════════════════════════════════════
# ADOPCION DE INFRAESTRUCTURA EXISTENTE — bloque import (Terraform 1.5+)
# ══════════════════════════════════════════════════════════════════════════════
#
# El bloque import declara la intencion de incorporar un recurso existente
# al estado de Terraform SIN destruirlo y recrearlo.
#
# Flujo completo (ver Paso 4 del README):
#   1. Crea el bucket legacy con AWS CLI (fuera de Terraform).
#   2. Descomenta el bloque import de abajo.
#   3. Ejecuta:
#        terraform plan -generate-config-out=generated.tf
#      Terraform escribe el bloque resource completo en generated.tf.
#   4. Revisa generated.tf, ajusta los atributos si es necesario y
#      mueve (o copia) el bloque resource a main.tf.
#   5. Vuelve a comentar o elimina el bloque import.
#   6. Ejecuta terraform apply — el bucket queda bajo control de Terraform
#      sin haber sido borrado ni recreado.
#
# NOTA: cuando el recurso usa un alias de proveedor distinto del default,
# debes especificar 'provider' en el bloque import. De lo contrario
# Terraform buscara el recurso en la region del proveedor default (que
# aqui no existe) y fallara con "no default provider configured".

# Descomenta este bloque en el Paso 4:
# import {
#   provider = aws.primary
#   to       = aws_s3_bucket.legacy_logs
#   id       = var.legacy_bucket_name
# }
#
# El bloque resource correspondiente lo generara Terraform automaticamente
# con -generate-config-out. Una vez generado y revisado, pegalo aqui
# (o en un fichero separado) y elimina el bloque import.
