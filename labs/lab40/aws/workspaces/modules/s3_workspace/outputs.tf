output "bucket_name" {
  description = "Nombre del bucket S3 de workspace"
  value       = aws_s3_bucket.this.bucket
}

output "bucket_arn" {
  description = "ARN del bucket S3 de workspace"
  value       = aws_s3_bucket.this.arn
}

output "ssm_parameter_name" {
  description = "Nombre del parametro SSM que almacena el nombre del bucket"
  value       = aws_ssm_parameter.bucket_name.name
}
