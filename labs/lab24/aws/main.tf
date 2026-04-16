# ===========================================================================
# Lab24 — El "Wrapper" Corporativo: RDS + VPC
# ===========================================================================
# Invoca el módulo corporate-rds que internamente orquesta:
#   - Módulo público VPC (terraform-aws-modules/vpc/aws)
#   - Módulo público RDS (terraform-aws-modules/rds/aws)
#   - Security group restrictivo
# Con parámetros de seguridad hardcoded que el equipo no puede desactivar.
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
# Módulo Wrapper — corporate-rds
# ===========================================================================

module "corporate_rds" {
  source = "./modules/corporate-rds"

  project_name = var.project_name
  environment  = var.environment

  # Red
  vpc_cidr = "10.20.0.0/16"

  # Base de datos (solo parámetros que el equipo puede elegir)
  db_engine         = "mysql"
  db_engine_version = "8.0"
  db_instance_class = "db.t4g.micro"
  db_name           = "appdb"
  db_username       = "admin"

  tags = local.common_tags
}
