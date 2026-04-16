# ── Region primaria ───────────────────────────────────────────────────────────
output "primary_bucket_name" {
  description = "Nombre del bucket S3 desplegado en la region primaria (us-east-1)"
  value       = aws_s3_bucket.artifacts_primary.bucket
}

output "primary_bucket_arn" {
  description = "ARN del bucket S3 de la region primaria"
  value       = aws_s3_bucket.artifacts_primary.arn
}

output "primary_ssm_parameter_name" {
  description = "Nombre del parametro SSM desplegado en us-east-1"
  value       = aws_ssm_parameter.config_primary.name
}

# ── Region secundaria ─────────────────────────────────────────────────────────
output "secondary_bucket_name" {
  description = "Nombre del bucket S3 desplegado en la region secundaria (eu-west-3)"
  value       = aws_s3_bucket.artifacts_secondary.bucket
}

output "secondary_bucket_arn" {
  description = "ARN del bucket S3 de la region secundaria"
  value       = aws_s3_bucket.artifacts_secondary.arn
}

output "secondary_ssm_parameter_name" {
  description = "Nombre del parametro SSM desplegado en eu-west-3"
  value       = aws_ssm_parameter.config_secondary.name
}

# ── Informacion de cuenta ─────────────────────────────────────────────────────
output "account_id" {
  description = "ID de la cuenta AWS activa (usado como sufijo en los nombres de bucket)"
  value       = data.aws_caller_identity.current.account_id
}

# ── Comandos de verificacion rapida ───────────────────────────────────────────
output "verify_commands" {
  description = "Comandos AWS CLI para verificar los recursos desplegados en ambas regiones"
  value       = <<-EOT
    # Verificar bucket primario (us-east-1)
    aws s3api get-bucket-location --bucket ${aws_s3_bucket.artifacts_primary.bucket}
    aws s3api get-bucket-tagging  --bucket ${aws_s3_bucket.artifacts_primary.bucket}

    # Verificar bucket secundario (eu-west-3)
    aws s3api get-bucket-location --bucket ${aws_s3_bucket.artifacts_secondary.bucket} --region eu-west-3
    aws s3api get-bucket-tagging  --bucket ${aws_s3_bucket.artifacts_secondary.bucket} --region eu-west-3

    # Verificar parametros SSM
    aws ssm get-parameter --name ${aws_ssm_parameter.config_primary.name} --region us-east-1
    aws ssm get-parameter --name ${aws_ssm_parameter.config_secondary.name} --region eu-west-3
  EOT
}
