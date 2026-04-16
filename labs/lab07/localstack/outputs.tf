output "bucket_name" {
  description = "Nombre del bucket S3 creado en LocalStack"
  value       = aws_s3_bucket.state.id
}

output "dynamodb_table_name" {
  description = "Nombre de la tabla DynamoDB creada en LocalStack"
  value       = aws_dynamodb_table.lock.name
}
