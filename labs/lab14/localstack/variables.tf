variable "project_name" {
  type        = string
  description = "Nombre del proyecto, usado en tags y nombres de recursos"
  default     = "lab14"
}

variable "environment" {
  type        = string
  description = "Entorno de despliegue"
  default     = "lab"
}

variable "vpc_cidr" {
  type        = string
  description = "CIDR block de la VPC"
  default     = "10.14.0.0/16"
}

variable "db_name" {
  type        = string
  description = "Nombre de la base de datos inicial"
  default     = "appdb"
}

variable "db_username" {
  type        = string
  description = "Nombre del usuario maestro de la base de datos"
  default     = "dbadmin"
}
