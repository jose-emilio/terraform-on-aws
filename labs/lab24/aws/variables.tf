variable "region" {
  type        = string
  description = "Región de AWS donde se despliega la infraestructura"
  default     = "us-east-1"
}

variable "project_name" {
  type        = string
  description = "Nombre del proyecto, usado en tags y nombres de recursos"
  default     = "lab24"
}

variable "environment" {
  type        = string
  description = "Entorno de despliegue (lab, dev, staging, production)"
  default     = "lab"
}
