# ID de la cuenta AWS activa. Seguro para mostrar en logs y pipelines de CI/CD.
output "account_id" {
  description = "ID de la cuenta AWS donde se ejecuta Terraform"
  value       = data.aws_caller_identity.current.account_id
}

# El ARN contiene el nombre del usuario o rol que ejecuta Terraform.
# sensitive = true impide que aparezca en texto plano en los logs de CI/CD
# y en la salida de terraform plan/apply. Solo es visible con terraform output.
output "caller_arn" {
  description = "ARN de la identidad que ejecuta Terraform"
  value       = data.aws_caller_identity.current.arn
  sensitive   = true
}

output "caller_user_id" {
  description = "User ID de la identidad que ejecuta Terraform"
  value       = data.aws_caller_identity.current.user_id
}

# Nombre y descripción de la región activa, obtenidos sin hardcodear
output "region" {
  description = "Región activa del provider"
  value       = "${data.aws_region.current.name} (${data.aws_region.current.description})"
}

# ID de la VPC localizada por tag, sin haberlo hardcodeado en ningún momento
output "production_vpc_id" {
  description = "ID de la VPC de producción encontrada por tag"
  value       = data.aws_vpc.production.id
}

# Lista de IDs de subredes lista para ser consumida por otros módulos
output "production_subnet_ids" {
  description = "IDs de las subredes de la VPC de producción"
  value       = data.aws_subnets.production.ids
}

# Map ID → IP privada de las instancias en ejecución en la VPC
output "production_instance_ips" {
  description = "IPs privadas de las instancias EC2 en ejecución en la VPC de producción"
  value       = local.instance_private_ips
}

# ARN de la política ReadOnlyAccess, resuelto dinámicamente por nombre
output "read_only_policy_arn" {
  description = "ARN de la política IAM ReadOnlyAccess"
  value       = data.aws_iam_policy.read_only.arn
}

# Lista completa de AZs disponibles
output "available_az_names" {
  description = "Nombres de todas las zonas de disponibilidad activas en la región"
  value       = local.az_names
}

# Lista filtrada con la cláusula if de la expresión for
output "primary_az_names" {
  description = "AZs principales (sufijos configurados en var.primary_az_suffixes)"
  value       = local.primary_az_names
}

# Ruta al reporte de auditoría generado localmente
output "audit_report_path" {
  description = "Ruta del archivo de reporte de auditoría generado"
  value       = local_file.audit_report.filename
}
