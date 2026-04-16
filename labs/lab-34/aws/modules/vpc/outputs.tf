output "vpc_id" {
  description = "ID de la VPC"
  value       = aws_vpc.main.id
}

output "vpc_cidr" {
  description = "CIDR de la VPC"
  value       = aws_vpc.main.cidr_block
}

output "private_subnet_ids" {
  description = "Lista de IDs de las subnets privadas"
  value       = [for s in aws_subnet.private : s.id]
}

output "private_subnets" {
  description = "Mapa AZ → ID de subnet privada"
  value       = { for az, s in aws_subnet.private : az => s.id }
}

output "nat_gateway_ids" {
  description = "Mapa AZ → ID del NAT Gateway"
  value       = { for az, ngw in aws_nat_gateway.main : az => ngw.id }
}

output "nat_public_ips" {
  description = "Mapa AZ → IP publica del NAT Gateway"
  value       = { for az, eip in aws_eip.nat : az => eip.public_ip }
}
