terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  # Backend local: el estado se guarda en ./terraform.tfstate junto a este directorio.
  # La capa de computo lo leerá mediante terraform_remote_state con backend = "local".
  # Para usar un backend S3 en LocalStack, consulta el README de localstack/.
}

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true

  endpoints {
    ec2 = "http://localhost.localstack.cloud:4566"
  }
}
