# --- Red ---

output "vpc_id" {
  description = "ID de la VPC"
  value       = module.corporate_rds.vpc_id
}

output "vpc_cidr" {
  description = "CIDR de la VPC"
  value       = module.corporate_rds.vpc_cidr
}

output "private_subnet_ids" {
  description = "IDs de las subredes privadas"
  value       = module.corporate_rds.private_subnet_ids
}

# --- Base de datos ---

output "db_endpoint" {
  description = "Endpoint de conexión de la instancia RDS"
  value       = module.corporate_rds.db_instance_endpoint
}

output "db_port" {
  description = "Puerto de la instancia RDS"
  value       = module.corporate_rds.db_instance_port
}

output "db_name" {
  description = "Nombre de la base de datos"
  value       = module.corporate_rds.db_instance_name
}

output "db_secret_arn" {
  description = "ARN del secreto con la contraseña (gestionada por RDS)"
  value       = module.corporate_rds.db_master_user_secret_arn
}

# --- Compliance ---

output "db_storage_encrypted" {
  description = "Confirmación: almacenamiento cifrado"
  value       = module.corporate_rds.db_storage_encrypted
}

output "db_deletion_protection" {
  description = "Confirmación: protección contra borrado"
  value       = module.corporate_rds.db_deletion_protection
}
