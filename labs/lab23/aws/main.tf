# ===========================================================================
# Lab23 — Diseño de Interfaz Robusta y "Fail-Safe"
# ===========================================================================
# Tres módulos que demuestran técnicas de validación defensiva:
#   - safe-network:     VPC con postcondition RFC 1918
#   - validated-bucket: S3 con regex de prefijo corporativo
#   - db-config:        Tipo object + sensitive + Secrets Manager + SSM
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
# Módulo safe-network — VPC con postcondición RFC 1918
# ===========================================================================

module "network" {
  source = "./modules/safe-network"

  vpc_cidr     = var.vpc_cidr
  project_name = var.project_name
  environment  = var.environment
  tags         = local.common_tags
}

# ===========================================================================
# Módulo validated-bucket — S3 con nombre validado por regex
# ===========================================================================

module "corporate_bucket" {
  source = "./modules/validated-bucket"

  bucket_name   = var.bucket_name
  force_destroy = true

  tags = merge(local.common_tags, {
    Purpose = "corporate-data"
  })
}

# ===========================================================================
# Módulo db-config — Configuración de DB con tipos complejos y secretos
# ===========================================================================

module "database" {
  source = "./modules/db-config"

  project_name = var.project_name
  db_config    = var.db_config
  db_password  = var.db_password
  tags         = local.common_tags
}
