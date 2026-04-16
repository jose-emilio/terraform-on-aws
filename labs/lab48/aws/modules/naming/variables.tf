variable "app" {
  type        = string
  description = "Nombre corto de la aplicación (ej: myapp, billing, auth)."

  validation {
    condition     = can(regex("^[a-z0-9]+$", var.app))
    error_message = "El nombre de la aplicacion solo puede contener letras minúsculas y números."
  }
}

variable "env" {
  type        = string
  description = "Código de entorno de dos o tres letras (ej: dev, stg, prd)."

  validation {
    condition     = contains(["dev", "stg", "prd"], var.env)
    error_message = "El entorno debe ser dev, stg o prd."
  }
}

variable "component" {
  type        = string
  description = "Componente funcional del sistema (ej: api, compute, data, network, auth)."

  validation {
    condition     = can(regex("^[a-z0-9]+$", var.component))
    error_message = "El componente solo puede contener letras minúsculas y números."
  }
}

variable "resource" {
  type        = string
  description = "Abreviatura del tipo de recurso AWS (ej: vpc, alb, asg, rds, sn, sg, rt)."

  validation {
    condition     = can(regex("^[a-z0-9]+$", var.resource))
    error_message = "El tipo de recurso solo puede contener letras minúsculas y números."
  }
}
