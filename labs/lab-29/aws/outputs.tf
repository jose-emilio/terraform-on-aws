output "ecr_repository_url" {
  description = "URL del repositorio ECR (usarla como prefijo para docker push)"
  value       = aws_ecr_repository.app.repository_url
}

output "docker_login_cmd" {
  description = "Comando para autenticarse en ECR antes de hacer docker push"
  value       = "aws ecr get-login-password --region ${var.region} | docker login --username AWS --password-stdin ${aws_ecr_repository.app.repository_url}"
}

output "ecs_cluster_name" {
  description = "Nombre del cluster ECS"
  value       = aws_ecs_cluster.main.name
}

output "web_service_name" {
  description = "Nombre del servicio ECS Web (acceso desde el navegador en puerto 80)"
  value       = aws_ecs_service.web.name
}

output "api_service_name" {
  description = "Nombre del servicio ECS API (accesible internamente en api:8080 via Service Connect)"
  value       = aws_ecs_service.api.name
}

output "web_task_definition_arn" {
  description = "ARN de la revisión activa de la task definition del servicio Web"
  value       = aws_ecs_task_definition.web.arn
}

output "api_task_definition_arn" {
  description = "ARN de la revisión activa de la task definition del servicio API"
  value       = aws_ecs_task_definition.api.arn
}

output "ssm_parameter_name" {
  description = "Nombre del parámetro SSM compartido entre ambos microservicios"
  value       = aws_ssm_parameter.api_key.name
}

output "service_connect_namespace" {
  description = "Namespace de Service Connect (DNS interno: web:80 y api:8080)"
  value       = aws_service_discovery_http_namespace.main.name
}

output "web_log_group" {
  description = "Grupo de logs CloudWatch del servicio Web"
  value       = aws_cloudwatch_log_group.web.name
}

output "api_log_group" {
  description = "Grupo de logs CloudWatch del servicio API"
  value       = aws_cloudwatch_log_group.api.name
}
