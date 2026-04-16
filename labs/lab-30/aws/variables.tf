variable "region" {
  type    = string
  default = "us-east-1"
}

variable "project" {
  type        = string
  description = "Prefijo que identifica todos los recursos del laboratorio"
  default     = "lab30"
}

variable "runtime" {
  type        = string
  description = "Runtime de Python para la función Lambda"
  default     = "python3.12"
}

variable "app_env" {
  type        = string
  description = "Entorno de despliegue (development, staging, production)"
  default     = "production"
}
