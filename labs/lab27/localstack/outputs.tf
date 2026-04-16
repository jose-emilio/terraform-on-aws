# AMI seleccionada dinámicamente por el data source
output "ami_id" {
  description = "ID de la AMI de Amazon Linux 2023 seleccionada"
  value       = data.aws_ami.al2023.id
}

output "ami_name" {
  description = "Nombre de la AMI seleccionada"
  value       = data.aws_ami.al2023.name
}

# Instancia EC2
output "instance_id" {
  description = "ID de la instancia EC2"
  value       = aws_instance.web.id
}

output "public_ip" {
  description = "IP publica de la instancia (si tiene)"
  value       = aws_instance.web.public_ip
}

# IAM
output "instance_profile_arn" {
  description = "ARN del Instance Profile asociado a la instancia"
  value       = aws_iam_instance_profile.ec2.arn
}

output "iam_role_name" {
  description = "Nombre del rol IAM de la instancia"
  value       = aws_iam_role.ec2.name
}

# User Data renderizado para verificación pre-apply
output "user_data_rendered" {
  description = "Script de bootstrap generado por templatefile()"
  value       = local.user_data
}

# Security Group
output "security_group_id" {
  description = "ID del security group de la instancia"
  value       = aws_security_group.web.id
}
