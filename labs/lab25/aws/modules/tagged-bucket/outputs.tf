output "bucket_id" {
  description = "Nombre (ID) del bucket S3"
  value       = aws_s3_bucket.this.bucket
}

output "bucket_arn" {
  description = "ARN del bucket S3"
  value       = aws_s3_bucket.this.arn
}

output "effective_tags" {
  description = "Etiquetas finales aplicadas al bucket (merge de default + custom)"
  value       = local.effective_tags
}
