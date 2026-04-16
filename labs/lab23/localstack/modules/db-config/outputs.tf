output "secret_arn" {
  description = "ARN del parámetro SecureString con la contraseña"
  value       = aws_ssm_parameter.db_password.arn
}

output "config_summary" {
  description = "Resumen de la configuración de la base de datos (sin contraseña)"
  value = {
    engine         = var.db_config.engine
    engine_version = var.db_config.engine_version
    instance_class = var.db_config.instance_class
    port           = var.db_config.port
    multi_az       = var.db_config.multi_az
    storage_gb     = var.db_config.allocated_storage
    backup_days    = var.db_config.backup_retention_days
  }
}

output "ssm_prefix" {
  description = "Prefijo de los parámetros SSM creados"
  value       = "/${var.project_name}/db/"
}
