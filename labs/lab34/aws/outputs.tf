output "vpc_id" {
  description = "ID de la VPC"
  value       = module.vpc.vpc_id
}

output "instance_id" {
  description = "ID de la instancia EC2"
  value       = module.ec2.instance_id
}

output "ebs_volume_id" {
  description = "ID del volumen EBS gp3"
  value       = module.ec2.ebs_volume_id
}

output "ebs_volume_arn" {
  description = "ARN del volumen EBS gp3"
  value       = module.ec2.ebs_volume_arn
}

output "dlm_policy_id" {
  description = "ID de la politica DLM de snapshots automaticos"
  value       = aws_dlm_lifecycle_policy.ebs_backup.id
}

output "efs_file_system_id" {
  description = "ID del EFS File System"
  value       = module.efs_share.file_system_id
}

output "efs_dns_name" {
  description = "DNS name del EFS para construir comandos de montaje"
  value       = module.efs_share.file_system_dns_name
}

output "efs_access_point_id" {
  description = "ID del EFS Access Point de la aplicacion"
  value       = module.efs_share.access_point_id
}

output "efs_access_point_arn" {
  description = "ARN del EFS Access Point (usar en el comando de montaje)"
  value       = module.efs_share.access_point_arn
}

output "efs_mount_targets" {
  description = "Mapa AZ → ID del mount target"
  value       = module.efs_share.mount_target_ids
}

output "mount_command" {
  description = "Comando para montar el EFS via Access Point en la instancia EC2"
  value       = "sudo mount -t efs -o tls,accesspoint=${module.efs_share.access_point_id} ${module.efs_share.file_system_id}:/ /mnt/efs"
}
