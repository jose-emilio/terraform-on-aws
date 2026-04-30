# ===========================================================================
# Ejemplo basico — Minima configuracion
# ===========================================================================
# Crea un bucket con los valores por defecto del modulo:
#   - Versionado activado
#   - Cifrado SSE-S3 activado
#   - Bloqueo de acceso publico
#   - Sin logging de acceso

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
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
