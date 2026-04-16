terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Configuracion parcial del backend. Inicializa asi:
  #   terraform init -backend-config=aws.s3.tfbackend -backend-config="bucket=terraform-state-labs-<ACCOUNT_ID>"
  backend "s3" {}
}

# ═══════════════════════════════════════════════════════════════════════════════
# Provider con default_tags — etiquetado automático universal
# ═══════════════════════════════════════════════════════════════════════════════
#
# El bloque default_tags inyecta las etiquetas definidas aquí en TODOS los
# recursos del provider, sin necesidad de repetirlas en cada resource block.
#
# Regla de precedencia: si un recurso define explícitamente una tag con la
# misma clave que default_tags, la del recurso GANA (override local).
#
# Ejemplo de cómo queda etiquetado un recurso:
#   aws_vpc.main → {Environment="prd", Project="lab48", ManagedBy="terraform",
#                   CostCenter="engineering", Name="lab48-prd-network-vpc"}
#
# La tag Name NO se incluye en default_tags porque es única por recurso.
# Las demás (Environment, Project, ManagedBy, CostCenter) son iguales para
# todos los recursos del proyecto y se gestionan aquí de forma centralizada.

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Environment = var.environment
      Project     = var.project
      ManagedBy   = "terraform"
      CostCenter  = var.cost_center
    }
  }
}
