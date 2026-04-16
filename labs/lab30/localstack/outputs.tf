output "function_name" {
  description = "Nombre de la función Lambda"
  value       = aws_lambda_function.processor.function_name
}

output "orders_queue_url" {
  description = "URL de la cola SQS de entrada (órdenes)"
  value       = aws_sqs_queue.orders.url
}

output "dlq_url" {
  description = "URL de la Dead Letter Queue"
  value       = aws_sqs_queue.dlq.url
}

output "success_queue_url" {
  description = "URL de la cola de éxitos (Lambda Destination on_success)"
  value       = aws_sqs_queue.success.url
}

output "failure_queue_url" {
  description = "URL de la cola de fallos (Lambda Destination on_failure)"
  value       = aws_sqs_queue.failure.url
}

output "log_group" {
  description = "Nombre del log group de CloudWatch"
  value       = aws_cloudwatch_log_group.lambda.name
}

output "send_premium_example" {
  description = "Comando para enviar una orden premium a la cola de entrada"
  value       = "awslocal sqs send-message --queue-url ${aws_sqs_queue.orders.url} --message-body '{\"order_id\":\"ORD-001\",\"order_type\":\"premium\",\"amount\":299.99}'"
}

output "invoke_async_success_example" {
  description = "Invocación async directa para probar Lambda Destinations (éxito)"
  value       = "awslocal lambda invoke --function-name ${aws_lambda_function.processor.function_name} --invocation-type Event --payload '{\"order_id\":\"ASYNC-001\",\"order_type\":\"premium\",\"amount\":500.00}' --cli-binary-format raw-in-base64-out /dev/null"
}

output "invoke_async_failure_example" {
  description = "Invocación async directa para probar Lambda Destinations (fallo, amount > 9999)"
  value       = "awslocal lambda invoke --function-name ${aws_lambda_function.processor.function_name} --invocation-type Event --payload '{\"order_id\":\"ASYNC-002\",\"order_type\":\"premium\",\"amount\":99999.99}' --cli-binary-format raw-in-base64-out /dev/null"
}
