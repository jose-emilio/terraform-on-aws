output "bucket_name" {
  description = "Nombre del bucket S3 del Lab02 usado como backend"
  value       = var.bucket_name
}

output "dynamodb_table_name" {
  description = "Nombre de la tabla DynamoDB para usar en el bloque backend"
  value       = aws_dynamodb_table.lock.name
}

output "backend_config" {
  description = "Bloque backend con DynamoDB listo para copiar en cualquier proyecto"
  value       = <<-EOT
    terraform {
      backend "s3" {
        bucket         = "${var.bucket_name}"
        key            = "PROYECTO/terraform.tfstate"
        region         = "us-east-1"
        encrypt        = true
        dynamodb_table = "${aws_dynamodb_table.lock.name}"
      }
    }
  EOT
}
