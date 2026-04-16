variable "bucket_name" {
  type        = string
  description = "Nombre del bucket S3. Debe ser globalmente unico."

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.bucket_name))
    error_message = "El nombre del bucket solo puede contener minusculas, numeros, puntos y guiones (3-63 caracteres)."
  }
}

variable "environment" {
  type        = string
  description = "Entorno de despliegue. Controla el nivel de proteccion del bucket."
  default     = "lab"

  validation {
    condition     = contains(["lab", "dev", "staging", "production"], var.environment)
    error_message = "El entorno debe ser uno de: lab, dev, staging, production."
  }
}

variable "enable_versioning" {
  type        = bool
  description = "Habilitar versionado en el bucket. Recomendado para datos criticos."
  default     = true
}

variable "enable_encryption" {
  type        = bool
  description = "Habilitar cifrado SSE-S3 en el bucket."
  default     = true
}

variable "enable_access_logging" {
  type        = bool
  description = "Habilitar logging de acceso a un bucket destino."
  default     = false
}

variable "logging_target_bucket" {
  type        = string
  description = "Nombre del bucket destino para access logs. Requerido si enable_access_logging = true."
  default     = ""
}

variable "logging_target_prefix" {
  type        = string
  description = "Prefijo para los logs de acceso dentro del bucket destino."
  default     = "logs/"
}

variable "force_destroy" {
  type        = bool
  description = "Permitir destruir el bucket aunque contenga objetos. Usar false en produccion."
  default     = false
}

variable "tags" {
  type        = map(string)
  description = "Etiquetas adicionales que se combinan con las del modulo."
  default     = {}
}
