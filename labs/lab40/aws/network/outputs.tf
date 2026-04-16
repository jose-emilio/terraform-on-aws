# Estos outputs son consumidos por el proyecto app/ mediante
# data "terraform_remote_state" "network". Cualquier valor que el proyecto
# app/ necesite conocer debe exponerse aqui — es el contrato entre los
# dos proyectos de Terraform.

output "vpc_id" {
  description = "ID del VPC principal"
  value       = aws_vpc.main.id
}

output "vpc_cidr" {
  description = "Bloque CIDR del VPC"
  value       = aws_vpc.main.cidr_block
}

output "public_subnet_id" {
  description = "ID de la subnet publica"
  value       = aws_subnet.public.id
}

output "private_subnet_id" {
  description = "ID de la subnet privada"
  value       = aws_subnet.private.id
}

output "igw_id" {
  description = "ID del Internet Gateway"
  value       = aws_internet_gateway.main.id
}

output "region" {
  description = "Region donde se desplego la red"
  value       = var.region
}
