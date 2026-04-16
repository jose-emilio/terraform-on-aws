output "alb_url" {
  description = "URL pública del Application Load Balancer"
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
  description = "Versión activa del Launch Template (se incrementa con cada apply que cambie user_data o la configuración de la instancia)"
  value       = aws_launch_template.web.latest_version
}

output "private_subnet_ids" {
  description = "IDs de las subredes privadas donde se despliegan las instancias del ASG"
  value       = aws_subnet.private[*].id
}
