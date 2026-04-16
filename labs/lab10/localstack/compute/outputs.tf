output "vpc_id" {
  description = "ID de la VPC consumida desde la capa de red."
  value       = local.vpc_id
}

output "subnet_id" {
  description = "ID de la subred consumida desde la capa de red."
  value       = local.subnet_id
}

output "security_group_id" {
  description = "ID del Security Group desplegado por la capa de computo."
  value       = aws_security_group.app.id
}
