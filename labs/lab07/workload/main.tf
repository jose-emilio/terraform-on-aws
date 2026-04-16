# Bucket de aplicación de ejemplo. Este proyecto comienza con estado local.
# Para migrar al backend remoto, añade `backend "s3" {}` al bloque terraform{}
# de providers.tf y ejecuta terraform init con el archivo .tfbackend correspondiente.
resource "aws_s3_bucket" "app" {
  bucket = var.app_bucket_name

  tags = {
    ManagedBy = "terraform"
    Lab       = "lab7-workload"
  }
}

resource "aws_s3_bucket_public_access_block" "app" {
  bucket = aws_s3_bucket.app.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
