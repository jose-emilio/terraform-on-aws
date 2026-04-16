variable "vpc_cidr" {
  type        = string
  description = "CIDR block de la VPC. Se validará con postcondition que sea un rango privado RFC 1918"
}

variable "project_name" {
  type        = string
  description = "Nombre del proyecto, usado en tags y nombres de recursos"
}

variable "environment" {
  type        = string
  description = "Entorno de despliegue"
  default     = "lab"
}

variable "tags" {
  type        = map(string)
  description = "Etiquetas adicionales para los recursos de red"
  default     = {}
}
