# ===========================================================================
# Lab23 — Diseño de Interfaz Robusta y "Fail-Safe" (LocalStack)
# ===========================================================================
# Versión adaptada: usa módulos igual que la versión AWS.
# El módulo db-config usa SSM SecureString en lugar de Secrets Manager.
# ===========================================================================

# --- Locals ---

locals {
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
