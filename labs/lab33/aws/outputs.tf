output "bucket_name" {
  description = "Nombre del bucket S3"
  value       = module.datalake.bucket_id
}

output "bucket_arn" {
  description = "ARN del bucket S3"
  value       = module.datalake.bucket_arn
}

output "kms_key_arn" {
  description = "ARN de la CMK KMS usada para el cifrado SSE-KMS"
  value       = module.datalake.kms_key_arn
}

output "kms_alias" {
  description = "Alias de la CMK KMS"
  value       = module.datalake.kms_alias
}

output "vpc_id" {
  description = "ID de la VPC del laboratorio"
  value       = aws_vpc.main.id
}

output "vpc_endpoint_id" {
  description = "ID del VPC Gateway Endpoint de S3"
  value       = aws_vpc_endpoint.s3.id
}

output "put_object_example" {
  description = "Comando de ejemplo para subir un objeto al bucket (desde la VPC)"
  value       = "aws s3 cp /tmp/test.txt s3://${module.datalake.bucket_id}/test.txt"
}

output "list_versions_example" {
  description = "Comando de ejemplo para listar versiones de objetos"
  value       = "aws s3api list-object-versions --bucket ${module.datalake.bucket_id}"
}
