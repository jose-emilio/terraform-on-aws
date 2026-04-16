terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Configuracion parcial del backend. Usalo asi:
  #   terraform init -backend-config=aws.s3.tfbackend -backend-config="bucket=terraform-state-labs-<ACCOUNT_ID>"
  backend "s3" {}
}

provider "aws" {
  region = var.region

  # merge() — Caso de uso 1: etiquetas globales del proveedor.
  # Todos los recursos heredan estas etiquetas via tags_all automaticamente,
  # sin necesidad de declararlas en cada resource. Las etiquetas especificas
  # de cada recurso se fusionan con estas en runtime.
  default_tags {
    tags = {
      ManagedBy   = "terraform"
      Project     = var.project
      Environment = var.environment
      CostCenter  = var.company_tags.cost_center
      Owner       = var.company_tags.owner
    }
  }
}
