variable "region" {
  type        = string
  description = "Region de AWS donde se despliega la infraestructura."
  default     = "us-east-1"
}

variable "project" {
  type        = string
  description = "Prefijo usado en el nombre de todos los recursos del laboratorio."
  default     = "lab46"
}

variable "alert_email" {
  type        = string
  description = "Direccion de correo que recibe las alertas de la Composite Alarm."

  validation {
    condition     = can(regex("^[^@]+@[^@]+\\.[^@]+$", var.alert_email))
    error_message = "El valor debe ser una direccion de correo electronico valida."
  }
}

variable "instance_type" {
  type        = string
  description = "Tipo de instancia EC2 que ejecuta el generador de logs."
  default     = "t4g.small"
}

variable "log_retention_days" {
  type        = number
  description = "Dias de retencion del log group de la aplicacion."
  default     = 30

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365], var.log_retention_days)
    error_message = "El valor debe ser uno de los periodos de retencion validos de CloudWatch Logs."
  }
}

variable "cpu_threshold" {
  type        = number
  description = "Porcentaje de CPU que activa la alarma cpu-high (componente de la Composite Alarm)."
  default     = 80

  validation {
    condition     = var.cpu_threshold > 0 && var.cpu_threshold <= 100
    error_message = "El umbral de CPU debe estar entre 1 y 100."
  }
}

variable "anomaly_band_width" {
  type        = number
  description = "Numero de desviaciones tipicas para la banda de Anomaly Detection (2 = ~95% de confianza)."
  default     = 2

  validation {
    condition     = var.anomaly_band_width > 0
    error_message = "La anchura de la banda debe ser un numero positivo."
  }
}
