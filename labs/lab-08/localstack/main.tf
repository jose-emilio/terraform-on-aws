# Laboratorio 8 — Fase 1: Adopción de infraestructura existente.
#
# Antes de continuar, crea el bucket fuera de Terraform en LocalStack:
#   aws --profile localstack s3 mb s3://lab8-import-local
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
