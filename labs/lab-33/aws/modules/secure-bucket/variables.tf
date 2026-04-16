variable "bucket_name" {
  type        = string
  description = "Nombre del bucket S3"
}

variable "project" {
  type        = string
  description = "Prefijo del proyecto para nombrar recursos KMS"
}

variable "tags" {
  type        = map(string)
  description = "Tags a aplicar a todos los recursos del modulo"
  default     = {}
}

variable "vpc_endpoint_id" {
  type        = string
  description = "ID del VPC Gateway Endpoint de S3 — la bucket policy deniega trafico fuera de este endpoint"
}

variable "transition_days" {
  type        = number
  description = "Dias hasta mover objetos (y versiones no actuales) a Glacier Flexible Retrieval"
  default     = 90
}

variable "expiration_days" {
  type        = number
  description = "Dias hasta eliminar objetos (y versiones no actuales) definitivamente"
  default     = 365
}
