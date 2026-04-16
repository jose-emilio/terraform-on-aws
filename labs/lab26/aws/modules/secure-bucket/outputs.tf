output "bucket_id" {
  description = "Nombre del bucket S3."
  value       = aws_s3_bucket.this.bucket
}

output "bucket_arn" {
  description = "ARN del bucket S3."
  value       = aws_s3_bucket.this.arn
}

output "bucket_domain_name" {
  description = "Nombre de dominio del bucket."
  value       = aws_s3_bucket.this.bucket_domain_name
}

output "versioning_status" {
  description = "Estado del versionado (Enabled o Suspended)."
  value       = var.enable_versioning ? "Enabled" : "Suspended"
}
