variable "region" {
  type        = string
  description = "Region de AWS donde se despliega la infraestructura"
  default     = "us-east-1"
}

variable "vpc_cidr" {
  type        = string
  description = "CIDR block de la VPC"
  default     = "10.17.0.0/16"
}

variable "project_name" {
  type        = string
  description = "Nombre del proyecto, usado en tags y nombres de recursos"
  default     = "lab21"
}

variable "environment" {
  type        = string
  description = "Entorno de despliegue (lab, dev, staging, production)"
  default     = "lab"
}

variable "internal_domain" {
  type        = string
  description = "Nombre del dominio interno para la Zona Hospedada Privada"
  default     = "app.internal"
}
