output "cmk_key_id" {
  description = "Key ID de la CMK"
  value       = aws_kms_key.main.key_id
}

output "cmk_alias_name" {
  description = "Nombre del alias de la CMK"
  value       = aws_kms_alias.main.name
}

output "s3_bucket_name" {
  description = "Nombre del bucket S3"
  value       = aws_s3_bucket.main.id
}
