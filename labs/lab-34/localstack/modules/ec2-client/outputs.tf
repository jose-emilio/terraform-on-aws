output "instance_id" {
  value = aws_instance.app.id
}

output "security_group_id" {
  value = aws_security_group.ec2.id
}

output "ebs_volume_id" {
  value = aws_ebs_volume.data.id
}

output "ebs_volume_arn" {
  value = aws_ebs_volume.data.arn
}
