variable "region" {
  type        = string
  description = "Region AWS donde se despliegan los recursos"
  default     = "us-east-1"
}

variable "project" {
  type        = string
  description = "Prefijo que identifica todos los recursos del laboratorio"
  default     = "lab35"
}

variable "db_name" {
  type        = string
  description = "Nombre de la base de datos inicial"
  default     = "appdb"
}

variable "db_username" {
  type        = string
  description = "Usuario maestro de la base de datos"
  default     = "dbadmin"
}

variable "db_instance_class" {
  type        = string
  description = "Tipo de instancia RDS"
  default     = "db.t4g.small"
}

variable "db_engine_version" {
  type        = string
  description = "Version del motor PostgreSQL"
  default     = "15.17"
}

variable "db_allocated_storage" {
  type        = number
  description = "Almacenamiento inicial en GB"
  default     = 20
}

variable "db_max_allocated_storage" {
  type        = number
  description = "Almacenamiento maximo para autoscaling en GB. 0 deshabilita el autoscaling."
  default     = 100
}

variable "rotation_lambda_arn" {
  type        = string
  description = "ARN de la funcion Lambda de rotacion de Secrets Manager. Dejar vacio para omitir la rotacion automatica. Ver README seccion 'Gestion de Secretos' para desplegarla."
  default     = ""
}

variable "app_instance_type" {
  type        = string
  description = "Tipo de instancia EC2 para la aplicacion web"
  default     = "t4g.small"
}

variable "asg_min_size" {
  type        = number
  description = "Numero minimo de instancias en el Auto Scaling Group"
  default     = 1
}

variable "asg_desired_capacity" {
  type        = number
  description = "Numero deseado de instancias en el Auto Scaling Group"
  default     = 2
}

variable "asg_max_size" {
  type        = number
  description = "Numero maximo de instancias en el Auto Scaling Group"
  default     = 4
}
