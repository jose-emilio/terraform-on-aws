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
  description = "ID del VPC Peering app - db"
  value       = aws_vpc_peering_connection.app_to_db.id
}

output "peering_app_c_id" {
  description = "ID del VPC Peering app - vpc-c"
  value       = aws_vpc_peering_connection.app_to_c.id
}
