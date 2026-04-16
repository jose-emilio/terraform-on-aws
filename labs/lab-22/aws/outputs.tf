output "logs_bucket_id" {
  description = "Nombre del bucket de logs"
  value       = module.logs_bucket.bucket_id
}

output "logs_bucket_arn" {
  description = "ARN del bucket de logs"
  value       = module.logs_bucket.bucket_arn
}

output "data_bucket_id" {
  description = "Nombre del bucket de datos"
  value       = module.data_bucket.bucket_id
}

output "data_bucket_arn" {
  description = "ARN del bucket de datos"
  value       = module.data_bucket.bucket_arn
}
