variable "project" {
  type        = string
  description = "Prefijo para nombrar los recursos del modulo"
}

variable "tags" {
  type        = map(string)
  description = "Etiquetas comunes a todos los recursos del modulo"
}

variable "vpc_id" {
  type        = string
  description = "ID de la VPC donde se despliega el EFS"
}

variable "subnet_ids" {
  type        = map(string)
  description = "Mapa AZ -> ID de subnet privada donde crear los mount targets. Usar claves estaticas (AZ) para que for_each funcione en plan."
}

variable "ec2_sg_id" {
  type        = string
  description = "ID del Security Group de las instancias EC2 que montaran el EFS"
}

variable "app_uid" {
  type        = number
  description = "POSIX UID del usuario propietario del directorio raiz del Access Point"
  default     = 1001
}

variable "app_gid" {
  type        = number
  description = "POSIX GID del grupo propietario del directorio raiz del Access Point"
  default     = 1001
}
