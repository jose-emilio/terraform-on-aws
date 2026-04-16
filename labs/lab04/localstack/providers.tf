# Configuración del backend de Terraform y versión mínima del provider de AWS
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# Credenciales ficticias aceptadas por LocalStack.
# Los parámetros skip_* evitan llamadas de validación a la API real de AWS.
provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true

  s3_use_path_style = true

  endpoints {
    iam = "http://localhost.localstack.cloud:4566" # usuarios IAM
    ec2 = "http://localhost.localstack.cloud:4566" # launch template
    sts = "http://localhost.localstack.cloud:4566" # aws_caller_identity
  }
}
