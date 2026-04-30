# ===========================================================================
# Ejemplo avanzado — Con cifrado y logging activados
# ===========================================================================
# Crea dos buckets:
#   1. Bucket de logs (destino del access logging)
#   2. Bucket de datos (con versionado, cifrado y logging hacia el bucket de logs)

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

locals {
  account_id = data.aws_caller_identity.current.account_id
}

# --- Bucket de logs (destino) ---

module "logs_bucket" {
  source = "../../"

  bucket_name       = "example-adv-logs-${local.account_id}"
  environment       = "production"
  enable_versioning = false
  force_destroy     = true

  tags = {
    Purpose = "access-logs"
  }
}

# --- Bucket de datos (con logging hacia el bucket de logs) ---

module "data_bucket" {
  source = "../../"

  bucket_name           = "example-adv-data-${local.account_id}"
  environment           = "production"
  enable_versioning     = true
  enable_encryption     = true
  enable_access_logging = true
  logging_target_bucket = module.logs_bucket.bucket_id
  logging_target_prefix = "data-bucket-logs/"
  force_destroy         = true

  tags = {
    Purpose            = "critical-data"
    DataClassification = "confidential"
  }
}

output "logs_bucket_id" {
  value = module.logs_bucket.bucket_id
}

output "data_bucket_id" {
  value = module.data_bucket.bucket_id
}

output "data_versioning" {
  value = module.data_bucket.versioning_status
}
