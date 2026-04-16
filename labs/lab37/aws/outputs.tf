output "instance_id" {
  description = "ID de la instancia EC2"
  value       = aws_instance.web.id
}

output "public_ip" {
  description = "IP publica de la instancia"
  value       = aws_instance.web.public_ip
}

output "app_version_deployed" {
  description = "Version de la aplicacion actualmente desplegada (segun triggers_replace)"
  value       = terraform_data.app_deploy.triggers_replace["app_version"]
}

output "ssh_command" {
  description = "Comando SSH para conectarse manualmente a la instancia"
  value       = "ssh -i ${var.ssh_private_key_path} ec2-user@${aws_instance.web.public_ip}"
}

output "web_url" {
  description = "URL publica de la aplicacion desplegada"
  value       = "http://${aws_instance.web.public_ip}"
}

output "version_json_url" {
  description = "Endpoint JSON con la version desplegada (util para healthchecks)"
  value       = "http://${aws_instance.web.public_ip}/version.json"
}
