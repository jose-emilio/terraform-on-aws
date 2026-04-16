# ===========================================================================
# Lab25 — Framework de Pruebas: Plan, Apply e Idempotencia
# ===========================================================================
# Root Module que invoca tagged-bucket. Sirve tanto para despliegue normal
# como para ser testeado con `terraform test`.
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
# Módulo tagged-bucket — El módulo bajo test
# ===========================================================================

module "bucket" {
  source = "./modules/tagged-bucket"

  bucket_name  = "${var.project_name}-${var.bucket_suffix}-${local.account_id}"
  project_name = var.project_name
  environment  = var.environment
  tags         = local.common_tags
}
