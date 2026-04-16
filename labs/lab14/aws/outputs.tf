output "kms_key_id" {
  description = "Key ID de la CMK (UUID); requerido por operaciones como get-key-rotation-status"
  value       = aws_kms_key.secrets.key_id
}

output "kms_key_arn" {
  description = "ARN de la clave KMS; úsalo en aws.s3.tfbackend como kms_key_id para cifrar el .tfstate"
  value       = aws_kms_key.secrets.arn
}

output "kms_key_alias" {
  description = "Alias de la clave KMS para referencia rápida"
  value       = aws_kms_alias.secrets.name
}

output "secret_arn" {
  description = "ARN del secreto en Secrets Manager"
  value       = aws_secretsmanager_secret.db.arn
}

output "secret_name" {
  description = "Nombre del secreto en Secrets Manager"
  value       = aws_secretsmanager_secret.db.name
}

output "rds_endpoint" {
  description = "Endpoint de conexión a la base de datos RDS"
  value       = aws_db_instance.main.endpoint
}

output "rds_identifier" {
  description = "Identificador de la instancia RDS"
  value       = aws_db_instance.main.identifier
}

output "db_username" {
  description = "Usuario maestro de la base de datos (la contraseña está en Secrets Manager)"
  value       = var.db_username
}

output "vpc_id" {
  description = "ID de la VPC creada para aislar la base de datos"
  value       = aws_vpc.main.id
}
