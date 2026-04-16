output "vpc_id" {
  description = "ID de la VPC desplegada"
  value       = aws_vpc.main.id
}

output "vpc_cidr" {
  description = "CIDR block de la VPC"
  value       = aws_vpc.main.cidr_block
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

output "subnet_cidrs" {
  description = "CIDRs calculados para cada subred"
  value = {
    for key, subnet in aws_subnet.this :
    key => subnet.cidr_block
  }
}

output "availability_zones" {
  description = "Zonas de disponibilidad utilizadas"
  value       = local.azs
}
