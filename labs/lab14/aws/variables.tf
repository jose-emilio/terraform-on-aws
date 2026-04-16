variable "region" {
  type        = string
  description = "Región de AWS donde se despliega la infraestructura"
  default     = "us-east-1"
}

variable "project_name" {
  type        = string
  description = "Nombre del proyecto, usado en tags y nombres de recursos"
  default     = "lab14"
}

variable "environment" {
  type        = string
  description = "Entorno de despliegue (lab, dev, staging, production)"
  default     = "lab"
}

variable "vpc_cidr" {
  type        = string
  description = "CIDR block de la VPC donde se desplegará la base de datos"
  default     = "10.14.0.0/16"
}

variable "db_name" {
  type        = string
  description = "Nombre de la base de datos inicial en la instancia RDS"
  default     = "appdb"
}

variable "db_username" {
  type        = string
  description = "Nombre del usuario maestro de la base de datos"
  default     = "dbadmin"
}
