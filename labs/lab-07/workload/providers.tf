terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# Provider parametrizado: funciona con AWS real y LocalStack usando -var-file.
# Para AWS real las credenciales se toman del entorno o de ~/.aws/credentials.
# Para LocalStack se pasan access_key, secret_key y s3_endpoint vía localstack.tfvars.
provider "aws" {
  region                      = var.region
  access_key                  = var.aws_access_key
  secret_key                  = var.aws_secret_key
  skip_credentials_validation = var.skip_credentials_validation
  skip_metadata_api_check     = var.skip_metadata_api_check
  skip_requesting_account_id  = var.skip_requesting_account_id

  endpoints {
    s3 = var.s3_endpoint
  }
}
