variable "region" {
  type        = string
  description = "Región de AWS donde se despliega la infraestructura"
  default     = "us-east-1"
}

variable "project_name" {
  type        = string
  description = "Nombre del proyecto, usado en tags y nombres de recursos"
  default     = "lab25"
}

variable "environment" {
  type        = string
  description = "Entorno de despliegue (lab, dev, staging, production)"
  default     = "lab"

  validation {
    condition     = contains(["lab", "dev", "staging", "production"], var.environment)
    error_message = "El entorno debe ser uno de: lab, dev, staging, production."
  }
}

variable "bucket_suffix" {
  type        = string
  description = "Sufijo para el nombre del bucket (se combina con project_name y account_id)"
  default     = "data"
}
