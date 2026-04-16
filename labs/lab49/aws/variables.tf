variable "region" {
  type        = string
  description = "Región AWS donde se despliegan todos los recursos del laboratorio."
  default     = "us-east-1"
}

variable "environment" {
  type        = string
  description = "Nombre del entorno (dev, stg, prd). Se propaga como tag a todos los recursos."
  default     = "prd"
}

variable "project" {
  type        = string
  description = "Nombre del proyecto. Se usa como tag y como prefijo en los nombres de recursos."
  default     = "lab49"
}
