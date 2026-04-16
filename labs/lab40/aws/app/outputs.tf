output "security_group_id" {
  description = "ID del security group de la capa de aplicacion"
  value       = aws_security_group.app.id
}

# Outputs que demuestran que los valores de red se leyeron correctamente
# del estado remoto de network/ sin hardcodear ningun ID.
output "vpc_id_from_remote_state" {
  description = "VPC ID leido del estado remoto de network/"
  value       = data.terraform_remote_state.network.outputs.vpc_id
}

output "public_subnet_id_from_remote_state" {
  description = "Subnet publica leida del estado remoto de network/"
  value       = data.terraform_remote_state.network.outputs.public_subnet_id
}

output "network_state_bucket" {
  description = "Bucket S3 desde el que se leyo el estado remoto de network/"
  value       = var.state_bucket
}
