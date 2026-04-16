# Añadir tras la Fase 1, una vez que aws_s3_bucket.app esté gestionado:
#
# output "bucket_id" {
#   description = "ID del bucket adoptado por Terraform (LocalStack)"
#   value       = aws_s3_bucket.app.id
# }
#
# output "bucket_arn" {
#   description = "ARN del bucket (LocalStack)"
#   value       = aws_s3_bucket.app.arn
# }
#
# Tras la Fase 2 (renombrado), actualizar la referencia a aws_s3_bucket.application.
# Tras la Fase 3 (remoción), eliminar los outputs.
