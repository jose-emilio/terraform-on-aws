terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Configuración parcial del backend. Todos los parámetros están en
  # aws.s3.tfbackend. Úsalo así:
  #   terraform init -backend-config=aws.s3.tfbackend -backend-config="bucket=terraform-state-labs-<ACCOUNT_ID>"
  backend "s3" {}
}

provider "aws" {
  region = var.region
}
