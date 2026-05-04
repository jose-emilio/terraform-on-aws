# ===========================================================================
# Ejemplo básico — Mínima configuración
# ===========================================================================
# Crea un bucket con los valores por defecto del módulo:
#   - Versionado activado
#   - Cifrado SSE-S3 activado
#   - Bloqueo de acceso público
#   - Sin logging de acceso

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

variable "region" {
  type        = string
  description = "Región AWS donde desplegar el bucket de ejemplo."
  default     = "us-east-1"
}

provider "aws" {
  region = var.region
}

data "aws_caller_identity" "current" {}

module "bucket" {
  source = "../../"

  bucket_name   = "example-basic-${data.aws_caller_identity.current.account_id}"
  environment   = "lab"
  force_destroy = true
}

output "bucket_id" {
  value = module.bucket.bucket_id
}

output "bucket_arn" {
  value = module.bucket.bucket_arn
}
