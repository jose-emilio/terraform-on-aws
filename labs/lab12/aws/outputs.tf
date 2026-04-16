output "iam_group_name" {
  description = "Nombre del grupo IAM de desarrolladores"
  value       = aws_iam_group.developers.name
}

output "iam_group_arn" {
  description = "ARN del grupo IAM de desarrolladores"
  value       = aws_iam_group.developers.arn
}

output "iam_user_name" {
  description = "Nombre del usuario IAM dev-01"
  value       = aws_iam_user.dev01.name
}

output "iam_user_arn" {
  description = "ARN del usuario IAM dev-01"
  value       = aws_iam_user.dev01.arn
}

output "ec2_role_name" {
  description = "Nombre del rol IAM para EC2"
  value       = aws_iam_role.ec2.name
}

output "ec2_role_arn" {
  description = "ARN del rol IAM para EC2"
  value       = aws_iam_role.ec2.arn
}

output "instance_profile_name" {
  description = "Nombre del Instance Profile"
  value       = aws_iam_instance_profile.ec2.name
}

output "instance_id" {
  description = "ID de la instancia EC2"
  value       = aws_instance.app.id
}

output "instance_private_ip" {
  description = "IP privada de la instancia EC2"
  value       = aws_instance.app.private_ip
}

output "verify_log_command" {
  description = "Comando SSM para leer el log de verificación de identidad"
  value       = "aws ssm start-session --target ${aws_instance.app.id} --document-name AWS-StartInteractiveCommand --parameters command='cat /var/log/lab12-verify.log'"
}

output "ssm_session_command" {
  description = "Comando para abrir una sesión interactiva en la instancia via SSM"
  value       = "aws ssm start-session --target ${aws_instance.app.id}"
}

output "get_caller_identity_command" {
  description = "Comando para verificar la identidad activa desde tu terminal local"
  value       = "aws sts get-caller-identity"
}
