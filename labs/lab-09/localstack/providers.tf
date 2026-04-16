terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Configuración parcial del backend. Todos los parámetros de LocalStack
  # están en localstack.s3.tfbackend. Úsalo así:
  #   terraform init -backend-config=localstack.s3.tfbackend
  backend "s3" {}
}

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true

  s3_use_path_style = true

  endpoints {
    ec2 = "http://localhost.localstack.cloud:4566"
  }
}
