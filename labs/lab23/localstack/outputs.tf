output "vpc_id" {
  description = "ID de la VPC"
  value       = module.network.vpc_id
}

output "vpc_cidr" {
  description = "CIDR de la VPC (validado como RFC 1918)"
  value       = module.network.vpc_cidr
}

output "bucket_id" {
  description = "Nombre del bucket S3 (validado con prefijo corporativo)"
  value       = module.corporate_bucket.bucket_id
}

output "db_config_summary" {
  description = "Resumen de la configuración de la base de datos (sin contraseña)"
  value       = module.database.config_summary
}

output "ssm_prefix" {
  description = "Prefijo de los parámetros SSM de configuración de DB"
  value       = module.database.ssm_prefix
}
