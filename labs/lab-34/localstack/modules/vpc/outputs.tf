output "vpc_id" {
  value = aws_vpc.main.id
}

output "private_subnet_ids" {
  value = [for s in aws_subnet.private : s.id]
}

output "private_subnets" {
  value = { for az, s in aws_subnet.private : az => s.id }
}
