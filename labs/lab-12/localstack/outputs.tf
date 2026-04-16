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

