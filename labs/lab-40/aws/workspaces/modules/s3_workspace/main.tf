# Modulo s3_workspace
# Encapsula el bucket S3 de workspace y su configuracion asociada para un
# entorno concreto. Sustituye al conjunto de recursos sueltos que usaban
# count en la version inicial del proyecto.
#
# Este modulo fue creado en el Paso 3 del laboratorio. Los bloques moved
# en workspaces/moved.tf redirigen las direcciones de estado de los recursos
# sueltos (aws_s3_bucket.workspace["dev"], etc.) a las direcciones dentro
# del modulo (module.workspace["dev"].aws_s3_bucket.this, etc.).

resource "aws_s3_bucket" "this" {
  bucket = "${var.project}-ws-${var.environment}-${var.account_id}"

  tags = {
    Name        = "${var.project}-ws-${var.environment}"
    Environment = var.environment
    Project     = var.project
    ManagedBy   = "terraform"
  }
}

resource "aws_s3_bucket_versioning" "this" {
  bucket = aws_s3_bucket.this.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket = aws_s3_bucket.this.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_ssm_parameter" "bucket_name" {
  name  = "/${var.project}/${var.environment}/bucket-name"
  type  = "String"
  value = aws_s3_bucket.this.bucket

  tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}
