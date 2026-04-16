variable "region" {
  type    = string
  default = "us-east-1"
}

variable "project" {
  type        = string
  description = "Prefijo que identifica todos los recursos del laboratorio"
  default     = "lab37"
}

variable "app_version" {
  type        = string
  description = "Version de la aplicacion a desplegar. Cambiarla fuerza una nueva ejecucion de los provisioners."
  default     = "1.0.0"
}

variable "ssh_private_key_path" {
  type        = string
  description = "Ruta al fichero de clave privada SSH (sin .pub). La clave publica se lee de <ruta>.pub"
  default     = "~/.ssh/lab37_key"
}

variable "ssh_allowed_cidr" {
  type        = string
  description = "CIDR desde el que se permite SSH al puerto 22. Restringe siempre a tu IP: $(curl -s https://checkip.amazonaws.com)/32"
  default     = "0.0.0.0/0"
}

variable "instance_type" {
  type    = string
  default = "t4g.small"
}
