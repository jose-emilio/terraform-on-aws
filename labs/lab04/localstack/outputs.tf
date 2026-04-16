# Outputs de auditoría: permiten verificar en qué cuenta y con qué identidad
# se ejecutó el despliegue, especialmente útil en entornos multi-cuenta.
output "account_id" {
  description = "ID de la cuenta AWS activa"
  value       = data.aws_caller_identity.current.account_id
}

output "caller_arn" {
  description = "ARN de la identidad que ejecuta Terraform"
  value       = data.aws_caller_identity.current.arn
}

# Expresión for que transforma el map de recursos en un map nombre → ARN,
# más legible que una lista de ARNs sin etiqueta
output "iam_user_arns" {
  description = "ARNs de los usuarios IAM creados"
  value       = { for name, user in aws_iam_user.team : name => user.arn }
}

output "launch_template_id" {
  description = "ID del launch template creado"
  value       = aws_launch_template.app.id
}
