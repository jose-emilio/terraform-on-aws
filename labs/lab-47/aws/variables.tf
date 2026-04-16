variable "region" {
  type        = string
  description = "Región de AWS donde se despliega la infraestructura."
  default     = "us-east-1"
}

variable "project" {
  type        = string
  description = "Prefijo usado en el nombre de todos los recursos del laboratorio."
  default     = "lab47"
}

variable "log_retention_days" {
  type        = number
  description = "Días de retención de los log groups de CloudWatch (Flow Logs y CloudTrail)."
  default     = 30

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365], var.log_retention_days)
    error_message = "Debe ser uno de los periodos de retención válidos de CloudWatch Logs."
  }
}

variable "glacier_transition_days" {
  type        = number
  description = "Días tras los cuales los objetos S3 pasan a Glacier Deep Archive."
  default     = 90

  validation {
    condition     = var.glacier_transition_days >= 1
    error_message = "El numero de dias debe ser al menos 1."
  }
}

variable "firehose_buffer_size_mb" {
  type        = number
  description = "Tamaño del buffer de Kinesis Firehose en MB antes de entregar a S3 (1-128)."
  default     = 5

  validation {
    condition     = var.firehose_buffer_size_mb >= 1 && var.firehose_buffer_size_mb <= 128
    error_message = "El buffer de Firehose debe estar entre 1 y 128 MB."
  }
}

variable "firehose_buffer_interval_seconds" {
  type        = number
  description = "Intervalo del buffer de Kinesis Firehose en segundos antes de entregar a S3 (60-900)."
  default     = 300

  validation {
    condition     = var.firehose_buffer_interval_seconds >= 60 && var.firehose_buffer_interval_seconds <= 900
    error_message = "El intervalo del buffer de Firehose debe estar entre 60 y 900 segundos."
  }
}

variable "vpc_cidr" {
  type        = string
  description = "Bloque CIDR de la VPC del laboratorio."
  default     = "10.47.0.0/16"

  validation {
    condition     = can(cidrnetmask(var.vpc_cidr))
    error_message = "Debe ser un bloque CIDR válido (ej: 10.47.0.0/16)."
  }
}

variable "instance_type" {
  type        = string
  description = "Tipo de instancia EC2 para el generador de tráfico."
  default     = "t4g.small"
}
