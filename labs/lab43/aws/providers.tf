terraform {
  required_version = ">= 1.5"
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

provider "aws" {
  region = var.region
}
