terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Configuración parcial del backend: solo key, region y encrypt están aquí.
  # El nombre del bucket se pasa en el init para no hardcodearlo en el código:
  #   terraform init -backend-config=aws.s3.tfbackend -backend-config="bucket=<nombre>"
  backend "s3" {}
}

provider "aws" {
  region = var.region
}
