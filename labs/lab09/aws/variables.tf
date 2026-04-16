variable "region" {
  type    = string
  default = "us-east-1"
}

variable "is_prod" {
  type        = bool
  default     = false
  description = "Marca el despliegue como producción. Debe ser true solo en el workspace prod."
}
