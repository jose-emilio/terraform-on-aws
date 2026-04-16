variable "bucket_name" {
  type        = string
  description = "Nombre del bucket S3. Debe comenzar con el prefijo corporativo 'empresa-'"

  validation {
    condition     = can(regex("^empresa-[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.bucket_name))
    error_message = "El nombre del bucket debe comenzar con 'empresa-', contener solo minúsculas, números, puntos y guiones, y tener entre 10 y 63 caracteres."
  }
}

variable "force_destroy" {
  type        = bool
  description = "Permitir destruir el bucket aunque contenga objetos"
  default     = false
}

variable "tags" {
  type        = map(string)
  description = "Etiquetas adicionales que se combinan con las del módulo"
  default     = {}
}
