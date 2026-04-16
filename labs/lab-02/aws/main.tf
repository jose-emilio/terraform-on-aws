# Configuración del backend de Terraform y versión mínima del provider de AWS
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# El provider lee las credenciales del perfil "default" de ~/.aws/credentials
provider "aws" {
  region = "us-east-1"
}

# Bucket S3 compartido para almacenar el estado remoto de Terraform.
# Este bucket se reutiliza como backend en el Lab07 y en el Lab10.
# ⚠️  NO lo destruyas al finalizar este laboratorio.
#
# Los nombres de bucket S3 son globalmente únicos en toda AWS.
# Sustituye <ACCOUNT_ID> por tu ID de cuenta (aws sts get-caller-identity).
resource "aws_s3_bucket" "state" {
  bucket = "terraform-state-labs-<ACCOUNT_ID>"

  tags = {
    ManagedBy = "terraform"
    Purpose   = "terraform-state"
  }
}

# Activa el versionado: cada terraform apply genera una nueva versión del estado
# en lugar de sobreescribir la anterior, lo que permite recuperar estados previos.
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Bloquea todo acceso público al bucket. El estado de Terraform puede contener
# secretos (contraseñas, claves privadas) y nunca debe ser accesible públicamente.
resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Habilita el cifrado AES-256 en reposo para todos los objetos del bucket.
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
