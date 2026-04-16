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

output "nat_mode" {
  description = "Modo de NAT activo: 'nat_gateway' o 'nat_instance'"
  value       = var.use_nat_instance ? "nat_instance" : "nat_gateway"
}

output "nat_public_ips" {
  description = "IPs públicas NAT por AZ"
  value = var.use_nat_instance ? {
    for az, inst in aws_instance.nat : az => inst.public_ip
  } : {
    for az, eip in aws_eip.nat : az => eip.public_ip
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
    for az, rt in aws_route_table.private : az => rt.id
  }
}

output "test_instance_id" {
  description = "ID de la instancia de test en subred privada"
  value       = aws_instance.test.id
}
