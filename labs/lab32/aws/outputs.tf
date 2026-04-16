output "function_name" {
  description = "Nombre de la función Lambda"
  value       = aws_lambda_function.main.function_name
}

output "function_version" {
  description = "Última versión publicada de la función Lambda"
  value       = aws_lambda_function.main.version
}

output "alias_arn" {
  description = "ARN del alias 'live' (con Provisioned Concurrency)"
  value       = aws_lambda_alias.live.arn
}

output "alias_invoke_arn" {
  description = "ARN de invocación del alias 'live'"
  value       = aws_lambda_alias.live.invoke_arn
}

output "vpc_id" {
  description = "ID de la VPC del laboratorio"
  value       = aws_vpc.main.id
}

output "private_subnet_ids" {
  description = "IDs de las subredes privadas (Lambda)"
  value       = aws_subnet.private[*].id
}

output "lambda_sg_id" {
  description = "ID del Security Group dedicado a Lambda"
  value       = aws_security_group.lambda.id
}

output "cluster_name" {
  description = "Nombre del cluster ECS"
  value       = aws_ecs_cluster.main.name
}

output "service_name" {
  description = "Nombre del servicio ECS"
  value       = aws_ecs_service.app.name
}

output "sns_topic_arn" {
  description = "ARN del topic SNS para alertas de CloudWatch"
  value       = aws_sns_topic.alerts.arn
}

output "alarm_name" {
  description = "Nombre de la alarma CloudWatch sobre CPU del servicio ECS"
  value       = aws_cloudwatch_metric_alarm.ecs_cpu.alarm_name
}

output "log_group_lambda" {
  description = "Nombre del log group de CloudWatch para Lambda"
  value       = aws_cloudwatch_log_group.lambda.name
}

output "log_group_ecs" {
  description = "Nombre del log group de CloudWatch para ECS"
  value       = aws_cloudwatch_log_group.ecs.name
}

output "invoke_alias_example" {
  description = "Comando para invocar la función a través del alias 'live' (con Provisioned Concurrency)"
  value       = "aws lambda invoke --function-name ${aws_lambda_function.main.function_name} --qualifier live --payload '{}' --cli-binary-format raw-in-base64-out /tmp/response.json && cat /tmp/response.json | python3 -m json.tool"
}

output "invoke_latest_example" {
  description = "Comando para invocar $LATEST (sin Provisioned Concurrency, cold start posible)"
  value       = "aws lambda invoke --function-name ${aws_lambda_function.main.function_name} --payload '{}' --cli-binary-format raw-in-base64-out /tmp/response.json && cat /tmp/response.json | python3 -m json.tool"
}
