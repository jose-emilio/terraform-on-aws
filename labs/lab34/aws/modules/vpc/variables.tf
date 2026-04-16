variable "project" {
  type        = string
  description = "Prefijo para nombrar los recursos del modulo"
}

variable "tags" {
  type        = map(string)
  description = "Etiquetas comunes a todos los recursos del modulo"
}

variable "cidr_block" {
  type        = string
  description = "CIDR de la VPC"
  default     = "10.30.0.0/16"
}

variable "private_subnets" {
  type        = map(string)
  description = "Mapa AZ → CIDR de las subnets privadas"
}

variable "public_subnets" {
  type        = map(string)
  description = "Mapa AZ → CIDR de las subnets publicas. Necesarias para alojar el NAT Gateway."
}
