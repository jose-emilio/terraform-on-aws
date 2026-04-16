output "ecr_repository_url" {
  description = "URL del repositorio ECR simulado en LocalStack"
  value       = aws_ecr_repository.app.repository_url
}

output "ecs_cluster_name" {
  description = "Nombre del cluster ECS"
  value       = aws_ecs_cluster.main.name
}

output "web_service_name" {
  description = "Nombre del servicio ECS Web"
  value       = aws_ecs_service.web.name
}

output "api_service_name" {
  description = "Nombre del servicio ECS API"
  value       = aws_ecs_service.api.name
}

output "web_task_definition_arn" {
  description = "ARN de la task definition del servicio Web"
  value       = aws_ecs_task_definition.web.arn
}

output "api_task_definition_arn" {
  description = "ARN de la task definition del servicio API"
  value       = aws_ecs_task_definition.api.arn
}

output "ssm_parameter_name" {
  description = "Nombre del parámetro SSM"
  value       = aws_ssm_parameter.api_key.name
}

output "service_connect_namespace" {
  description = "Namespace de Service Connect"
  value       = aws_service_discovery_http_namespace.main.name
}
