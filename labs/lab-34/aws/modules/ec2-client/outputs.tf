output "instance_id" {
  description = "ID de la instancia EC2"
  value       = aws_instance.app.id
}

output "instance_az" {
  description = "AZ donde se despliega la instancia"
  value       = aws_instance.app.availability_zone
}

output "security_group_id" {
  description = "ID del Security Group de la instancia EC2"
  value       = aws_security_group.ec2.id
}

output "ebs_volume_id" {
  description = "ID del volumen EBS de datos"
  value       = aws_ebs_volume.data.id
}

output "ebs_volume_arn" {
  description = "ARN del volumen EBS de datos"
  value       = aws_ebs_volume.data.arn
}
