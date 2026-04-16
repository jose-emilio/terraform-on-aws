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
  # Redirige las llamadas de S3 al endpoint local de LocalStack
  endpoints {
    s3 = "http://localhost.localstack.cloud:4566"
  }
}

# Bucket de estado compartido para LocalStack.
# En LocalStack el nombre no necesita ser globalmente único.
resource "aws_s3_bucket" "state" {
  bucket = "terraform-state-labs"

  tags = {
    ManagedBy = "terraform"
    Purpose   = "terraform-state"
  }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

output "bucket_name" {
  description = "Nombre del bucket de estado compartido"
  value       = aws_s3_bucket.state.bucket
}

output "bucket_arn" {
  description = "ARN del bucket de estado compartido"
  value       = aws_s3_bucket.state.arn
}

output "bucket_region" {
  description = "Región donde fue creado el bucket"
  value       = aws_s3_bucket.state.region
}
