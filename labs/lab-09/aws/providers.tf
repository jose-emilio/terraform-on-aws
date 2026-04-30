terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Configuración parcial del backend. El bucket se pasa en el init:
  #   terraform init -backend-config=aws.s3.tfbackend -backend-config="bucket=<nombre>"
  # Con workspaces, Terraform prefija la key automáticamente:
  #   default → lab09/terraform.tfstate
  #   dev     → env:/dev/lab09/terraform.tfstate
  #   prod    → env:/prod/lab09/terraform.tfstate
  backend "s3" {}
}

provider "aws" {
  region = var.region
}
