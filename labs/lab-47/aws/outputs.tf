output "vpc_id" {
  description = "ID de la VPC del laboratorio."
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "IDs de las subredes públicas (una por AZ)."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "IDs de las subredes privadas (una por AZ)."
  value       = aws_subnet.private[*].id
}

output "traffic_gen_instance_id" {
  description = "ID de la instancia EC2 generadora de tráfico."
  value       = aws_instance.traffic_gen.id
}

output "traffic_gen_public_ip" {
  description = "IP pública de la instancia generadora de tráfico."
  value       = aws_instance.traffic_gen.public_ip
}

output "traffic_gen_eni_id" {
  description = "ID de la ENI primaria de la instancia (objetivo del Flow Log)."
  value       = aws_instance.traffic_gen.primary_network_interface_id
}

output "archive_bucket_name" {
  description = "Nombre del bucket S3 de archivo centralizado."
  value       = aws_s3_bucket.archive.id
}

output "archive_bucket_arn" {
  description = "ARN del bucket S3 de archivo."
  value       = aws_s3_bucket.archive.arn
}

output "flow_logs_log_group" {
  description = "Nombre del log group de VPC Flow Logs."
  value       = aws_cloudwatch_log_group.flow_logs.name
}

output "cloudtrail_log_group" {
  description = "Nombre del log group de CloudTrail en CloudWatch."
  value       = aws_cloudwatch_log_group.cloudtrail.name
}

output "cloudtrail_name" {
  description = "Nombre del trail de CloudTrail."
  value       = aws_cloudtrail.main.name
}

output "cloudtrail_s3_prefix" {
  description = "Prefijo S3 completo donde CloudTrail escribe los logs."
  value       = "s3://${aws_s3_bucket.archive.id}/cloudtrail/AWSLogs/${data.aws_caller_identity.current.account_id}/"
}

output "firehose_name" {
  description = "Nombre del delivery stream de Kinesis Firehose."
  value       = aws_kinesis_firehose_delivery_stream.logs.name
}

output "firehose_arn" {
  description = "ARN del delivery stream de Kinesis Firehose."
  value       = aws_kinesis_firehose_delivery_stream.logs.arn
}

output "firehose_s3_prefix" {
  description = "Prefijo base en S3 donde Firehose entrega los Flow Logs (particionado por fecha)."
  value       = "s3://${aws_s3_bucket.archive.id}/firehose/"
}

output "kms_key_arn" {
  description = "ARN de la CMK compartida del laboratorio."
  value       = aws_kms_key.main.arn
}

output "eni_flow_log_id" {
  description = "ID del VPC Flow Log habilitado sobre la ENI de la instancia."
  value       = aws_flow_log.eni.id
}
