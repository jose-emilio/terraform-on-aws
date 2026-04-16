output "vpc_id" {
  value = aws_vpc.main.id
}

# Los CIDRs calculados por cidrsubnet() se exponen para verificar
# que la división automática del bloque es la esperada
output "public_subnet_cidrs" {
  value = aws_subnet.public[*].cidr_block
}

output "private_subnet_cidrs" {
  value = aws_subnet.private[*].cidr_block
}

output "security_group_id" {
  value = aws_security_group.main.id
}
