output "vpc_id" {
  description = "ID del VPC creado."
  value       = aws_vpc.this.id
}

output "vpc_arn" {
  description = "ARN del VPC."
  value       = aws_vpc.this.arn
}

output "vpc_cidr_block" {
  description = "CIDR block asignado al VPC."
  value       = aws_vpc.this.cidr_block
}

output "internet_gateway_id" {
  description = "ID del Internet Gateway adjunto al VPC."
  value       = aws_internet_gateway.this.id
}

output "public_subnet_ids" {
  description = "Lista de IDs de las subredes publicas, en el mismo orden que public_subnet_cidrs."
  value       = [for s in aws_subnet.public : s.id]
}

output "private_subnet_ids" {
  description = "Lista de IDs de las subredes privadas, en el mismo orden que private_subnet_cidrs."
  value       = [for s in aws_subnet.private : s.id]
}

output "public_route_table_id" {
  description = "ID de la tabla de rutas publica (compartida por todas las subredes publicas)."
  value       = aws_route_table.public.id
}

output "private_route_table_id" {
  description = "ID de la tabla de rutas privada. Añade una ruta 0.0.0.0/0 → NAT Gateway para acceso saliente a internet."
  value       = aws_route_table.private.id
}
