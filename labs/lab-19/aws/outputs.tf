output "app_vpc_id" {
  description = "ID de la VPC app"
  value       = aws_vpc.app.id
}

output "db_vpc_id" {
  description = "ID de la VPC db"
  value       = aws_vpc.db.id
}

output "c_vpc_id" {
  description = "ID de la VPC C"
  value       = aws_vpc.c.id
}

output "peering_app_db_id" {
  description = "ID del VPC Peering app ↔ db"
  value       = aws_vpc_peering_connection.app_to_db.id
}

output "peering_app_c_id" {
  description = "ID del VPC Peering app ↔ vpc-c"
  value       = aws_vpc_peering_connection.app_to_c.id
}

output "db_sg_id" {
  description = "ID del Security Group de db"
  value       = aws_security_group.db.id
}

output "nat_public_ip" {
  description = "IP publica del NAT Gateway de app"
  value       = aws_eip.nat_app.public_ip
}

output "test_instance_app_id" {
  description = "ID de la instancia de test en app"
  value       = aws_instance.test_app.id
}

output "test_instance_db_id" {
  description = "ID de la instancia de test en db"
  value       = aws_instance.test_db.id
}

output "test_instance_c_id" {
  description = "ID de la instancia de test en vpc-c"
  value       = aws_instance.test_c.id
}

output "test_instance_app_private_ip" {
  description = "IP privada de la instancia de test en app"
  value       = aws_instance.test_app.private_ip
}

output "test_instance_db_private_ip" {
  description = "IP privada de la instancia de test en db"
  value       = aws_instance.test_db.private_ip
}

output "test_instance_c_private_ip" {
  description = "IP privada de la instancia de test en vpc-c"
  value       = aws_instance.test_c.private_ip
}
