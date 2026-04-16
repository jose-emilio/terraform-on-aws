# ──────────────────────────────────────────────────────────────────────────────
# Codigo Terraform INSEGURO — Demostracion del patron Fail Fast
# ──────────────────────────────────────────────────────────────────────────────
#
# Este fichero contiene misconfiguraciones deliberadas para demostrar como
# el pipeline de validacion las detecta y aborta el build.
#
# Problemas que detectaran las herramientas:
#
# tfsec (pre_build, paso 4):
#   aws-s3-block-public-acls       El bucket no tiene public access block
#   aws-s3-block-public-policy     El bucket no tiene bloqueo de politica publica
#   aws-s3-ignore-public-acls      El bucket no ignora ACLs publicas
#   aws-s3-no-public-buckets       El bucket no restringe buckets publicos
#   aws-s3-enable-bucket-encryption No hay cifrado SSE habilitado
#   aws-s3-enable-versioning       No hay versionado habilitado
#   aws-s3-no-public-acl           La ACL del bucket es public-read
#
# Checkov (pre_build, paso 5):
#   CKV_AWS_18   S3 Bucket sin access logging
#   CKV_AWS_19   S3 Bucket sin cifrado SSE
#   CKV_AWS_20   S3 Bucket con ACL publica (public-read)
#   CKV_AWS_21   S3 Bucket sin versionado habilitado
#   CKV2_AWS_6   S3 Bucket sin public access block
#   CKV2_AWS_62  S3 Bucket sin event notifications
#
# Resultado esperado:
#   La fase pre_build falla en el paso 4 (tfsec) con exit code 1.
#   CodeBuild registra on-failure: ABORT y el build queda en estado FAILED.
#   El paso 5 (Checkov) y la fase build NUNCA se ejecutan — Fail Fast.
# ──────────────────────────────────────────────────────────────────────────────

terraform {
  required_version = ">= 1.5"
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
