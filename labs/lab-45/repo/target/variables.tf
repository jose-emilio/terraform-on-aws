variable "project" {
  type        = string
  description = "Prefijo utilizado en el nombre de todos los recursos del modulo target."
  default     = "lab45"
}

variable "region" {
  type        = string
  description = "Region de AWS donde se despliegan los recursos."
  default     = "us-east-1"
}

variable "environment" {
  type        = string
  description = "Entorno de despliegue (dev, staging, prod)."
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "El entorno debe ser dev, staging o prod."
  }
}

variable "log_retention_days" {
  type        = number
  description = "Dias de retencion del grupo de logs de CloudWatch."
  default     = 365

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365], var.log_retention_days)
    error_message = "El valor debe ser uno de los periodos validos de CloudWatch Logs."
  }
}
