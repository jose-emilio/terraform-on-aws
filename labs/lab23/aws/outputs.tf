output "vpc_id" {
  description = "ID de la VPC"
  value       = module.network.vpc_id
}

output "vpc_cidr" {
  description = "CIDR de la VPC (validado como RFC 1918)"
  value       = module.network.vpc_cidr
}

output "private_subnet_ids" {
  description = "IDs de las subredes privadas"
  value       = module.network.private_subnet_ids
}

output "bucket_id" {
  description = "Nombre del bucket S3 (validado con prefijo corporativo)"
  value       = module.corporate_bucket.bucket_id
}

output "bucket_arn" {
  description = "ARN del bucket S3"
  value       = module.corporate_bucket.bucket_arn
}

output "db_config_summary" {
  description = "Resumen de la configuración de la base de datos (sin contraseña)"
  value       = module.database.config_summary
}

output "secret_arn" {
  description = "ARN del secreto en Secrets Manager (la contraseña NO se expone en outputs)"
  value       = module.database.secret_arn
}

output "ssm_prefix" {
  description = "Prefijo de los parámetros SSM de configuración de DB"
  value       = module.database.ssm_prefix
}
