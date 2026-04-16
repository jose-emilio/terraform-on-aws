variable "project_name" {
  type        = string
  description = "Nombre del proyecto, usado como prefijo en los parámetros SSM"
}

variable "db_config" {
  type = object({
    engine            = string
    engine_version    = string
    instance_class    = string
    allocated_storage = number
    port              = optional(number, 3306)
    multi_az          = optional(bool, false)
    backup_retention_days = optional(number, 7)
  })

  description = "Configuración de la base de datos. 'engine', 'engine_version', 'instance_class' y 'allocated_storage' son obligatorios. 'port', 'multi_az' y 'backup_retention_days' son opcionales con valores por defecto."

  validation {
    condition     = contains(["mysql", "postgres", "mariadb"], var.db_config.engine)
    error_message = "El motor de base de datos debe ser uno de: mysql, postgres, mariadb."
  }

  validation {
    condition     = var.db_config.allocated_storage >= 20 && var.db_config.allocated_storage <= 1000
    error_message = "El almacenamiento debe estar entre 20 y 1000 GB."
  }
}

variable "db_password" {
  type        = string
  description = "Contraseña del usuario administrador de la base de datos. No aparece en los logs de consola."
  sensitive   = true

  validation {
    condition     = length(var.db_password) >= 12
    error_message = "La contraseña debe tener al menos 12 caracteres."
  }

  validation {
    condition     = can(regex("[A-Z]", var.db_password)) && can(regex("[a-z]", var.db_password)) && can(regex("[0-9]", var.db_password))
    error_message = "La contraseña debe contener al menos una mayúscula, una minúscula y un número."
  }
}

variable "tags" {
  type        = map(string)
  description = "Etiquetas adicionales para los recursos del módulo"
  default     = {}
}
