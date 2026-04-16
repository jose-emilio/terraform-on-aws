# api_endpoint y api_id se han eliminado: API Gateway v2 no está disponible
# en LocalStack Community. Usa aws/ para el despliegue completo con AWS real.

output "function_name" {
  description = "Nombre de la función Lambda"
  value       = aws_lambda_function.api.function_name
}

output "layer_arn" {
  description = "ARN versionado de la Lambda Layer 'utils'"
  value       = aws_lambda_layer_version.utils.arn
}

output "layer_version" {
  description = "Número de versión de la Lambda Layer"
  value       = aws_lambda_layer_version.utils.version
}

output "log_group" {
  description = "Nombre del log group de CloudWatch"
  value       = aws_cloudwatch_log_group.lambda.name
}

output "invoke_example" {
  description = "Comando awslocal para invocar la función directamente"
  value       = "awslocal lambda invoke --function-name ${aws_lambda_function.api.function_name} --payload '{\"requestContext\":{\"http\":{\"method\":\"GET\"}},\"rawPath\":\"/items\"}' --cli-binary-format raw-in-base64-out /tmp/response.json && cat /tmp/response.json"
}
