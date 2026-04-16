variable "region" {
  type        = string
  description = "Region AWS donde se despliegan los recursos"
  default     = "us-east-1"
}

variable "project" {
  type        = string
  description = "Prefijo que identifica todos los recursos del laboratorio"
  default     = "lab33"
}

variable "transition_days" {
  type        = number
  description = "Dias hasta mover objetos a Glacier Flexible Retrieval"
  default     = 90
}

variable "expiration_days" {
  type        = number
  description = "Dias hasta eliminar objetos definitivamente"
  default     = 365
}
