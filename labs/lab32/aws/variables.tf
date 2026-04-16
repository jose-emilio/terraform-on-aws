variable "region" {
  type    = string
  default = "us-east-1"
}

variable "project" {
  type        = string
  description = "Prefijo que identifica todos los recursos del laboratorio"
  default     = "lab32"
}

variable "runtime" {
  type        = string
  description = "Runtime de Python para la función Lambda"
  default     = "python3.12"
}

variable "app_env" {
  type        = string
  description = "Entorno de despliegue (development, staging, production)"
  default     = "production"
}

variable "provisioned_concurrency" {
  type        = number
  description = "Número de instancias Lambda pre-calentadas (Provisioned Concurrency sobre alias 'live')"
  default     = 5
}

variable "ecs_desired_count" {
  type        = number
  description = "Número deseado de tareas ECS Fargate"
  default     = 2
}

variable "alert_email" {
  type        = string
  description = "Email para notificaciones SNS de la alarma de CPU (deja vacío para omitir la suscripción)"
  default     = ""
}
