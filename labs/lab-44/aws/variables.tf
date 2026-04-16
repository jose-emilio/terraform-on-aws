variable "region" {
  type        = string
  description = "Region de AWS donde se despliega la infraestructura."
  default     = "us-east-1"
}

variable "vpc_cidr" {
  type        = string
  description = "Bloque CIDR de la VPC del laboratorio."
  default     = "10.44.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "El bloque CIDR debe ser valido (p. ej. 10.44.0.0/16)."
  }
}

variable "project" {
  type        = string
  description = "Prefijo usado en el nombre de todos los recursos del laboratorio."
  default     = "lab44"
}

variable "instance_type" {
  type        = string
  description = "Tipo de instancia EC2 ARM64 (Graviton) para las instancias de la aplicacion."
  default     = "t4g.micro"

  validation {
    condition     = can(regex("^[a-z][0-9][a-z]?g\\.(nano|micro|small|medium|large|xlarge|2xlarge)$", var.instance_type))
    error_message = "El tipo de instancia debe ser un tipo EC2 Graviton (ARM64), p. ej. t4g.micro."
  }
}

variable "asg_desired_capacity" {
  type        = number
  description = "Numero deseado de instancias en el ASG al arrancar."
  default     = 4

  validation {
    condition     = var.asg_desired_capacity >= 1 && var.asg_desired_capacity <= 10
    error_message = "La capacidad deseada debe estar entre 1 y 10 instancias."
  }
}

variable "asg_min_size" {
  type        = number
  description = "Numero minimo de instancias en el ASG."
  default     = 4

  validation {
    condition     = var.asg_min_size >= 1 && var.asg_min_size <= 10
    error_message = "El minimo debe estar entre 1 y 10 instancias."
  }
}

variable "asg_max_size" {
  type        = number
  description = "Numero maximo de instancias en el ASG."
  default     = 8

  validation {
    condition     = var.asg_max_size >= 1 && var.asg_max_size <= 20
    error_message = "El maximo debe estar entre 1 y 20 instancias."
  }
}

variable "error_rate_threshold" {
  type        = number
  description = "Porcentaje de errores 5xx sobre el total de peticiones que dispara el rollback automatico."
  default     = 1

  validation {
    condition     = var.error_rate_threshold > 0 && var.error_rate_threshold <= 100
    error_message = "El umbral debe ser un porcentaje entre 0 (exclusivo) y 100."
  }
}

