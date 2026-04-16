# ── Buckets de workspace ──────────────────────────────────────────────────────
# Estos outputs cambian su expresion a lo largo del laboratorio:
#   Paso 1 (count):    aws_s3_bucket.workspace[*].bucket
#   Paso 2 (for_each): values(aws_s3_bucket.workspace)[*].bucket
#   Paso 3 (modulo):   values(module.workspace)[*].bucket_name
#
# El fichero muestra la expresion del Paso 1. Actualizala junto con main.tf
# en cada fase de refactorizacion.

output "workspace_bucket_names" {
  description = "Nombres de los buckets de workspace por entorno"
  value       = aws_s3_bucket.workspace[*].bucket
}

output "workspace_bucket_arns" {
  description = "ARNs de los buckets de workspace por entorno"
  value       = aws_s3_bucket.workspace[*].arn
}

# ── Parametros de configuracion ───────────────────────────────────────────────
output "config_parameter_count" {
  description = "Numero de parametros SSM de configuracion desplegados"
  value       = length(aws_ssm_parameter.config)
}

output "account_id" {
  description = "ID de la cuenta AWS activa"
  value       = data.aws_caller_identity.current.account_id
}
