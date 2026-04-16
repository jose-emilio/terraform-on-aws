# ===========================================================================
# Lab22 — Refactorizacion Avanzada de S3 (De Monolitico a Modular)
# ===========================================================================
# Version LocalStack: usa account_id fijo ya que skip_requesting_account_id = true
# ===========================================================================

# --- Locals ---

locals {
  account_id = "000000000000"

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
  force_destroy     = true

  tags = merge(local.common_tags, {
    Purpose            = "data"
    DataClassification = "confidential"
  })
}
