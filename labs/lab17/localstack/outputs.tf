output "vpc_id" {
  description = "ID de la VPC desplegada"
  value       = aws_vpc.main.id
}

output "vpc_cidr" {
  description = "CIDR block de la VPC"
  value       = aws_vpc.main.cidr_block
}

output "internet_gateway_id" {
  description = "ID del Internet Gateway"
  value       = aws_internet_gateway.main.id
}

output "nat_gateway_ids" {
  description = "IDs de los NAT Gateways (uno por AZ)"
  value = {
    for key, gw in aws_nat_gateway.main : key => gw.id
  }
}

output "nat_public_ips" {
  description = "IPs públicas de los NAT Gateways"
  value = {
    for key, eip in aws_eip.nat : key => eip.public_ip
  }
}

output "s3_endpoint_id" {
  description = "ID del VPC Gateway Endpoint para S3"
  value       = aws_vpc_endpoint.s3.id
}

output "public_subnet_ids" {
  description = "IDs de las subredes públicas"
  value = {
    for key, subnet in aws_subnet.this :
    key => subnet.id if local.subnets[key].public
  }
}

output "private_subnet_ids" {
  description = "IDs de las subredes privadas"
  value = {
    for key, subnet in aws_subnet.this :
    key => subnet.id if !local.subnets[key].public
  }
}

output "public_route_table_id" {
  description = "ID de la tabla de rutas pública"
  value       = aws_route_table.public.id
}

output "private_route_table_ids" {
  description = "IDs de las tablas de rutas privadas (una por AZ)"
  value = {
    for key, rt in aws_route_table.private : key => rt.id
  }
}
