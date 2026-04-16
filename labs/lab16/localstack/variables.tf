variable "region" {
  type        = string
  description = "Región (fija en LocalStack)"
  default     = "us-east-1"
}

variable "vpc_cidr" {
  type        = string
  description = "CIDR block de la VPC (debe ser un rango RFC 1918)"
  default     = "10.12.0.0/16"
}

variable "project_name" {
  type        = string
  description = "Nombre del proyecto, usado en tags y nombres de recursos"
  default     = "lab16"
}

variable "environment" {
  type        = string
  description = "Entorno de despliegue (lab, dev, staging, production)"
  default     = "lab"
}
