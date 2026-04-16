variable "primary_region" {
  type        = string
  description = "Region AWS primaria donde se desplegaran los recursos principales"
  default     = "us-east-1"
}

variable "secondary_region" {
  type        = string
  description = "Region AWS secundaria para el despliegue global"
  default     = "eu-west-3"
}

variable "project" {
  type        = string
  description = "Prefijo que identifica todos los recursos del laboratorio"
  default     = "lab39"
}

variable "environment" {
  type        = string
  description = "Nombre del entorno (production, staging, dev)"
  default     = "production"

  validation {
    condition     = contains(["production", "staging", "dev"], var.environment)
    error_message = "El entorno debe ser 'production', 'staging' o 'dev'."
  }
}

variable "legacy_bucket_name" {
  type        = string
  description = <<-EOT
    Nombre exacto del bucket S3 existente que se adoptara mediante el bloque
    import de Terraform 1.5+. Dejalo vacio durante el apply inicial; se
    rellena en el Paso 4 del laboratorio cuando se ejecuta el flujo de
    importacion.

    Crear el bucket previamente con:
      aws s3api create-bucket \
        --bucket lab39-legacy-logs-<ACCOUNT_ID> \
        --region us-east-1
  EOT
  default     = ""
}
