variable "region" {
  type    = string
  default = "us-east-1"
}

variable "project" {
  type        = string
  description = "Prefijo que identifica todos los recursos del laboratorio"
  default     = "lab28"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "instance_type" {
  type    = string
  default = "t4g.small"
}

variable "min_size" {
  type        = number
  description = "Número mínimo de instancias en el ASG"
  default     = 2
}

variable "max_size" {
  type        = number
  description = "Número máximo de instancias en el ASG"
  default     = 6
}

variable "desired_capacity" {
  type        = number
  description = "Capacidad deseada inicial del ASG"
  default     = 2
}

variable "app_version" {
  type        = string
  description = "Versión de la aplicación embebida en user_data. Cambiarla genera una nueva versión del Launch Template y activa el instance_refresh."
  default     = "v1"
}
