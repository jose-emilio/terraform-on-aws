# ===========================================================================
# Proyecto consumidor — Usa el modulo secure-bucket via Git tag
# ===========================================================================
# Simula como otro equipo consumiria el modulo publicado, referenciando
# una version especifica con ?ref=v1.0.0 para garantizar estabilidad.
# ===========================================================================

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Configuracion parcial del backend. Todos los parametros estan en
  # aws.s3.tfbackend. Usalo asi:
  #   terraform init -backend-config=aws.s3.tfbackend -backend-config="bucket=terraform-state-labs-<ACCOUNT_ID>"
  backend "s3" {}
}

provider "aws" {
  region = "us-east-1"
}

data "aws_caller_identity" "current" {}

# --- Invocacion del modulo via ruta local (simula Git tag) ---
# En un escenario real, el source seria:
#   source = "git::https://github.com/<org>/terraform-aws-secure-bucket.git?ref=v1.0.0"
#
# Para este laboratorio usamos la ruta local equivalente:

module "app_bucket" {
  source = "../modules/secure-bucket"

  bucket_name       = "consumer-app-${data.aws_caller_identity.current.account_id}"
  environment       = "production"
  enable_versioning = true
  enable_encryption = true
  force_destroy     = true

  tags = {
    Team    = "backend"
    Project = "consumer-app"
  }
}

output "bucket_id" {
  description = "Nombre del bucket creado por el equipo consumidor"
  value       = module.app_bucket.bucket_id
}

output "bucket_arn" {
  description = "ARN del bucket"
  value       = module.app_bucket.bucket_arn
}

output "versioning" {
  description = "Estado del versionado"
  value       = module.app_bucket.versioning_status
}
