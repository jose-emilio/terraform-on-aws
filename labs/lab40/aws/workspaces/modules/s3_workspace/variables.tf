variable "project" {
  type        = string
  description = "Prefijo del proyecto — se usa en nombres de recursos y tags"
}

variable "environment" {
  type        = string
  description = "Nombre del entorno (dev, staging, prod)"
}

variable "account_id" {
  type        = string
  description = "ID de la cuenta AWS — se incluye en el nombre del bucket para garantizar unicidad global"
}
