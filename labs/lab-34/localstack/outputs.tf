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
