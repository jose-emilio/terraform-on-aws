output "file_system_id" {
  description = "ID del EFS File System"
  value       = aws_efs_file_system.main.id
}

output "file_system_arn" {
  description = "ARN del EFS File System"
  value       = aws_efs_file_system.main.arn
}

output "file_system_dns_name" {
  description = "DNS name del EFS para construir el comando de montaje"
  value       = aws_efs_file_system.main.dns_name
}

output "access_point_id" {
  description = "ID del EFS Access Point de la aplicacion"
  value       = aws_efs_access_point.app.id
}

output "access_point_arn" {
  description = "ARN del EFS Access Point de la aplicacion"
  value       = aws_efs_access_point.app.arn
}

output "security_group_id" {
  description = "ID del Security Group del EFS"
  value       = aws_security_group.efs.id
}

output "mount_target_ids" {
  description = "Mapa AZ → ID del mount target"
  value       = { for k, v in aws_efs_mount_target.main : k => v.id }
}
