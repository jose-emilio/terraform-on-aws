# Ejemplo mínimo de infraestructura para validar el pipeline DevSecOps de lab-15.
#
# Diseñado para pasar todos los gates (Checkov, Trivy, Conftest) sin requerir
# infraestructura auxiliar (buckets de logs, lifecycle policies, etc.). Una
# sola CMK de KMS basta para ejercer el pipeline de extremo a extremo y
# demostrar que un módulo bien configurado es aceptado.
#
# Sustituye este código por tu propia infraestructura cuando el pipeline esté
# verde — el workflow scan/plan/apply seguirá funcionando sobre cualquier
# código Terraform que pongas en este directorio.

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Backend parcial: el bucket se pasa via -backend-config en el init.
  backend "s3" {}
}

provider "aws" {
  region = "us-east-1"
}

data "aws_caller_identity" "current" {}

# CMK con rotación automática y key policy explícita.
# Satisface CKV_AWS_7 (rotation) y CKV2_AWS_64 (policy).
resource "aws_kms_key" "demo" {
  description             = "CMK demo para validar el pipeline DevSecOps de lab-15"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  rotation_period_in_days = 90 # rotación trimestral, más estricta que la anual por defecto

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "EnableRootAccess"
      Effect    = "Allow"
      Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
      Action    = "kms:*"
      Resource  = "*"
    }]
  })

  tags = {
    Project   = "lab15-pipeline-demo"
    ManagedBy = "terraform"
  }
}

resource "aws_kms_alias" "demo" {
  name          = "alias/lab15-pipeline-demo"
  target_key_id = aws_kms_key.demo.key_id
}
