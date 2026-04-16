variable "region" {
  type        = string
  description = "Region AWS donde se despliegan los recursos"
  default     = "us-east-1"
}

variable "project" {
  type        = string
  description = "Prefijo que identifica todos los recursos del laboratorio"
  default     = "lab34"
}

variable "instance_type" {
  type        = string
  description = "Tipo de instancia EC2"
  default     = "t3.micro"
}

variable "app_uid" {
  type        = number
  description = "POSIX UID del usuario de la aplicacion en el EFS Access Point"
  default     = 1001
}

variable "app_gid" {
  type        = number
  description = "POSIX GID del grupo de la aplicacion en el EFS Access Point"
  default     = 1001
}
