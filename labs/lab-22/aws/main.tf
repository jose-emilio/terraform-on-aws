# ===========================================================================
# Lab22 — Refactorizacion Avanzada de S3 (De Monolitico a Modular)
# ===========================================================================
# Dos instancias del modulo s3-bucket:
#   - logs: bucket para almacenar logs de la aplicacion
#   - data: bucket para datos criticos del negocio
# Cada instancia recibe etiquetas globales del proyecto combinadas con
# etiquetas especificas de su proposito mediante merge().
# ===========================================================================

# --- Data Sources ---

data "aws_caller_identity" "current" {}

# --- Locals ---

locals {
  account_id = data.aws_caller_identity.current.account_id

  common_tags = {
    Environment = var.environment
    ManagedBy   = "terraform"
    Project     = var.project_name
  }
}

# ===========================================================================
# Modulo S3 — Bucket de Logs
# ===========================================================================

module "logs_bucket" {
  source = "./modules/s3-bucket"

  bucket_name       = "${var.project_name}-logs-${local.account_id}"
  enable_versioning = false
  force_destroy     = true

  tags = merge(local.common_tags, {
    Purpose            = "logs"
    DataClassification = "internal"
  })
}

# ===========================================================================
# Modulo S3 — Bucket de Datos
# ===========================================================================

module "data_bucket" {
  source = "./modules/s3-bucket"

  bucket_name       = "${var.project_name}-data-${local.account_id}"
  enable_versioning = true
  force_destroy     = false

  tags = merge(local.common_tags, {
    Purpose            = "data"
    DataClassification = "confidential"
  })
}
