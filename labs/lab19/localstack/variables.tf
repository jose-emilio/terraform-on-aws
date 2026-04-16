variable "region" {
  type        = string
  description = "Region (fija en LocalStack)"
  default     = "us-east-1"
}

variable "app_cidr" {
  type        = string
  description = "CIDR block de la VPC app"
  default     = "10.15.0.0/16"
}

variable "db_cidr" {
  type        = string
  description = "CIDR block de la VPC db"
  default     = "10.16.0.0/16"
}

variable "c_cidr" {
  type        = string
  description = "CIDR block de la VPC C"
  default     = "10.17.0.0/16"
}

variable "project_name" {
  type        = string
  description = "Nombre del proyecto, usado en tags y nombres de recursos"
  default     = "lab19"
}

variable "environment" {
  type        = string
  description = "Entorno de despliegue (lab, dev, staging, production)"
  default     = "lab"
}
