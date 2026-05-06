# ──────────────────────────────────────────────────────────────────────────────
# Codigo Terraform INSEGURO — Demostracion del patron Collect and Fail
# ──────────────────────────────────────────────────────────────────────────────
#
# Este fichero contiene misconfiguraciones deliberadas para demostrar como
# las herramientas de seguridad del pipeline las detectan en post_build.
#
# Problemas que detectaran las herramientas:
#
# Trivy (post_build, paso 4):
#   AVD-AWS-0086  El bucket no tiene public access block (block_public_acls)
#   AVD-AWS-0087  El bucket no tiene bloqueo de politica publica
#   AVD-AWS-0088  El bucket no ignora ACLs publicas
#   AVD-AWS-0089  El bucket no restringe buckets publicos
#   AVD-AWS-0090  No hay cifrado SSE habilitado
#   AVD-AWS-0094  La ACL del bucket es public-read (acceso publico explicito)
#
# Checkov (post_build, paso 5):
#   CKV_AWS_18   S3 Bucket sin access logging
#   CKV_AWS_19   S3 Bucket sin cifrado SSE
#   CKV_AWS_20   S3 Bucket con ACL publica (public-read)
#   CKV_AWS_21   S3 Bucket sin versionado habilitado
#   CKV2_AWS_6   S3 Bucket sin public access block
#   CKV2_AWS_62  S3 Bucket sin event notifications
#
# Resultado esperado:
#   pre_build (formato + sintaxis + tflint) y build (terraform plan) pasan.
#   En post_build, Trivy y Checkov detectan hallazgos y registran SECURITY_FAILED=1.
#   Ambas herramientas se ejecutan completas (patron Collect and Fail) y suben
#   sus informes JUnit a CodeBuild Reports antes de que el build termine en FAILED.
# ──────────────────────────────────────────────────────────────────────────────

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

# ── Bucket S3 sin controles de seguridad ──────────────────────────────────────
#
# Misconfiguraciones en este bloque:
#   - Sin aws_s3_bucket_public_access_block → cualquier ACL publica funciona
#   - Sin aws_s3_bucket_server_side_encryption_configuration → datos en claro
#   - Sin aws_s3_bucket_versioning → sin proteccion ante borrados accidentales
resource "aws_s3_bucket" "datos" {
  bucket = "mi-datos-lab43-insecure"

  tags = {
    Environment = "lab"
    ManagedBy   = "terraform"
  }
}

# ── ACL publica — el problema critico ─────────────────────────────────────────
#
# object_ownership = "BucketOwnerPreferred" es necesario en provider v5+/v6+
# para poder usar ACLs en el bucket (por defecto las ACLs estan deshabilitadas
# con BucketOwnerEnforced). Sin este bloque, aws_s3_bucket_acl fallaria con
# "InvalidBucketAclWithObjectOwnership".
#
# Aun asi, la combinacion de "BucketOwnerPreferred" + ACL "public-read" es
# una misconfiguracion critica: cualquier objeto subido sin ACL explicita
# hereda la del bucket y queda expuesto publicamente a internet.
resource "aws_s3_bucket_ownership_controls" "datos" {
  bucket = aws_s3_bucket.datos.id

  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

resource "aws_s3_bucket_acl" "datos" {
  bucket = aws_s3_bucket.datos.id
  acl    = "public-read" # CRITICO: expone todos los objetos a internet

  depends_on = [aws_s3_bucket_ownership_controls.datos]
}
