output "bucket_id" {
  description = "Nombre del bucket S3"
  value       = module.bucket.bucket_id
}

output "bucket_arn" {
  description = "ARN del bucket S3"
  value       = module.bucket.bucket_arn
}

output "effective_tags" {
  description = "Etiquetas finales aplicadas al bucket"
  value       = module.bucket.effective_tags
}
