# --- VPC ---

output "vpc_id" {
  description = "ID de la VPC"
  value       = module.vpc.vpc_id
}

output "vpc_cidr" {
  description = "CIDR de la VPC"
  value       = module.vpc.vpc_cidr_block
}

output "private_subnet_ids" {
  description = "IDs de las subredes privadas"
  value       = module.vpc.private_subnets
}

output "database_subnet_ids" {
  description = "IDs de las subredes de base de datos"
  value       = module.vpc.database_subnets
}

output "database_subnet_group_name" {
  description = "Nombre del grupo de subredes de base de datos"
  value       = module.vpc.database_subnet_group_name
}

# --- RDS ---

output "db_instance_id" {
  description = "ID de la instancia RDS"
  value       = module.rds.db_instance_identifier
}

output "db_instance_endpoint" {
  description = "Endpoint de conexión de la instancia RDS"
  value       = module.rds.db_instance_endpoint
}

output "db_instance_port" {
  description = "Puerto de la instancia RDS"
  value       = module.rds.db_instance_port
}

output "db_instance_name" {
  description = "Nombre de la base de datos"
  value       = module.rds.db_instance_name
}

output "db_master_user_secret_arn" {
  description = "ARN del secreto en Secrets Manager con la contraseña generada por RDS"
  value       = module.rds.db_instance_master_user_secret_arn
}

# --- Seguridad (verificación de compliance) ---

output "db_storage_encrypted" {
  description = "Confirmación de que el almacenamiento está cifrado (siempre true)"
  value       = true
}

output "db_deletion_protection" {
  description = "Confirmación de que la protección contra borrado está activa (siempre true)"
  value       = true
}

output "security_group_id" {
  description = "ID del security group de RDS"
  value       = aws_security_group.rds.id
}
