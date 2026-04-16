output "bucket_id" {
  description = "ID (nombre) del bucket"
  value       = aws_s3_bucket.main.id
}

output "bucket_arn" {
  description = "ARN del bucket"
  value       = aws_s3_bucket.main.arn
}

output "bucket_domain_name" {
  description = "Nombre de dominio del bucket (estilo path)"
  value       = aws_s3_bucket.main.bucket_domain_name
}

output "kms_key_arn" {
  description = "ARN de la CMK KMS usada para el cifrado SSE-KMS"
  value       = aws_kms_key.s3.arn
}

output "kms_key_id" {
  description = "ID de la CMK KMS"
  value       = aws_kms_key.s3.key_id
}

output "kms_alias" {
  description = "Alias de la CMK KMS"
  value       = aws_kms_alias.s3.name
}
