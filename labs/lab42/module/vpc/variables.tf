variable "name" {
  type        = string
  description = "Prefijo de nombre aplicado a todos los recursos del modulo."
}

variable "cidr_block" {
  type        = string
  description = "CIDR block del VPC. Debe ser un rango /16 a /28."
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrnetmask(var.cidr_block))
    error_message = "cidr_block debe ser un CIDR IPv4 valido (p. ej. 10.0.0.0/16)."
  }
}

variable "public_subnet_cidrs" {
  type        = list(string)
  description = "Lista de CIDRs para las subredes publicas. Deben estar dentro del cidr_block del VPC."
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_subnet_cidrs" {
  type        = list(string)
  description = "Lista de CIDRs para las subredes privadas. Deben estar dentro del cidr_block del VPC."
  default     = ["10.0.101.0/24", "10.0.102.0/24"]
}

variable "availability_zones" {
  type        = list(string)
  description = "Zonas de disponibilidad donde crear las subredes. El numero de AZs debe coincidir con la cantidad de subredes publicas y privadas."
  default     = ["us-east-1a", "us-east-1b"]

  validation {
    condition     = length(var.availability_zones) >= 1
    error_message = "Se requiere al menos una zona de disponibilidad."
  }
}

variable "enable_dns_hostnames" {
  type        = bool
  description = "Habilitar nombres DNS para instancias en el VPC."
  default     = true
}

variable "enable_dns_support" {
  type        = bool
  description = "Habilitar soporte DNS en el VPC."
  default     = true
}

variable "tags" {
  type        = map(string)
  description = "Tags adicionales aplicados a todos los recursos del modulo."
  default     = {}
}
