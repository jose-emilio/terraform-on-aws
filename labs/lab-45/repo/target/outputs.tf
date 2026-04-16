output "bucket_name" {
  description = "Nombre del bucket S3 desplegado por el pipeline."
  value       = aws_s3_bucket.data.bucket
}

output "bucket_arn" {
  description = "ARN del bucket S3."
  value       = aws_s3_bucket.data.arn
}

output "ssm_parameter_name" {
  description = "Nombre del parametro SSM del entorno."
  value       = aws_ssm_parameter.environment.name
}

output "log_group_name" {
  description = "Nombre del grupo de logs de CloudWatch."
  value       = aws_cloudwatch_log_group.app.name
}

output "log_retention_days" {
  description = "Periodo de retencion configurado en el log group."
  value       = aws_cloudwatch_log_group.app.retention_in_days
}
