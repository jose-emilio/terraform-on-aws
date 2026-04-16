output "vpc_id" {
  description = "ID de la VPC desplegada por la capa de red."
  value       = aws_vpc.main.id
}

output "subnet_id" {
  description = "ID de la subred pública."
  value       = aws_subnet.public.id
}

output "vpc_cidr" {
  description = "Bloque CIDR de la VPC."
  value       = aws_vpc.main.cidr_block
}
