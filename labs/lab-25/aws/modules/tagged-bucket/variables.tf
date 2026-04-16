variable "bucket_name" {
  type        = string
  description = "Nombre completo del bucket S3"

  validation {
    condition     = length(var.bucket_name) >= 3 && length(var.bucket_name) <= 63
    error_message = "El nombre del bucket debe tener entre 3 y 63 caracteres."
  }

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]*[a-z0-9]$", var.bucket_name))
    error_message = "El nombre del bucket solo puede contener minusculas, numeros, puntos y guiones."
  }
}

variable "project_name" {
  type        = string
  description = "Nombre del proyecto, usado en tags"
}

variable "environment" {
  type        = string
  description = "Entorno de despliegue"
  default     = "lab"

  validation {
    condition     = contains(["lab", "dev", "staging", "production"], var.environment)
    error_message = "El entorno debe ser uno de: lab, dev, staging, production."
  }
}

variable "tags" {
  type        = map(string)
  description = "Etiquetas adicionales que se combinan con las del modulo"
  default     = {}
}
