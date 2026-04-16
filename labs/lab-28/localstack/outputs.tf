output "alb_url" {
  description = "URL del ALB simulado en LocalStack"
  value       = "http://${aws_lb.main.dns_name}"
}

output "asg_name" {
  description = "Nombre del Auto Scaling Group"
  value       = aws_autoscaling_group.web.name
}

output "launch_template_id" {
  description = "ID del Launch Template"
  value       = aws_launch_template.web.id
}

output "launch_template_latest_version" {
  description = "Versión activa del Launch Template"
  value       = aws_launch_template.web.latest_version
}
