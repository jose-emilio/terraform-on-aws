output "config_bucket_name" {
  description = "Nombre del bucket S3 donde Config entrega snapshots e historial de configuración."
  value       = aws_s3_bucket.config_delivery.bucket
}

output "config_recorder_name" {
  description = "Nombre del Configuration Recorder. Necesario para consultar su estado."
  value       = aws_config_configuration_recorder.main.name
}

output "config_rule_ebs_name" {
  description = "Nombre de la regla Config que detecta volúmenes EBS sin cifrar."
  value       = aws_config_config_rule.ebs_encrypted.name
}

output "config_rule_s3_name" {
  description = "Nombre de la regla Config que detecta buckets S3 con acceso público."
  value       = aws_config_config_rule.s3_public_access_prohibited.name
}

output "remediation_role_arn" {
  description = "ARN del rol IAM que SSM Automation asume para ejecutar la remediación de S3."
  value       = aws_iam_role.remediation.arn
}

output "security_hub_arn" {
  description = "ARN de la cuenta de Security Hub habilitada."
  value       = aws_securityhub_account.main.arn
}

output "fsbp_subscription_arn" {
  description = "ARN de la suscripción al estándar FSBP de Security Hub."
  value       = aws_securityhub_standards_subscription.fsbp.id
}
