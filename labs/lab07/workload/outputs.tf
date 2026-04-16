output "app_bucket_name" {
  description = "Nombre del bucket de aplicación"
  value       = aws_s3_bucket.app.id
}

output "app_bucket_arn" {
  description = "ARN del bucket de aplicación"
  value       = aws_s3_bucket.app.arn
}
