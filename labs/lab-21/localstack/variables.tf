variable "region" {
  type        = string
  description = "Región declarada al provider AWS. En LocalStack es informativa (todos los servicios responden bajo el mismo endpoint local), pero se respeta para mantener paridad con la versión aws/."
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
