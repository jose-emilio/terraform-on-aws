output "vpc_id" {
  description = "ID de la VPC desplegada"
  value       = aws_vpc.main.id
}

output "security_group_id" {
  description = "ID del security group de la aplicacion"
  value       = aws_security_group.app.id
}

output "security_group_name" {
  description = "Nombre del security group de la aplicacion"
  value       = aws_security_group.app.name
}
