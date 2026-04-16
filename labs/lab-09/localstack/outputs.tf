# Workspace activo en el momento del apply
output "workspace" {
  description = "Workspace de Terraform activo"
  value       = terraform.workspace
}

output "vpc_id" {
  description = "ID de la VPC del entorno"
  value       = aws_vpc.main.id
}

# El CIDR refleja la configuración dinámica del workspace
output "vpc_cidr" {
  description = "Rango CIDR de la VPC"
  value       = aws_vpc.main.cidr_block
}

output "subnet_cidr" {
  description = "Rango CIDR de la subred"
  value       = aws_subnet.main.cidr_block
}

# instance_type no está asociado a ningún recurso desplegado en este lab;
# se expone como output para verificar la lógica de selección por workspace.
output "instance_type" {
  description = "Tipo de instancia configurado para este entorno (valor de referencia)"
  value       = local.instance_type
}

output "is_prod" {
  description = "Flag de producción activo"
  value       = var.is_prod
}
