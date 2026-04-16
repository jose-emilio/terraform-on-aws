output "kms_key_id" {
  description = "Key ID de la CMK (UUID); requerido por operaciones como get-key-rotation-status"
  value       = aws_kms_key.secrets.key_id
}

output "kms_key_arn" {
  description = "ARN de la clave KMS (emulada por LocalStack)"
  value       = aws_kms_key.secrets.arn
}

output "kms_key_alias" {
  description = "Alias de la clave KMS"
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
