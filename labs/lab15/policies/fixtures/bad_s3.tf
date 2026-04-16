# Fixture de prueba — NO desplegar
# Demuestra que la política s3_encryption.rego detecta buckets sin cifrado

# Bucket sin ninguna configuración de cifrado → FAIL [s3-encryption]
resource "aws_s3_bucket" "no_encryption" {
  bucket = "bucket-sin-cifrado"
}

# Bucket con cifrado AES256 en lugar de aws:kms → FAIL [s3-kms-only]
resource "aws_s3_bucket" "aes_encryption" {
  bucket = "bucket-con-aes"
}

resource "aws_s3_bucket_server_side_encryption_configuration" "aes" {
  bucket = aws_s3_bucket.aes_encryption.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Bucket con SSE-KMS pero sin bucket_key_enabled → WARN [s3-bucket-key]
resource "aws_s3_bucket" "kms_no_key" {
  bucket = "bucket-kms-sin-bucket-key"
}

resource "aws_s3_bucket_server_side_encryption_configuration" "kms_no_key" {
  bucket = aws_s3_bucket.kms_no_key.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    # bucket_key_enabled ausente → WARN
  }
}
