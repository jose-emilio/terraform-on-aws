output "vpc_id" {
  description = "ID de la VPC"
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "CIDR de la VPC (validado como RFC 1918 por postcondition)"
  value       = aws_vpc.this.cidr_block
}

output "private_subnet_ids" {
  description = "IDs de las subredes privadas"
  value       = [for s in aws_subnet.private : s.id]
}
