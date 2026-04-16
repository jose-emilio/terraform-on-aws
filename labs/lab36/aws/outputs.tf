output "app_url" {
  description = "URL publica de la aplicacion web (puerto 8080)"
  value       = "http://${aws_instance.app.public_ip}:8080"
}

output "app_public_ip" {
  description = "IP publica de la instancia EC2"
  value       = aws_instance.app.public_ip
}

output "dynamo_table_name" {
  description = "Nombre de la tabla DynamoDB de productos"
  value       = aws_dynamodb_table.products.name
}

output "dynamo_table_arn" {
  description = "ARN de la tabla DynamoDB de productos"
  value       = aws_dynamodb_table.products.arn
}

output "dynamo_stream_arn" {
  description = "ARN del stream de DynamoDB (CDC)"
  value       = aws_dynamodb_table.products.stream_arn
}

output "dynamo_gsi_name" {
  description = "Nombre del Global Secondary Index para consultas por status"
  value       = "by-status-index"
}

output "events_table_name" {
  description = "Nombre de la tabla DynamoDB de eventos CDC"
  value       = aws_dynamodb_table.events.name
}

output "redis_primary_endpoint" {
  description = "Endpoint primario de Redis (escrituras)"
  value       = aws_elasticache_replication_group.redis.primary_endpoint_address
}

output "redis_reader_endpoint" {
  description = "Endpoint de lectura de Redis"
  value       = aws_elasticache_replication_group.redis.reader_endpoint_address
}

output "redis_port" {
  description = "Puerto de Redis"
  value       = aws_elasticache_replication_group.redis.port
}

output "redis_secret_name" {
  description = "Nombre del secreto en Secrets Manager con el AUTH token de Redis"
  value       = aws_secretsmanager_secret.redis_auth.name
}

output "lambda_function_name" {
  description = "Nombre de la funcion Lambda CDC"
  value       = aws_lambda_function.cdc_processor.function_name
}

output "lambda_function_arn" {
  description = "ARN de la funcion Lambda CDC"
  value       = aws_lambda_function.cdc_processor.arn
}

output "sns_topic_arn" {
  description = "ARN del topic SNS para alertas de CloudWatch"
  value       = aws_sns_topic.alerts.arn
}

output "alarm_redis_cpu" {
  description = "Nombre de la alarma de CPU de Redis"
  value       = aws_cloudwatch_metric_alarm.redis_cpu.alarm_name
}

output "alarm_redis_evictions" {
  description = "Nombre de la alarma de evictions de Redis"
  value       = aws_cloudwatch_metric_alarm.redis_evictions.alarm_name
}

output "vpc_id" {
  description = "ID de la VPC"
  value       = aws_vpc.main.id
}

output "app_artifacts_bucket" {
  description = "Bucket S3 con los artefactos de la aplicacion"
  value       = aws_s3_bucket.app_artifacts.bucket
}

output "get_redis_token_command" {
  description = "Comando para recuperar el AUTH token de Redis desde Secrets Manager"
  value       = "aws secretsmanager get-secret-value --secret-id ${aws_secretsmanager_secret.redis_auth.name} --query SecretString --output text"
}

output "scan_products_command" {
  description = "Comando para listar todos los productos en DynamoDB"
  value       = "aws dynamodb scan --table-name ${aws_dynamodb_table.products.name} --region ${var.region}"
}

output "query_gsi_command" {
  description = "Comando para consultar productos activos via GSI (ordenados por precio)"
  value       = "aws dynamodb query --table-name ${aws_dynamodb_table.products.name} --index-name by-status-index --key-condition-expression '#s = :v' --expression-attribute-names '{\"#s\":\"status\"}' --expression-attribute-values '{\":v\":{\"S\":\"active\"}}' --region ${var.region}"
}

output "subscribe_sns_command" {
  description = "Comando para suscribirse al topic SNS y recibir alertas por email"
  value       = "aws sns subscribe --topic-arn ${aws_sns_topic.alerts.arn} --protocol email --notification-endpoint TU_EMAIL@ejemplo.com --region ${var.region}"
}
