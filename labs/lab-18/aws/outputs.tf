output "vpc_id" {
  description = "ID de la VPC desplegada"
  value       = aws_vpc.main.id
}

output "vpc_cidr" {
  description = "CIDR block de la VPC"
  value       = aws_vpc.main.cidr_block
}

output "alb_dns_name" {
  description = "DNS publico del Application Load Balancer"
  value       = aws_lb.main.dns_name
}

output "alb_sg_id" {
  description = "ID del Security Group del ALB"
  value       = aws_security_group.alb.id
}

output "app_sg_id" {
  description = "ID del Security Group de las instancias de aplicacion"
  value       = aws_security_group.app.id
}

output "public_nacl_id" {
  description = "ID de la NACL de las subredes publicas"
  value       = aws_network_acl.public.id
}

output "private_nacl_id" {
  description = "ID de la NACL de las subredes privadas"
  value       = aws_network_acl.private.id
}

output "flow_log_group" {
  description = "Nombre del CloudWatch Log Group de VPC Flow Logs"
  value       = aws_cloudwatch_log_group.flow_logs.name
}

output "app_instance_ids" {
  description = "IDs de las instancias de aplicacion"
  value = {
    for key, inst in aws_instance.app : key => inst.id
  }
}

output "public_subnet_ids" {
  description = "IDs de las subredes publicas"
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
