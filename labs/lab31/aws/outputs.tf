output "api_endpoint" {
  description = "URL base de la HTTP API. Añade /items, /items/{id}, etc."
  value       = aws_apigatewayv2_stage.default.invoke_url
}

output "function_name" {
  description = "Nombre de la función Lambda"
  value       = aws_lambda_function.api.function_name
}

output "function_arn" {
  description = "ARN de la función Lambda"
  value       = aws_lambda_function.api.arn
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
  description = "Nombre del log group de CloudWatch para la función Lambda"
  value       = aws_cloudwatch_log_group.lambda.name
}

output "api_id" {
  description = "ID de la HTTP API en API Gateway v2"
  value       = aws_apigatewayv2_api.main.id
}

output "curl_get_items" {
  description = "Comando curl de ejemplo para GET /items"
  value       = "curl -s '${aws_apigatewayv2_stage.default.invoke_url}/items' | python3 -m json.tool"
}

output "curl_post_item" {
  description = "Comando curl de ejemplo para POST /items"
  value       = "curl -s -X POST '${aws_apigatewayv2_stage.default.invoke_url}/items' -H 'Content-Type: application/json' -d '{\"nombre\":\"Nuevo Item\",\"precio\":49.99}' | python3 -m json.tool"
}
