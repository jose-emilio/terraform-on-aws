variable "bucket_name" {
  type        = string
  description = "Nombre del bucket S3. Debe ser globalmente unico"
}

variable "enable_versioning" {
  type        = bool
  description = "Habilitar versionado en el bucket"
  default     = true
}

variable "force_destroy" {
  type        = bool
  description = "Permitir destruir el bucket aunque contenga objetos"
  default     = false
}

variable "tags" {
  type        = map(string)
  description = "Etiquetas adicionales que se combinan con las etiquetas por defecto del modulo"
  default     = {}
}
