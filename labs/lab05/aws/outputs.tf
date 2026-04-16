# Muestra el script de User Data renderizado para verificar que la
# interpolación de variables y las directivas %{for}/%{if} son correctas
# antes de que llegue a la instancia EC2.
output "user_data_rendered" {
  description = "Script de bootstrap generado por templatefile()"
  value       = local.user_data
}

# Expone el map de tags generado por la expresión for para verificar
# que upper() transformó correctamente los nombres de servicio
output "service_tags" {
  description = "Tags de servicios generados con la expresión for"
  value       = local.service_tags
}

output "key_pair_name" {
  description = "Nombre del key pair registrado en AWS"
  value       = aws_key_pair.lab4.key_name
}

output "launch_template_id" {
  description = "ID del launch template creado"
  value       = aws_launch_template.app.id
}

# Ruta al archivo de configuración generado localmente
output "config_file_path" {
  description = "Ruta del archivo de configuración generado por local_file"
  value       = local_file.app_config.filename
}
