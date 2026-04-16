# Laboratorio 8 — Fase 1: Adopción de infraestructura existente.
#
# Antes de continuar, crea el bucket fuera de Terraform:
#   aws s3 mb s3://$TF_VAR_bucket_name --region us-east-1
#
# Luego genera la configuración HCL automáticamente:
#   terraform plan -generate-config-out=generated.tf
#
# Revisa generated.tf, integra el bloque resource en este archivo
# y elimina generated.tf. El bloque import{} puede mantenerse (es idempotente).

import {
  to = aws_s3_bucket.app
  id = var.bucket_name
}
